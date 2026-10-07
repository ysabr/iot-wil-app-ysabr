#!/bin/bash

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
	exec sudo -E bash "$0" "$@"
fi

apt-get update -y
apt-get install -y ca-certificates curl gnupg jq
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo \
	"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
	>/etc/apt/sources.list.d/docker.list
apt-get update -y

apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

K3D_VERSION="${K3D_VERSION:-v5.9.0}"
INSTALLED_K3D_VERSION=$(k3d version 2>/dev/null | awk '$1 == "k3d" { print $3 }' || true)
if [ "$INSTALLED_K3D_VERSION" != "$K3D_VERSION" ]; then
	curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | TAG="$K3D_VERSION" bash
fi

# Match the existing cluster, or the stable K3s channel for a fresh one.
CLUSTER_NAME="${CLUSTER_NAME:-bonus}"
NODE_IMAGE=$(docker inspect "k3d-${CLUSTER_NAME}-server-0" --format '{{.Config.Image}}' 2>/dev/null || true)
if [ -z "$NODE_IMAGE" ]; then
	if [ -z "${K3S_IMAGE:-}" ]; then
		K3S_VERSION=$(curl -fsSL https://update.k3s.io/v1-release/channels | jq -er '.data[] | select(.id == "stable") | .latest')
		K3S_IMAGE="rancher/k3s:${K3S_VERSION/+/-}"
	fi
	NODE_IMAGE="$K3S_IMAGE"
fi
K3S_TAG="${NODE_IMAGE##*:}"
KUBECTL_VERSION="${KUBECTL_VERSION:-${K3S_TAG%%-k3s*}}"
if [[ ! "$KUBECTL_VERSION" =~ ^v1\.[0-9]+\.[0-9]+$ ]]; then
	echo "Cannot determine a matching kubectl version from '$K3S_TAG'. Set KUBECTL_VERSION explicitly." >&2
	exit 1
fi
INSTALLED_KUBECTL_VERSION=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' || true)
if [ "$INSTALLED_KUBECTL_VERSION" != "$KUBECTL_VERSION" ]; then
	ARCH=$(dpkg --print-architecture)
	DOWNLOAD_DIR=$(mktemp -d)
	trap 'rm -rf "$DOWNLOAD_DIR"' EXIT
	URL="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"
	curl -fsSL "$URL" -o "$DOWNLOAD_DIR/kubectl"
	CHECKSUM=$(curl -fsSL "$URL.sha256")
	printf '%s  %s\n' "$CHECKSUM" "$DOWNLOAD_DIR/kubectl" | sha256sum --check --status
	install -m 0755 "$DOWNLOAD_DIR/kubectl" /usr/local/bin/kubectl
fi

if ! command -v helm >/dev/null 2>&1; then
	curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
