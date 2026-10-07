#!/bin/bash

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
	exec sudo -E bash "$0" "$@"
fi

apt-get update -y
apt-get install -y git uuid-runtime

TOKEN=$(uuidgen)

get_pod() {
	kubectl get pod -n gitlab -l app=webservice -o jsonpath='{.items[0].metadata.name}'
}

kubectl -n gitlab exec -i "$(get_pod)" -- /srv/gitlab/bin/rails console <<EOF
token = User.find_by_username('root').personal_access_tokens.create(scopes: [:api, :sudo, :read_user, :read_repository, :write_repository], name: 'Root token', expires_at: 365.days.from_now)
token.set_token('$TOKEN')
token.save!
EOF

sleep 10

if ! curl -fsS -H "Content-Type: application/json" \
	"http://localhost:8181/api/v4/projects?private_token=$TOKEN" \
	-d '{ "name": "service", "visibility": "public" }'; then
	echo "Project may already exist, continuing."
fi

echo

DIR=$(mktemp -d /tmp/git-service-XXXXXX)

git clone "http://localhost:8181/root/service.git" "$DIR"

cp confs/wil-app.yml "$DIR/wil-app.yml"
cd "$DIR"

git config user.email "admin@gitlab.local"
git config user.name "Admin"

git add wil-app.yml
git commit -m "Deploy playground v1" || true
git push "http://root:$TOKEN@localhost:8181/root/service.git"
