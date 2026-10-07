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

If the installer reports `Key was rejected by service` when loading `vboxdrv`,
Secure Boot is blocking the unsigned VirtualBox kernel driver. Sign the
VirtualBox modules and enroll their signing certificate before starting VMs.
Enrollment requires confirmation in the boot-time MOK manager after a reboot.
See [Debian's Secure Boot documentation](https://wiki.debian.org/SecureBoot)
and [Oracle's installation guide](https://docs.oracle.com/en/virtualization/virtualbox/7.2/user/installation.html).

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
Log in as `admin`. The password can also be read directly:

```bash
sudo kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 --decode
```

The installer updates k3d and selects kubectl to match the existing cluster,
or the stable K3s channel for a fresh cluster. Existing clusters are
reused. The setup installs Argo CD with server-side apply, which avoids the
`metadata.annotations: Too long` error on its ApplicationSet definition.

The configured GitOps source is `https://github.com/ysabr/iot-wil-app-ysabr`.
Argo CD reads `wil-app.yml` at that repository's root. The template is also
included in `p3/confs/wil-app.yml`. To use a different public repository,
publish that template at its root, make sure its name contains a team login,
and update `p3/confs/argocd-deploy.yml` before setup. Without the Git manifest,
Argo CD can start but the playground app cannot sync.

For the v1/v2 demonstration, change the image in the GitHub repository's root
`wil-app.yml` from `wil42/playground:v1` to `wil42/playground:v2`, then commit
and push to `main`. Argo CD updates the deployment automatically. Verify with
`curl http://localhost:8888`; the response should contain `"message": "v2"`.

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

The tests simulate fresh and existing clusters for Part 3 and the bonus, and
verify that port forwarding retries after a disconnect. They do not install
host packages or boot VMs.
Vagrant configuration can be checked with `vagrant validate` from each part.
Use `vagrant validate --ignore-provider` when the VM provider is unavailable;
that checks the configuration without verifying provider options or VM boot.
