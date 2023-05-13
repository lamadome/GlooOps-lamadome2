#!/bin/bash
export MGMT=mgmt
export CLUSTER1=cluster1
export CLUSTER2=cluster2
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

argocd login solo.cd.akuity.cloud --username=admin --password='dkc5dzc9JTX!hpn*utr' --insecure --grpc-web
argocd proj create -f "$DIR/teams/platform/appproject-gloo-mgmt.yaml" --grpc-web
argocd repo add https://github.com/lamadome/GlooOps-lamadome2 --project gloo-mesh --grpc-web
argocd app create -f "$DIR/teams/platform/mgmt-server/app-mgmt-server.yaml"

sleep 5

kubectl --context ${MGMT} -n gloo-mesh rollout status deploy/gloo-mesh-mgmt-server
kubectl --context ${MGMT} -n gloo-mesh rollout status deploy/gloo-mesh-ui

kubectl --context $CLUSTER1 create ns gloo-mesh
kubectl --context $CLUSTER2 create ns gloo-mesh

kubectl get secret relay-root-tls-secret -n gloo-mesh --context ${MGMT} -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt
kubectl get secret relay-identity-token-secret -n gloo-mesh --context ${MGMT} -o jsonpath='{.data.token}' | base64 -d > token

cat <<EOF > $DIR/teams/platform/gloo-mesh-agent/base/relay-root-tls-secret.yaml
apiVersion: v1
data:
  ca.crt:  $(cat ca.crt | base64)
kind: Secret
metadata:
  name: relay-root-tls-secret
  namespace: gloo-mesh
EOF

cat <<EOF > $DIR/teams/platform/gloo-mesh-agent/base/relay-identity-token-secret.yaml
apiVersion: v1
data:
  token: $(cat token | base64)
kind: Secret
metadata:
  name: relay-identity-token-secret
  namespace: gloo-mesh
EOF

git add .
git commit -m "add tls and token secret"
git push

rm ca.crt
rm token

export ENDPOINT_GLOO_MESH=$(kubectl --context ${MGMT} -n gloo-mesh get svc gloo-mesh-mgmt-server -o jsonpath='{.status.loadBalancer.ingress[0].*}'):9900
export HOST_GLOO_MESH=$(echo ${ENDPOINT_GLOO_MESH} | cut -d: -f1)
export GLOO_MESH_UI=http://$(kubectl --context ${MGMT} -n gloo-mesh get svc gloo-mesh-ui -o jsonpath='{.status.loadBalancer.ingress[0].*}'):8090

cat <<EOF > $DIR/teams/platform/gloo-mesh-agent/mgmt/values-cluster1.yaml
relay:
  serverAddress: ${ENDPOINT_GLOO_MESH}
  authority: gloo-mesh-mgmt-server.gloo-mesh
rate-limiter:
  enabled: false
ext-auth-service:
  enabled: false
cluster: cluster1
EOF

cat <<EOF > $DIR/teams/platform/gloo-mesh-agent/mgmt/values-cluster2.yaml
relay:
  serverAddress: ${ENDPOINT_GLOO_MESH}
  authority: gloo-mesh-mgmt-server.gloo-mesh
rate-limiter:
  enabled: false
ext-auth-service:
  enabled: false
cluster: cluster1
EOF

git add .
git commit -m "update relay address"
git push

argocd appset create "$DIR/teams/platform/gloo-mesh-agent/gloo-agents-app.yaml"

kubectl --context ${CLUSTER1} -n gloo-mesh rollout status deploy/gloo-mesh-agent
kubectl --context ${CLUSTER2} -n gloo-mesh rollout status deploy/gloo-mesh-agent

argocd appset create "$DIR/teams/platform/istio/applicationset.yaml"

until [[ $(kubectl --context ${CLUSTER1} -n istio-system get deploy -o json | jq '[.items[].status.readyReplicas] | add') -ge 1 ]]; do
  sleep 1
done
until [[ $(kubectl --context ${CLUSTER1} -n istio-gateways get deploy -o json | jq '[.items[].status.readyReplicas] | add') -eq 2 ]]; do
  sleep 1
done
p "done"
kubectl --context ${CLUSTER1} -n istio-gateways get pods
kubectl --context ${CLUSTER1} -n istio-system get pods

p "Checking istio install on cluster1"
until [[ $(kubectl --context ${CLUSTER2} -n istio-system get deploy -o json | jq '[.items[].status.readyReplicas] | add') -ge 1 ]]; do
  sleep 1
done
until [[ $(kubectl --context ${CLUSTER2} -n istio-gateways get deploy -o json | jq '[.items[].status.readyReplicas] | add') -eq 2 ]]; do
  sleep 1
done
p "done"

kubectl --context ${CLUSTER2} -n istio-gateways get pods
kubectl --context ${CLUSTER2} -n istio-system get pods

export ENDPOINT_HTTP_GW_CLUSTER1=$(kubectl --context ${CLUSTER1} -n istio-gateways get svc -l istio=ingressgateway -o jsonpath='{.items[0].status.loadBalancer.ingress[0].*}'):80
export ENDPOINT_HTTPS_GW_CLUSTER1=$(kubectl --context ${CLUSTER1} -n istio-gateways get svc -l istio=ingressgateway -o jsonpath='{.items[0].status.loadBalancer.ingress[0].*}'):443
export HOST_GW_CLUSTER1=$(echo ${ENDPOINT_HTTP_GW_CLUSTER1} | cut -d: -f1)
export ENDPOINT_HTTP_GW_CLUSTER2=$(kubectl --context ${CLUSTER2} -n istio-gateways get svc -l istio=ingressgateway -o jsonpath='{.items[0].status.loadBalancer.ingress[0].*}'):80
export ENDPOINT_HTTPS_GW_CLUSTER2=$(kubectl --context ${CLUSTER2} -n istio-gateways get svc -l istio=ingressgateway -o jsonpath='{.items[0].status.loadBalancer.ingress[0].*}'):443
export HOST_GW_CLUSTER2=$(echo ${ENDPOINT_HTTP_GW_CLUSTER2} | cut -d: -f1)

#Create the workspaces appset
argocd appset create "$DIR/teams/platform/workspaces/applicationset.yaml"

argocd appset create "$DIR/teams/gateways/argo-app.yaml"

kubectl --context ${CLUSTER1} create ns fake-frontend
kubectl --context ${CLUSTER1} create ns fake-backend

