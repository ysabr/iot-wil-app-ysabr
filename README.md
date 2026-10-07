# Inception of Things

Infrastructure learning repo built around Vagrant, K3s, K3d, and Argo CD.

## Layout

- `p1`: two Vagrant VMs, one K3s server and one worker.
- `p2`: one Vagrant VM serving three apps through K3s ingress.
- `p3`: K3d + Argo CD setup on a VM.
- `bonus`: local GitLab added to the p3-style setup.

## What to Run

On the Debian amd64 host, install the prerequisites for Parts 1 and 2 once,
from the project root:

```bash
sudo bash p1/scripts/install-host.sh
```

This installs Vagrant from HashiCorp and VirtualBox 7.2 from Oracle, including
the kernel headers needed for VirtualBox. The VMs use `bento/debian-13`, which
provides Debian 13 images for VirtualBox. Run `vagrant` as your regular user.
Start each part's commands below from the project root.

Part 1:

```bash
cd p1
vagrant up
vagrant ssh ysabrS
kubectl get nodes -o wide
exit
vagrant halt
```

Halt Part 1 before starting Part 2: both use `192.168.56.110` for the server.

Part 2:

```bash
cd p2
vagrant up
curl -H 'Host: app1.com' http://192.168.56.110
curl -H 'Host: app2.com' http://192.168.56.110
curl http://192.168.56.110
```

Part 3, from the VM where Docker/K3d should run:

```bash
cd p3
sudo bash scripts/installation.sh
sudo bash scripts/setup.sh
```

Then open Argo CD at `https://localhost:8080` and the app at `http://localhost:8888`.
The Argo CD admin password is printed by `scripts/setup.sh`.

The installer updates k3d and selects kubectl to match the existing cluster,
or the stable K3s channel for a fresh cluster. Existing clusters are
reused. The setup installs Argo CD with server-side apply, which avoids the
`metadata.annotations: Too long` error on its ApplicationSet definition.

Before running Part 3 setup, create the required public GitHub repository for the app manifests,
make sure its name contains `ysabr`, push `p3/confs/wil-app.yml` to it, and update
`p3/confs/argocd-deploy.yml` if your GitHub username or repository name differs.
The configured repository is `https://github.com/ysabr/iot-wil-app-ysabr` and
must contain `wil-app.yml` at its root. Without it, Argo CD can start but the
playground app cannot sync.

After a failed Part 3 installation, rerun the two scripts from `p3`; the setup
repairs the partial Argo CD installation without deleting the cluster:

```bash
sudo bash scripts/installation.sh && sudo bash scripts/setup.sh
sudo kubectl get pods -n argocd
sudo kubectl get applications -n argocd
```

The Microsoft Teams keyring warning in `apt-get update` comes from a host APT
source and is separate from the Argo CD error.

## Bonus

```bash
cd bonus
sudo bash everything.sh run
```

## Notes

- These setups are meant for local learning labs, not production deployment.
- IPs and forwarded ports follow the subject: `192.168.56.110`, `192.168.56.111`,
  Argo CD on `8080`, and the playground app on `8888`.
- `bonus/everything.sh clean` removes local cluster/tooling state and should only be
  used when you really want a reset.

## Checks

```bash
python3 -m unittest discover -s tests -v
find . -type f -name '*.sh' -exec bash -n {} \;
git diff --check
```

The setup tests simulate fresh and existing clusters for Part 3 and the bonus;
they do not install host packages or boot VMs.
