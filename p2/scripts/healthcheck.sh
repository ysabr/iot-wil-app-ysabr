#!/bin/bash

set -euo pipefail

SERVER_IP="${SERVER_IP:-192.168.56.110}"

check_app() {
	local host="$1"
	local expected="$2"
	local label="$3"
	local body

	for attempt in $(seq 1 90); do
		if [ -n "$host" ]; then
			body=$(curl --noproxy '*' --connect-timeout 3 --max-time 5 -fsS -H "Host: $host" "http://$SERVER_IP" || true)
		else
			body=$(curl --noproxy '*' --connect-timeout 3 --max-time 5 -fsS "http://$SERVER_IP" || true)
		fi

		if echo "$body" | grep -qiF "$expected"; then
			echo "$label is reachable"
			return 0
		fi

		echo "Waiting for $label... ($attempt/90)"
		sleep 2
	done

	echo "$label did not return expected content: $expected"
	return 1
}

kubectl rollout status deployment/app1 --timeout=300s
kubectl rollout status deployment/app2 --timeout=300s
kubectl rollout status deployment/app3 --timeout=300s

check_app "app1.com" "hello from app1" "app1.com"
check_app "app2.com" "hello from app2" "app2.com"
check_app "" "hello from app3" "default app3"
check_app "unknown.example" "hello from app3" "unmatched host app3"

exit 0
