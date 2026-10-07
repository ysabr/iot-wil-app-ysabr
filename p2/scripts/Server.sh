#!/bin/bash

set -euo pipefail

echo -e "\033[1;3;34m--- Server script starting ---\033[0m"

SERVER_IP="${SERVER_IP:-192.168.56.110}"
NODE_IP="${NODE_IP:-$SERVER_IP}"

apt-get update -y
apt-get install -y ca-certificates curl iproute2

echo -e "\033[1;32m--- Installing K3s ---\033[0m"

PRIVATE_IFACE=$(ip -o -4 addr show | awk -v ip="$NODE_IP" '$4 ~ "^" ip "/" { print $2; exit }')

if [ -z "$PRIVATE_IFACE" ]; then
	echo "Could not find the private interface for $NODE_IP"
	ip -o -4 addr show
	exit 1
fi

curl -sfL https://get.k3s.io | K3S_KUBECONFIG_MODE="644" \
	INSTALL_K3S_EXEC="server --node-ip=$SERVER_IP --advertise-address=$SERVER_IP --flannel-iface=$PRIVATE_IFACE" \
	sh -

kubectl wait --for=condition=Ready nodes --all --timeout=180s
kubectl rollout status deployment/traefik -n kube-system --timeout=180s

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
