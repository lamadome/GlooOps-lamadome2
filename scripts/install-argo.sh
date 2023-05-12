#!/bin/bash
# ########################
export MGMT=mgmt
export CLUSTER1=cluster1
export CLUSTER2=cluster2

kubectl create namespace argocd --context ${MGMT}
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.6.0-rc3/manifests/install.yaml --context ${MGMT}
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=120s --context ${MGMT}
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}' --context ${MGMT}
kubectl -n argocd patch secret argocd-secret -p '{"stringData": {"admin.password": "$2a$10$ldvEUwliowstaKXsWbK5b.mvN79pN8yFqQzq1Vq50fIEnzHGhljCa","admin.passwordMtime": "'$(date +%FT%T%Z)'"}}' --context ${MGMT}
export ARGO_URL=$(kubectl get svc -n argocd argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].*}' --context ${MGMT})

sleep 5

echo "Login to Argo"
argocd login ${ARGO_URL} --username=admin --password=admin --insecure
argocd cluster add ${MGMT} -y --in-cluster --name ${MGMT}

echo "create cluster1"
kubectl -n kube-system create serviceaccount argo-cluster-admin --context ${CLUSTER1}

cat << EOF | kubectl  --context ${CLUSTER1} apply -f -

apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argo-cluster-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: argo-cluster-admin
  namespace: kube-system
EOF

export USER_TOKEN_VALUE_cluster1=$(kubectl create token argo-cluster-admin -n kube-system --context ${CLUSTER1} --duration=0s)
export CURRENT_cluster1=$(kubectl config view --raw -o=go-template='{{range .contexts}}{{if eq .name "'''${CLUSTER1}'''"}}{{ index .context "cluster" }}{{end}}{{end}}' --context ${CLUSTER1})
export CA_cluster1=$(kubectl config view --raw -o=go-template='{{range .clusters}}{{if eq .name "'''${CURRENT_cluster1}'''"}}"{{with index .cluster "certificate-authority-data" }}{{.}}{{end}}"{{ end }}{{ end }}' --context ${CLUSTER1})
export API_cluster1=https://$(kubectl -n kube-system get po --context ${CLUSTER1} | grep -i apiserver | cut -f1 -d" " | xargs kubectl -n kube-system get po -o=jsonpath="{.status.hostIP}" --context ${CLUSTER1}):6443

kubectl --context ${MGMT} apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cluster1-secret
  labels:
    argocd.argoproj.io/secret-type: cluster
  namespace: argocd
type: Opaque
stringData:
  name: ${CLUSTER1}
  server: ${API_cluster1}
  config: |
    {
      "bearerToken": "${USER_TOKEN_VALUE_cluster1}",
      "tlsClientConfig": {
        "insecure": false,
        "caData": ${CA_cluster1}
      }
    }
EOF

echo "create cluster2"
kubectl -n kube-system create serviceaccount argo-cluster-admin --context ${CLUSTER2}

cat << EOF | kubectl  --context ${CLUSTER2} apply -f -

apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argo-cluster-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: argo-cluster-admin
  namespace: kube-system
EOF

export USER_TOKEN_VALUE_cluster2=$(kubectl create token argo-cluster-admin -n kube-system --context ${CLUSTER2} --duration=0s)
export CURRENT_cluster2=$(kubectl config view --raw -o=go-template='{{range .contexts}}{{if eq .name "'''${CLUSTER2}'''"}}{{ index .context "cluster" }}{{end}}{{end}}' --context ${CLUSTER2})
export CA_cluster2=$(kubectl config view --raw -o=go-template='{{range .clusters}}{{if eq .name "'''${CURRENT_cluster2}'''"}}"{{with index .cluster "certificate-authority-data" }}{{.}}{{end}}"{{ end }}{{ end }}' --context ${CLUSTER2})
export API_cluster2=https://$(kubectl -n kube-system get po --context ${CLUSTER2} | grep -i apiserver | cut -f1 -d" " | xargs kubectl -n kube-system get po -o=jsonpath="{.status.hostIP}" --context ${CLUSTER2}):6443

kubectl --context ${MGMT} apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cluster2-secret
  labels:
    argocd.argoproj.io/secret-type: cluster
  namespace: argocd
type: Opaque
stringData:
  name: ${CLUSTER2}
  server: ${API_cluster2}
  config: |
    {
      "bearerToken": "${USER_TOKEN_VALUE_cluster2}",
      "tlsClientConfig": {
        "insecure": false,
        "caData": ${CA_cluster2}
      }
    }
EOF

echo "Add Repo"
kubectl --context ${MGMT} apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: gloo-ops-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  url: ${REPO_URL}
  project: gloo-mesh
  type: git
EOF

argocd cluster list
argocd repo list

echo "Argo URL: https://${ARGO_URL}"