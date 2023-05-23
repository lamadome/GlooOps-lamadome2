#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

error_exit() {
    echo "Error: $1"
    exit 1
}

print_operation_info() {
    echo "============================================================"
    echo "$1"
    echo "============================================================"
    echo ""
}

debug() {
    if [[ "$_DEBUG" = true ]]; then
        echo "$1"
    fi
}

check_vault_status() {
    vault status &> /dev/null
    while [[ $? -ne 0 ]]; do sleep 5; vault status &> /dev/null; done
}

generate_relay_root_pki() {
    print_operation_info "Bootstrapping the relay PKI on Vault"

    kubectl --context ${MGMT} create namespace gloo-mesh --dry-run=client -o yaml | kubectl --context ${MGMT} apply -f -

    check_vault_status

    local cert_gen_dir=$(mktemp -d)/certs/relay
    mkdir -p $cert_gen_dir

    # Generate offline root CA (10 year expiry)
    debug "Generating the offline root CA"
    cfssl genkey \
      -initca $DIR/files/pki/relay/root-template.json | cfssljson -bare $cert_gen_dir/root-cert

    # Generate an intermediate CA
    vault secrets enable -path relay-pki-int pki

    vault write -field=csr \
      relay-pki-int/intermediate/generate/internal \
      common_name=${COMMON_NAME} \
      key_type=rsa \
      key_bits=4096 \
      max_path_length=1 \
      ttl="43800h" > $cert_gen_dir/int-request.csr

    # Sign the CSR using the offline root
    cfssl sign \
      -ca $cert_gen_dir/root-cert.pem \
      -ca-key $cert_gen_dir/root-cert-key.pem \
      -config $DIR/files/pki/relay/int-config.json \
      $cert_gen_dir/int-request.csr | cfssljson -bare $cert_gen_dir/int-ca

    # Set signed cert with the extracted blob
    vault write -format=json \
      relay-pki-int/intermediate/set-signed \
      certificate=@$cert_gen_dir/int-ca.pem
    debug "Completed generating a signed cert"

    # Configure a role
    vault write \
      relay-pki-int/roles/gloo-mesh-mgmt-server \
      allow_any_name=true max_ttl="720h"

    #rm -f $cert_gen_dir/root-cert-key.pem

    debug "Configuring certificate manager to issue relay server certificate"
    kubectl --context ${MGMT} create secret generic vault-token --from-literal=token=root -n gloo-mesh

      envsubst < <(cat $DIR/files/vault-issuer.yaml) | kubectl --context="${MGMT}" apply -f -

    sleep 5

    envsubst < <(cat $DIR/files/relay-server-cer.yaml) | kubectl --context="${MGMT}" apply -f -


    rm -rf $cert_gen_dir
}

configure_cert_manager_for_workers() {
    local cluster_context=$1
    local cluster_name=$2

    print_operation_info "Configuring certificate manager to issue the relay client certificate for $cluster_name cluster"

    kubectl --context ${cluster_context} create namespace gloo-mesh --dry-run=client -o yaml | kubectl --context ${cluster_context} apply -f -
    kubectl --context ${cluster_context} create secret generic vault-token --from-literal=token=root -n gloo-mesh

    kubectl --context ${cluster_context} apply -f- <<EOF
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: vault-issuer
  namespace: gloo-mesh
spec:
  vault:
    path: relay-pki-int/sign/gloo-mesh-mgmt-server
    server: $VAULT_ADDR
    auth:
      tokenSecretRef:
        name: vault-token
        key: token
EOF

    sleep 5

    kubectl --context ${cluster_context} apply -f- <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: relay-client-tls
  namespace: gloo-mesh
spec:
  commonName: "${COMMON_NAME}"
  dnsNames:
    - "$cluster_name"
  secretName: relay-client-tls-secret
  duration: 720h
  renewBefore: 700h
  privateKey:
    rotationPolicy: Always
    algorithm: RSA
    size: 2048
  issuerRef:
    name: vault-issuer
    kind: Issuer
    group: cert-manager.io
EOF
}
export MGMT=mgmt
export CLUSTER1=cluster1
export CLUSTER2=cluster2

# Find the public IP for the vault service
export VAULT_LB=$(kubectl --context ${MGMT} get svc -n vault vault \
    -o jsonpath='{.status.loadBalancer.ingress[0].*}')
export VAULT_ADDR="http://${VAULT_LB}:8200"
export VAULT_TOKEN="root"
export COMMON_NAME="gloo-mesh-mgmt-server"

if [[ -z "${VAULT_LB}" ]]; then
    error_exit "Unable to obtain the address for the Vault service"
fi


generate_relay_root_pki

configure_cert_manager_for_workers $CLUSTER1 cluster1
configure_cert_manager_for_workers $CLUSTER2 cluster2