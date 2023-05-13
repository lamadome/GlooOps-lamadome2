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
argocd appset create "$DIR/steams/platform/istio/applicationset.yaml"

