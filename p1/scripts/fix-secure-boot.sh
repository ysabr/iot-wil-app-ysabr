#!/bin/bash

set -euo pipefail
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

if [ "$(id -u)" -ne 0 ]; then
	exec sudo bash "$0" "$@"
fi

for tool in mokutil openssl rcvboxdrv modprobe; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "Missing $tool. Run sudo bash p1/scripts/install-host.sh first." >&2
		exit 1
	fi
done

SECURE_BOOT_STATE=$(mokutil --sb-state)
if ! grep -q 'SecureBoot enabled' <<<"$SECURE_BOOT_STATE"; then
	echo "Secure Boot is not enabled; no signing certificate enrollment is needed."
	rcvboxdrv setup
	modprobe -a vboxdrv vboxnetflt vboxnetadp
	exit 0
fi

# Oracle's package reuses these keys when rebuilding modules after updates.
MOK_DIR=/var/lib/shim-signed/mok
KEY="$MOK_DIR/MOK.priv"
CERT="$MOK_DIR/MOK.der"
umask 077
install -d -m 0700 "$MOK_DIR"

if [ ! -e "$KEY" ] && [ ! -e "$CERT" ]; then
	openssl req -new -x509 -newkey rsa:2048 -nodes \
		-keyout "$KEY" -outform DER -out "$CERT" -days 3650 \
		-subj '/CN=Local VirtualBox Module Signing/' \
		-addext 'extendedKeyUsage=codeSigning'
elif [ ! -s "$KEY" ] || [ ! -s "$CERT" ]; then
	echo "Incomplete signing key pair in $MOK_DIR. Restore both files before continuing." >&2
	exit 1
fi

# Preserve existing keys and check that their certificate belongs to them.
KEY_PUBLIC=$(openssl pkey -in "$KEY" -pubout)
CERT_PUBLIC=$(openssl x509 -inform DER -in "$CERT" -pubkey -noout)
if [ "$KEY_PUBLIC" != "$CERT_PUBLIC" ]; then
	echo "The signing key and certificate in $MOK_DIR do not match." >&2
	exit 1
fi
chmod 0600 "$KEY"
chmod 0644 "$CERT"

show_enrollment_steps() {
	cat <<'EOF'

Certificate enrollment is pending. Save your work, then run sudo reboot.
At the blue MOK Manager screen, choose:
  Enroll MOK -> Continue -> Yes -> enter the password -> Reboot
After logging in, run this script again to build, sign, and load the drivers.
VirtualBox cannot start VMs until enrollment is confirmed at boot.
EOF
}

# mokutil 0.7.x can return success even when its message says that a key is
# not enrolled, so use its C-locale status text rather than its exit status.
MOK_STATUS=$(LC_ALL=C mokutil --test-key "$CERT" 2>&1 || true)
case "$MOK_STATUS" in
*"is already in the enrollment request"*)
	printf '%s\n' "$MOK_STATUS"
	show_enrollment_steps
	exit 0
	;;
*"is already enrolled"* | *"is already in db"* | *"already in the built-in trusted keyring"* | *"Already in kernel trusted keyring"*)
	printf '%s\n' "$MOK_STATUS"
	;;
*"is not enrolled"*)
	printf '%s\n' "$MOK_STATUS"
	echo "Set a temporary enrollment password at the following prompt."
	mokutil --import "$CERT"
	show_enrollment_steps
	exit 0
	;;
*)
	echo "Could not determine whether the VirtualBox signing certificate is enrolled:" >&2
	printf '%s\n' "$MOK_STATUS" >&2
	exit 1
	;;
esac

rcvboxdrv setup
modprobe -a vboxdrv vboxnetflt vboxnetadp
echo "VirtualBox drivers are loaded. Run vagrant up --provider=virtualbox as your regular user."
