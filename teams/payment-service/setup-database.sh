#!/bin/bash
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

export MGMT=mgmt
export CLUSTER1=cluster1
export CLUSTER2=cluster2

helm upgrade --install csi secrets-store-csi-driver/secrets-store-csi-driver -f helm/csi.yaml --namespace kube-system --kube-context cluster1
helm upgrade --install csi secrets-store-csi-driver/secrets-store-csi-driver -f helm/csi.yaml --namespace kube-system --kube-context cluster2

kubectl --context $CLUSTER1 create ns payments
kubectl --context $CLUSTER2 create ns payments

kubectl label --context="${CLUSTER1}" namespace payments \
    istio-injection=enabled
kubectl label --context="${CLUSTER2}" namespace payments \
    istio-injection=enabled



kubectl --context $CLUSTER1 apply -f $DIR/cluster1/payments-database.yaml -n payments
kubectl --context $CLUSTER1 apply -f $DIR/cluster1/payments-processor.yaml -n payments

export VAULT_LB=$(kubectl --context ${MGMT} get svc -n vault vault \
          -o jsonpath='{.status.loadBalancer.ingress[0].*}')
export POSTGRES_LB=$(kubectl --context ${CLUSTER1} get svc -n payments payments-database \
          -o jsonpath='{.status.loadBalancer.ingress[0].*}')
export VAULT_ADDR="http://${VAULT_LB}:8200"
export VAULT_TOKEN=root

vault secrets enable -path='payments/database' database
vault secrets enable -path='payments/secrets' -version=2 kv

vault kv put payments/secrets/processor 'username=payments-app' 'password=payments-admin-password'

vault write payments/database/config/payments \
	 	plugin_name=postgresql-database-plugin \
	 	connection_url='postgresql://{{username}}:{{password}}@'${POSTGRES_LB}':5432/payments' \
	 	allowed_roles="payments-app" \
	 	username="postgres" \
	 	password="postgres-admin-password"

vault write payments/database/roles/payments-app \
    db_name=payments \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
		GRANT ALL PRIVILEGES ON payments TO \"{{name}}\";" \
    default_ttl="2m" \
    max_ttl="4m"
vault write auth/k8s-cluster-1/role/payments-app \
     bound_service_account_names=payments-app \
     bound_service_account_namespaces=payments \
     policies=payments \
     ttl=24h
vault write auth/k8s-cluster-2/role/payments-app \
     bound_service_account_names=payments-app \
     bound_service_account_namespaces=payments \
     policies=payments \
     ttl=24h

vault secrets enable transit
vault write -f transit/keys/payments-app

vault policy write payments $DIR/policy.hcl