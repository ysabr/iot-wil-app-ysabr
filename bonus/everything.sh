#!/bin/bash

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
	exec sudo -E bash "$0" "$@"
fi

run() {
	echo -e "\033[1;34m--- INSTALLATION ---\033[0m"
	bash scripts/installation.sh

	echo -e "\033[1;34m--- SETUP ---\033[0m"
	bash scripts/setup.sh
	echo 'OK'
}

stop() {
	k3d cluster delete bonus || true
	rm -f argoCD.password gitlab.password
	echo 'OK'
}

clean() {
	stop
	remove_command helm
	rm -rf ~/.config/helm
	rm -rf ~/.cache/helm
	rm -rf ~/.local/share/helm
	k3d cluster delete -a || true
	remove_command k3d
	remove_command kubectl
	rm -rf ~/.kube
	apt-get remove -y docker-ce docker-ce-cli containerd.io \
		docker-buildx-plugin docker-compose-plugin
	apt autoremove -y
}

remove_command() {
	local path

	path=$(command -v "$1" || true)
	if [ -n "$path" ]; then
		rm -f "$path"
	fi
}

if [ -z "${1:-}" ]; then
	PS3="> "
	select option in run port stop clean; do
		echo $option
		case $option in
		"run")
			run
			exit
			;;
		"port")
			bash scripts/port-forwarding.sh
			exit
			;;
		"stop")
			stop
			exit
			;;
		"clean")
			clean
			exit
			;;
		*)
			echo -e 'Choose from:\nrun (1)\nport (2)\nstop (3)\nclean (4)'
			;;
		esac
	done
else
	case "$1" in
	"run")
		run
		exit
		;;
	"port")
		bash scripts/port-forwarding.sh
		exit
		;;
	"stop")
		stop
		exit
		;;
	"clean")
		clean
		exit
		;;
	*)
		echo "Choose from: run/port/stop/clean"
		exit 1
		;;
	esac
fi
