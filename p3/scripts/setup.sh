#!/bin/bash

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
	exec sudo -E bash "$0" "$@"
fi

CLUSTER_NAME="${CLUSTER_NAME:-iot}"

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
	k3d cluster start "$CLUSTER_NAME" --timeout 180s
	k3d kubeconfig merge "$CLUSTER_NAME" --kubeconfig-switch-context >/dev/null
fi

kubectl wait --for=condition=Ready --timeout=180s node --all

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f -

# Server-side apply avoids the annotation size limit on Argo CD's CRDs.
kubectl apply -n argocd --server-side --force-conflicts \
	-f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl wait --for=condition=Established --timeout=60s \
	crd/applications.argoproj.io crd/applicationsets.argoproj.io crd/appprojects.argoproj.io

kubectl wait --for=condition=Available --timeout=300s -n argocd deployment --all
kubectl rollout status -n argocd statefulset/argocd-application-controller --timeout=300s

INITIAL_PASSWORD=$(kubectl get secret argocd-initial-admin-secret -n argocd --ignore-not-found -o jsonpath="{.data.password}")
if [ -n "$INITIAL_PASSWORD" ]; then
	echo "Argo CD initial admin password:"
	printf '%s' "$INITIAL_PASSWORD" | base64 --decode
	echo
else
	echo "Argo CD is already configured; use your existing admin password."
fi

kubectl apply -f confs/argocd-cm.yml -n argocd
kubectl rollout restart deployment/argocd-repo-server -n argocd
kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=180s
kubectl apply -f confs/argocd-deploy.yml -n argocd

bash scripts/port-forward.sh

if ! curl --noproxy '*' --insecure --fail --silent --show-error --retry 20 --retry-delay 2 \
	--retry-connrefused --retry-max-time 60 --connect-timeout 2 --max-time 5 \
	https://localhost:8080/healthz >/dev/null; then
	echo "Argo CD is not reachable on port 8080. Check /tmp/argocd-port-forward.log and whether another process is using the port." >&2
	exit 1
fi

echo "Waiting for Argo CD to sync the Git repository and start wil-app..."
if ! kubectl wait -n argocd application/wil-app --timeout=300s \
	--for=jsonpath='{.status.sync.status}'=Synced || \
	! kubectl wait -n argocd application/wil-app --timeout=300s \
	--for=jsonpath='{.status.health.status}'=Healthy; then
	echo "wil-app is not ready. Check the repository URL and its manifests in confs/argocd-deploy.yml." >&2
	kubectl get application/wil-app -n argocd \
		-o jsonpath='{range .status.conditions[*]}{.type}{": "}{.message}{"\n"}{end}' >&2 || true
	kubectl get pods,service -n dev >&2 || true
	exit 1
fi

if ! curl --noproxy '*' --fail --silent --show-error --retry 20 --retry-delay 2 \
	--retry-connrefused --retry-max-time 60 --connect-timeout 2 --max-time 5 \
	http://localhost:8888; then
	echo "wil-app is synced, but port 8888 is not reachable. Check the cluster's port mapping and the LoadBalancer service in the Git repository." >&2
	exit 1
fi
echo

echo "Argo CD: https://localhost:8080"
echo "Application: http://localhost:8888"
