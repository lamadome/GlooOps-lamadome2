#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
export MGMT=mgmt
export CLUSTER1=cluster1
export CLUSTER2=cluster2

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
cat << EOF | kubectl --context="${context}" create -f -
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-auth
---
apiVersion: v1
kind: Secret
metadata:
  name: vault-auth
  annotations:
    kubernetes.io/service-account.name: vault-auth
type: kubernetes.io/service-account-token
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: role-tokenreview-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
  - kind: ServiceAccount
    name: vault-auth
    namespace: default
EOF

export VAULT_LB=$(kubectl --context ${MGMT} get svc -n vault vault \
      -o jsonpath='{.status.loadBalancer.ingress[0].*}')
export VAULT_ADDR="http://${VAULT_LB}:8200"
export VAULT_TOKEN=root
vault auth enable --path="k8s-cluster-$clusternr" kubernetes
TOKEN_REVIEW_JWT=$(kubectl --context="${context}" get secret vault-auth -o go-template='{{ .data.token }}' | base64 --decode)
KUBE_CA_CERT=$(kubectl --context="${context}" config view --raw --minify --flatten -o jsonpath='{.clusters[].cluster.certificate-authority-data}' | base64 --decode)
KUBE_HOST=$(kubectl -n kube-system get po --context ${context} | grep -i apiserver | cut -f1 -d" " | xargs kubectl -n kube-system get po -o=jsonpath="{.status.hostIP}" --context ${context}):6443

echo "JWT Review Token"
echo $TOKEN_REVIEW_JWT
echo $KUBE_HOST
echo "-----"

vault write auth/k8s-cluster-$clusternr/config \
    token_reviewer_jwt="$TOKEN_REVIEW_JWT" \
    kubernetes_host="https://$KUBE_HOST" \
    kubernetes_ca_cert="$KUBE_CA_CERT"

vault write auth/k8s-cluster-$clusternr/role/issuer-istio-ca$clusternr \
    bound_service_account_names=vault-issuer \
    bound_service_account_namespaces=istio-system \
    policies=pki-istio-ca \
    ttl=20m
}

#function to enable vault PKI
enable_vault_pki() {
    export VAULT_LB=$(kubectl --context ${MGMT} get svc -n vault vault \
          -o jsonpath='{.status.loadBalancer.ingress[0].*}')
    export VAULT_ADDR="http://${VAULT_LB}:8200"
    vault secrets enable pki
    vault secrets tune -max-lease-ttl=87600h pki
    vault write -field=certificate pki/root/generate/internal \
      common_name="istio-ca-vault" ttl=87600h > CA_cert.crt
    vault write pki/config/urls \
        issuing_certificates="${VAULT_ADDR}/v1/pki/ca" \
        crl_distribution_points="${VAULT_ADDR}/v1/pki/crl"
vault policy write pki-istio-ca - <<EOF
path "pki*"                        { capabilities = ["read", "list"] }
path "pki_int1/roles/istio-ca1"   { capabilities = ["create", "update"] }
path "pki_int1/sign/istio-ca1"    { capabilities = ["create", "update"] }
path "pki_int1/issue/istio-ca1"   { capabilities = ["create"] }
path "pki_int2/roles/istio-ca2"   { capabilities = ["create", "update"] }
path "pki_int2/sign/istio-ca2"    { capabilities = ["create", "update"] }
path "pki_int2/issue/istio-ca2"   { capabilities = ["create"] }
EOF
}
configure_vault_pki() {
    local clusternr=$1
    vault secrets enable -path=pki_int$clusternr pki
    vault secrets tune -max-lease-ttl=43800h pki_int$clusternr
    vault write -format=json pki_int$clusternr/intermediate/generate/internal \
            common_name="Istio-ca Intermediate Authority$clusternr" \
            | jq -r '.data.csr' > pki_intermediate$clusternr.csr
    vault write -format=json pki/root/sign-intermediate csr=@pki_intermediate$clusternr.csr \
            format=pem ttl="43800h" \
            | jq -r '.data.certificate' > intermediate$clusternr.cert.pem
    cat intermediate$clusternr.cert.pem > intermediate$clusternr.chain.pem
    cat CA_cert.crt >> intermediate$clusternr.chain.pem

    vault write pki_int$clusternr/intermediate/set-signed certificate=@intermediate$clusternr.chain.pem

    vault write pki_int$clusternr/roles/istio-ca$clusternr \
        allowed_domains=istio-ca \
        allow_any_name=true  \
        enforce_hostnames=false \
        require_cn=false \
        allowed_uri_sans="spiffe://*" \
        max_ttl=72h
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



export VAULT_VERSION=0.24.1

install_vault $MGMT
connect_cluster $CLUSTER1 1
connect_cluster $CLUSTER2 2
enable_vault_pki
configure_vault_pki 1
configure_vault_pki 2

configure_vault_injector $CLUSTER1 1
configure_vault_injector $CLUSTER2 2

#install_csi $CLUSTER1
#install_csi $CLUSTER2
#
