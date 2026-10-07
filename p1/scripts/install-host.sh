#!/bin/bash

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
	exec sudo -E bash "$0" "$@"
fi

. /etc/os-release
if [ "$ID" != debian ] || [ "$(dpkg --print-architecture)" != amd64 ]; then
	echo "This host installer supports Debian amd64." >&2
	exit 1
fi

apt-get update
apt-get install -y ca-certificates curl gnupg build-essential dkms "linux-headers-$(uname -r)"
install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://apt.releases.hashicorp.com/gpg | \
	gpg --batch --yes --dearmor -o /etc/apt/keyrings/hashicorp.gpg
curl -fsSL https://www.virtualbox.org/download/oracle_vbox_2016.asc | \
	gpg --batch --yes --dearmor -o /etc/apt/keyrings/oracle-virtualbox.gpg
chmod 0644 /etc/apt/keyrings/hashicorp.gpg /etc/apt/keyrings/oracle-virtualbox.gpg

printf '%s\n' \
	"deb [arch=amd64 signed-by=/etc/apt/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com ${VERSION_CODENAME} main" \
	>/etc/apt/sources.list.d/hashicorp.list
printf '%s\n' \
	"deb [arch=amd64 signed-by=/etc/apt/keyrings/oracle-virtualbox.gpg] https://download.virtualbox.org/virtualbox/debian ${VERSION_CODENAME} contrib" \
	>/etc/apt/sources.list.d/virtualbox.list

apt-get update
apt-get install -y vagrant virtualbox-7.2
modprobe vboxdrv

vagrant --version
VBoxManage --version
echo "Host prerequisites for Parts 1 and 2 are installed. Run vagrant as your regular user."
