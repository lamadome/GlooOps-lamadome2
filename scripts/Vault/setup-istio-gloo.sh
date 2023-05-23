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


wait_for_lb_address() {
    local context=$1
    local service=$2
    local ns=$3

    # Only run this for a load balancer type
    kubectl --context ${context} -n $ns get service/$service --output=jsonpath='{.spec.type}' | grep -i LoadBalancer &> /dev/null
    is_lb_enabled=$?
    if [ $is_lb_enabled -eq 0 ]; then
        ip=""
        while [ -z $ip ]; do
            echo "Waiting for $service external IP ..."
            ip=$(kubectl --context ${context} -n $ns get service/$service --output=jsonpath='{.status.loadBalancer}' | grep "ingress")
            [ -z "$ip" ] && sleep 5
        done
        debug "Found $service external IP: ${ip}"
    fi
}

install_vault() {
    local context=$1

    print_operation_info "Installing Vault $VAULT_VERSION"

    helm repo add hashicorp https://helm.releases.hashicorp.com
    helm repo update

    helm install vault hashicorp/vault -n vault \
        --kube-context ${context} \
        --version ${VAULT_VERSION} \
        --create-namespace \
        -f $DIR/vault-helm-values.yaml

    # Wait for vault to be ready
    kubectl --context ${context} wait --for=condition=ready pod vault-0 -n vault --timeout 0

    wait_for_lb_address $context "vault" "vault"
}

connect_cluster() {
local context=$1
local clusternr=$2
print_operation_info "Setting k8s-auth on ${context}"

kubectl --context="${context}" create -f $DIR/files/vault-auth-sa.yaml

vault auth enable --path="k8s-cluster-$clusternr" kubernetes
TOKEN_REVIEW_JWT=$(kubectl --context="${context}" get secret vault-auth -o go-template='{{ .data.token }}' | base64 --decode)
KUBE_CA_CERT=$(kubectl --context="${context}" config view --raw --minify --flatten -o jsonpath='{.clusters[].cluster.certificate-authority-data}' | base64 --decode)
KUBE_HOST=$(kubectl -n kube-system get po --context ${context} | grep -i apiserver | cut -f1 -d" " | xargs kubectl -n kube-system get po -o=jsonpath="{.status.hostIP}" --context ${context}):6443

vault write auth/k8s-cluster-$clusternr/config \
    token_reviewer_jwt="$TOKEN_REVIEW_JWT" \
    kubernetes_host="https://$KUBE_HOST" \
    kubernetes_ca_cert="$KUBE_CA_CERT"

vault write auth/k8s-cluster-$clusternr/role/issuer-istio-ca$clusternr \
    bound_service_account_names=istiod-1-17 \
    bound_service_account_namespaces=istio-system \
    policies=gen-int-ca-cluster${clusternr} \
    ttl=20m

vault write auth/k8s-cluster-$clusternr/role/issuer-istio-ca$clusternr \
    bound_service_account_names=vault-issuer \
    bound_service_account_namespaces=istio-system \
    policies=gen-int-ca-cluster${clusternr} \
    ttl=20m
}

generate_root() {
    print_operation_info "Bootstrapping the Istio PKI on Vault"

    local cert_gen_dir=$(mktemp -d)/certs/istio
    mkdir -p $cert_gen_dir

    # Generate offline root CA (10 year expiry)
    cfssl genkey \
      -initca $DIR/files/pki/istio/root-template.json | cfssljson -bare $cert_gen_dir/root-cert

    cat $cert_gen_dir/root-cert-key.pem $cert_gen_dir/root-cert.pem > $cert_gen_dir/root-bundle.pem

    # Enable PKI engine
    vault secrets enable pki

    # Import Root CA
    vault write -format=json pki/config/ca pem_bundle=@$cert_gen_dir/root-bundle.pem

    rm -rf $cert_gen_dir
}

#function to enable vault PKI
generate_int_cluster() {
    local clusternr=$1
    print_operation_info "Bootstrapping the intermediate Istio PKI for $CLUSTER${clusternr} cluster on Vault"

    # Enable PKI for west mesh (intermediate signing)
    vault secrets enable -path=pki_int${clusternr} pki

    # Tune with 3 years TTL
    vault secrets tune -max-lease-ttl="26280h" pki_int${clusternr}

    vault policy write gen-int-ca-cluster${clusternr} - <<EOF
path "pki_int${clusternr}/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "pki/cert/ca" {
  capabilities = ["read"]
}
path "pki/root/sign-intermediate" {
  capabilities = ["create", "read", "update", "list"]
}
EOF
}

install_csi() {
  local context=$1
  helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts

  helm upgrade --install csi secrets-store-csi-driver/secrets-store-csi-driver \
  --set "syncSecret.enabled=true" \
  --set "enableSecretRotation=true" \
  --namespace kube-system \
  --kube-context $context

  kubectl --namespace kube-system rollout status daemonset/csi-secrets-store-csi-driver --context $context
}

configure_vault_injector() {
  local context=$1
  local clusternr=$2
  helm upgrade --install vault hashicorp/vault \
      --set "global.externalVaultAddr=${VAULT_ADDR}" \
      --set injector.authPath="auth/k8s-cluster-${clusternr}" \
      --set csi.enabled=true \
      --kube-context $context
  kubectl rollout status deployment/vault-agent-injector --context $context
}

export MGMT=mgmt
export CLUSTER1=cluster1
export CLUSTER2=cluster2
export VAULT_VERSION=0.24.1

install_vault $MGMT

sleep 10


export VAULT_LB=$(kubectl --context ${MGMT} get svc -n vault vault \
          -o jsonpath='{.status.loadBalancer.ingress[0].*}')
export VAULT_ADDR="http://${VAULT_LB}:8200"

#generate_root
#
#generate_int_cluster 1
#generate_int_cluster 2

connect_cluster $CLUSTER1 1
connect_cluster $CLUSTER2 2

configure_vault_injector $CLUSTER1 1
configure_vault_injector $CLUSTER2 2