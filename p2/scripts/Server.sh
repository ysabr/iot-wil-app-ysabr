#!/bin/bash

set -euo pipefail

echo -e "\033[1;3;34m--- Server script starting ---\033[0m"

SERVER_IP="${SERVER_IP:-192.168.56.110}"
NODE_IP="${NODE_IP:-$SERVER_IP}"

apt-get update -y
apt-get install -y ca-certificates curl iproute2

echo -e "\033[1;32m--- Installing K3s ---\033[0m"

PRIVATE_IFACE=$(ip -o -4 addr show | awk -v ip="$NODE_IP" '{ split($4, address, "/"); if (address[1] == ip) { print $2; exit } }')

if [ -z "$PRIVATE_IFACE" ]; then
	echo "Could not find the private interface for $NODE_IP"
	ip -o -4 addr show
	exit 1
fi

curl -sfL https://get.k3s.io | K3S_KUBECONFIG_MODE="644" \
	INSTALL_K3S_EXEC="server --node-ip=$SERVER_IP --advertise-address=$SERVER_IP --flannel-iface=$PRIVATE_IFACE" \
	sh -

# K3s and its Helm controller create these resources asynchronously.
# Wait for each resource to exist before waiting for readiness.
deadline=$((SECONDS + 300))
until [ -n "$(kubectl get nodes -o name --request-timeout=10s 2>/dev/null)" ]; do
	if (( SECONDS >= deadline )); then
		echo "K3s did not register a node within 300 seconds"
		journalctl -u k3s --no-pager -n 50
		exit 1
	fi
	sleep 2
done
kubectl wait --for=condition=Ready nodes --all --timeout=300s

deadline=$((SECONDS + 300))
until kubectl get deployment/traefik -n kube-system --request-timeout=10s >/dev/null 2>&1; do
	if (( SECONDS >= deadline )); then
		echo "Traefik deployment was not created within 300 seconds"
		kubectl get pods -n kube-system -o wide
		exit 1
	fi
	sleep 2
done
kubectl rollout status deployment/traefik -n kube-system --timeout=300s

if ! grep -q 'kubectl get all -o wide' /home/vagrant/.bashrc; then
	cat >>/home/vagrant/.bashrc <<EOF

echo
echo -e '\033[1mkubectl get all -o wide:\033[0m'
sudo kubectl get all -o wide
echo
echo -e '\033[1mkubectl get ingress:\033[0m'
sudo kubectl get ingress
EOF
fi

echo -e "\033[1;3;34m--- Server script finished ---\033[0m"
