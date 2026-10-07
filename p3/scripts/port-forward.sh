#!/bin/bash

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
	exec sudo -E bash "$0" "$@"
fi

if pgrep -f "kubectl port-forward service/argocd-server.*8080:443" >/dev/null 2>&1; then
	echo "Argo CD port-forward is already running on 8080"
	exit 0
fi

kubectl wait --for=condition=Ready --timeout=180s -n argocd pod -l app.kubernetes.io/name=argocd-server

(
	while true; do
		kubectl port-forward service/argocd-server --address 0.0.0.0 -n argocd 8080:443
		sleep 2
	done
) >/tmp/argocd-port-forward.log 2>&1 &
disown

echo "Argo CD port-forward started on https://localhost:8080"
