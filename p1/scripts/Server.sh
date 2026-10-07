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

for attempt in $(seq 1 90); do
	if [ -s /var/lib/rancher/k3s/server/node-token ] && \
		kubectl get nodes -o name --request-timeout=5s 2>/dev/null | grep -q '^node/'; then
		break
	fi
	echo "Waiting for the K3s API and node token... ($attempt/90)"
	sleep 2
done

if [ ! -s /var/lib/rancher/k3s/server/node-token ] || \
	! kubectl get nodes -o name --request-timeout=5s 2>/dev/null | grep -q '^node/'; then
	echo "K3s did not start. Check: journalctl -u k3s --no-pager -n 50" >&2
	exit 1
fi

install -m 0644 /var/lib/rancher/k3s/server/node-token /vagrant/node-token

kubectl wait --for=condition=Ready nodes --all --timeout=300s

if ! grep -q 'kubectl get nodes -o wide' /home/vagrant/.bashrc; then
	cat >>/home/vagrant/.bashrc <<EOF

echo
echo -e '\033[1mkubectl get nodes -o wide:\033[0m'
sudo kubectl get nodes -o wide
echo
echo -e '\033[1mPrivate interface ($PRIVATE_IFACE):\033[0m'
ip addr show "$PRIVATE_IFACE"
EOF
fi

echo -e "\033[1;3;34m--- Server script finished ---\033[0m"
