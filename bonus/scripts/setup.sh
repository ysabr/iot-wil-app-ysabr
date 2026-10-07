#!/bin/bash

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
	exec sudo -E bash "$0" "$@"
fi

CLUSTER_NAME="${CLUSTER_NAME:-bonus}"

if ! command -v k3d >/dev/null 2>&1; then
	echo "k3d could not be found"
	exit 1
fi
if ! command -v kubectl >/dev/null 2>&1; then
	echo "kubectl could not be found"
	exit 1
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR/.."

docker info >/dev/null

if ! k3d cluster list | awk 'NR > 1 { print $1 }' | grep -qx "$CLUSTER_NAME"; then
	if [ -z "${K3S_IMAGE:-}" ]; then
		K3S_VERSION=$(curl -fsSL https://update.k3s.io/v1-release/channels | jq -er '.data[] | select(.id == "stable") | .latest')
		K3S_IMAGE="rancher/k3s:${K3S_VERSION/+/-}"
	fi
	k3d cluster create "$CLUSTER_NAME" --image "$K3S_IMAGE" --port "8888:8888@loadbalancer"
else
	k3d kubeconfig merge "$CLUSTER_NAME" --kubeconfig-switch-context >/dev/null
fi

kubectl wait --for=condition=Ready --timeout=180s node --all

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace gitlab --dry-run=client -o yaml | kubectl apply -f -

# Server-side apply avoids the annotation size limit on Argo CD's CRDs.
kubectl apply -n argocd --server-side --force-conflicts \
	-f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl wait --for=condition=Established --timeout=60s \
	crd/applications.argoproj.io crd/applicationsets.argoproj.io crd/appprojects.argoproj.io

helm repo add gitlab https://charts.gitlab.io/ --force-update
helm repo update
helm upgrade --install gitlab gitlab/gitlab \
	--timeout 600s \
	--values confs/gitlab.yaml \
	-n gitlab

echo -e '\n\033[32mWaiting for GitLab to be ready (up to 15min)\033[0m'
# The chart creates the webservice deployment asynchronously.
deadline=$((SECONDS + 300))
until kubectl get deployment/gitlab-webservice-default -n gitlab >/dev/null 2>&1; do
	if (( SECONDS >= deadline )); then
		echo "GitLab webservice deployment was not created within 300 seconds" >&2
		kubectl get pods -n gitlab >&2 || true
		exit 1
	fi
	sleep 2
done
if ! kubectl rollout status deployment/gitlab-webservice-default -n gitlab --timeout=900s; then
	echo "GitLab did not become ready. It needs about 6 GB of free memory." >&2
	kubectl get pods -n gitlab >&2 || true
	exit 1
fi

bash scripts/port-forwarding.sh

bash scripts/repo.sh

kubectl apply -f confs/argocd-cm.yml -n argocd
kubectl rollout restart deployment/argocd-repo-server -n argocd
kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=180s
kubectl apply -f confs/argocd-deploy.yml -n argocd

kubectl wait --for=condition=Available --timeout=300s -n argocd deployment --all
kubectl rollout status -n argocd statefulset/argocd-application-controller --timeout=300s
echo -e "\033[1mArgoCD password:"
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 --decode >argoCD.password
echo >>argoCD.password
cat argoCD.password
echo -e "Saved to argoCD.password\033[0m"

echo -e "\033[1mGitlab password:"
kubectl get secret gitlab-gitlab-initial-root-password -n gitlab -o jsonpath="{.data.password}" | base64 --decode >gitlab.password
echo >>gitlab.password
cat gitlab.password
echo -e "Saved to gitlab.password\033[0m"

echo "GitLab: http://localhost:8181"
echo "Argo CD: https://localhost:8080"
echo "Application: http://localhost:8888"
