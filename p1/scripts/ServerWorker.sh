#!/bin/bash

set -euo pipefail

echo -e "\033[1;3;33m--- Server Worker script starting ---\033[0m"

SERVER_IP="${SERVER_IP:-192.168.56.110}"
WORKER_IP="${WORKER_IP:-192.168.56.111}"
NODE_IP="${NODE_IP:-$WORKER_IP}"

apt-get update -y
apt-get install -y ca-certificates curl iproute2

echo -e "\033[1;32m--- Installing K3s ---\033[0m"

PRIVATE_IFACE=$(ip -o -4 addr show | awk -v ip="$NODE_IP" '$4 ~ "^" ip "/" { print $2; exit }')

if [ -z "$PRIVATE_IFACE" ]; then
	echo "Could not find the private interface for $NODE_IP"
	ip -o -4 addr show
	exit 1
fi

for attempt in $(seq 1 90); do
	if [ -s /vagrant/node-token ]; then
		break
	fi
	echo "Waiting for the server node token... ($attempt/90)"
	sleep 2
done

if [ ! -s /vagrant/node-token ]; then
	echo "Missing /vagrant/node-token. Start the server VM first or rerun provisioning."
	exit 1
fi

curl -sfL https://get.k3s.io | K3S_URL="https://$SERVER_IP:6443" \
	K3S_TOKEN_FILE="/vagrant/node-token" \
	INSTALL_K3S_EXEC="agent --node-ip=$WORKER_IP --flannel-iface=$PRIVATE_IFACE" \
	sh -

if ! grep -q 'Private interface' /home/vagrant/.bashrc; then
	cat >>/home/vagrant/.bashrc <<EOF

echo
echo -e '\033[1mPrivate interface ($PRIVATE_IFACE):\033[0m'
ip addr show "$PRIVATE_IFACE"
EOF
fi

echo -e "\033[1;3;33m--- Server Worker script finished ---\033[0m"
