#!/bin/bash

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
	exec sudo -E bash "$0" "$@"
fi

if ! pgrep -f "kubectl port-forward service/gitlab-webservice-default.*8181:8181" >/dev/null 2>&1; then
	echo 'Port forwarding GitLab 8181:8181'
	(
		while true; do
			kubectl port-forward service/gitlab-webservice-default --address 0.0.0.0 -n gitlab 8181:8181 || true
			sleep 2
		done
	) >/tmp/gitlab-port-forward.log 2>&1 &
	disown
fi

if ! pgrep -f "kubectl port-forward service/argocd-server.*8080:443" >/dev/null 2>&1; then
	kubectl wait --for=condition=Ready --timeout=180s pod -l app.kubernetes.io/name=argocd-server -n argocd
	echo 'Port forwarding Argo CD 8080:443'
	(
		while true; do
			kubectl port-forward service/argocd-server --address 0.0.0.0 -n argocd 8080:443 || true
			sleep 2
		done
	) >/tmp/argocd-port-forward.log 2>&1 &
	disown
fi
