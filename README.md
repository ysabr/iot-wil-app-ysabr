# Inception of Things

Infrastructure learning repo built around Vagrant, K3s, K3d, and Argo CD.

## Layout

- `p1`: two Vagrant VMs, one K3s server and one worker.
- `p2`: one Vagrant VM serving three apps through K3s ingress.
- `p3`: K3d + Argo CD setup on a VM.
- `bonus`: local GitLab added to the p3-style setup.

## What to Run

Run the host commands below in your Debian terminal. The project root is:

```bash
cd .
```

Allow memory for each lab: p1 uses 3 GB across two VMs, p2 uses 2 GB,
and the optional p3 VM uses 4 GB. Run one part at a time. The K3s servers
use 2 CPUs and 2 GB, matching the [K3s requirements](https://docs.k3s.io/installation/requirements).
Downloads need an internet connection.

### Fix the current VirtualBox error first

Your log shows that VirtualBox and Vagrant are already installed. Secure Boot
rejects the unsigned `vboxdrv` module, so Vagrant cannot start a VM. The
`No usable default provider` message follows from that driver failure.

From the project root, run:

```bash
sudo bash p1/scripts/fix-secure-boot.sh
```

The helper creates a signing key and certificate at the paths expected by
Oracle's VirtualBox package, preserving an existing pair. Set a temporary
password when `mokutil` asks. Save your work, then reboot yourself:

```bash
sudo reboot
```

At the blue MOK Manager screen choose **Enroll MOK → Continue → Yes**, enter
that temporary password, then choose **Reboot**. This boot-time confirmation
is required; a script cannot complete it from your terminal.

After logging back in:

```bash
cd .
sudo bash p1/scripts/fix-secure-boot.sh
lsmod | grep '^vbox'
VBoxManage --version
```

The second run builds, signs, and loads `vboxdrv`, `vboxnetflt`, and
`vboxnetadp`. Continue when it reports that the drivers are loaded. If it
asks for enrollment again, the boot-time confirmation was not completed.
Oracle's rebuild script reuses this key after upgrades; if a later kernel
update breaks VirtualBox, install that kernel's headers and rerun the helper.
See [Debian's Secure Boot guidance](https://wiki.debian.org/SecureBoot) and
[Oracle's installation guide](https://docs.oracle.com/en/virtualization/virtualbox/7.2/user/installation.html).

For a fresh Debian amd64 machine, install the prerequisites once before using
the helper:

```bash
sudo bash p1/scripts/install-host.sh
```

This installs Vagrant from HashiCorp and VirtualBox 7.2 from Oracle, including
the kernel headers needed for VirtualBox. The VMs use `bento/debian-13`, which
provides Debian 13 images for VirtualBox. Run `vagrant` as your regular user,
without `sudo`.

### Part 1

```bash
cd p1
vagrant up --provider=virtualbox --provision
vagrant ssh ysabrS -c 'sudo k3s kubectl get nodes -o wide'
```

Expect **two Ready nodes**: `ysabrs` at `192.168.56.110` and `ysabrsw`
at `192.168.56.111`. If the worker is still joining, wait inside the server:

```bash
vagrant ssh ysabrS -c 'sudo k3s kubectl wait --for=create node/ysabrsw --timeout=300s'
vagrant ssh ysabrS -c 'sudo k3s kubectl wait --for=condition=Ready nodes --all --timeout=300s'
vagrant ssh ysabrS -c 'sudo k3s kubectl get nodes -o wide'
```

For an interactive server shell use `vagrant ssh ysabrS`; for the worker use
`vagrant ssh ysabrSW`. Inside the server, use `sudo k3s kubectl`. If SSH fails,
you are still on the host: do not run the VM's Kubernetes commands there.
The host's `https://localhost:8080` TLS error in your log is separate from
p1's Kubernetes API.

### Part 2

Halt p1 before starting p2: both use `192.168.56.110` for the server.

```bash
cd p1
vagrant halt
cd ../p2
vagrant up --provider=virtualbox --provision
curl --noproxy '*' -H 'Host: app1.com' http://192.168.56.110
curl --noproxy '*' -H 'Host: app2.com' http://192.168.56.110
curl --noproxy '*' http://192.168.56.110
curl --noproxy '*' -H 'Host: unknown.example' http://192.168.56.110
vagrant ssh ysabrS -c 'sudo k3s kubectl get deployments,pods,services,ingress'
```

Expect **hello from app1**, **hello from app2**, **hello from app3**, and
**hello from app3**, respectively. The app2 deployment should show `3/3`.
`app1.com` and `app2.com` are matched by host name; every other request,
including the bare IP, reaches app3 through the Ingress catch-all rule.
Provisioning runs these healthchecks too. To visit the named apps in your
browser, add `192.168.56.110 app1.com app2.com` to the host's `/etc/hosts`.

For an existing p1/p2 VM, apply changed memory/CPU settings with
`vagrant reload --provision` from its part directory. After a provisioning
failure, `vagrant up --provider=virtualbox --provision` retries setup.

### Part 3

You already have Docker/K3d tooling on this Debian machine. To reuse that
environment, run these commands on the machine where the existing `iot`
cluster runs. This route does not need VirtualBox:

```bash
cd p3
sudo bash scripts/installation.sh && sudo bash scripts/setup.sh
sudo kubectl --context=k3d-iot get nodes
sudo kubectl --context=k3d-iot get applications -n argocd
sudo kubectl --context=k3d-iot get pods,service -n dev
curl --noproxy '*' http://localhost:8888
```

The setup reuses an existing cluster, starts it if stopped, and waits for
Argo CD plus a **Synced / Healthy** application before reporting success.
Expect the app response to contain `"message": "v1"` initially.

For a separate p3 VM instead, halt p1 and p2, ensure host ports 8080 and 8888
are free, and then run from `p3`:

```bash
vagrant up --provider=virtualbox --provision
vagrant ssh -c 'sudo kubectl --context=k3d-iot get applications -n argocd'
curl --noproxy '*' http://localhost:8888
```

The Vagrantfile installs Docker/K3d, runs setup, and forwards the two UI ports.
Check occupied ports with `ss -ltn '( sport = :8080 or sport = :8888 )'`.
Use one p3 route at a time; a host installation already using these ports
conflicts with the VM's forwarded ports. To repair setup inside the p3 VM:

```bash
vagrant ssh
cd /vagrant
sudo bash scripts/setup.sh
```

Then open Argo CD at `https://localhost:8080` and the app at `http://localhost:8888`.
Log in as `admin` with the password printed by setup, or your existing password
if you changed it earlier. Argo CD uses a self-signed certificate for this lab,
so your browser can show a certificate warning. The initial password can also
be read on the machine where K3d runs:

```bash
sudo kubectl --context=k3d-iot get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 --decode
```

If that initial secret was deleted after changing the password, use the
password you set; rerunning setup keeps it.

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

Verify the remote manifest before setup if needed:

```bash
curl -fsSL https://raw.githubusercontent.com/ysabr/iot-wil-app-ysabr/main/wil-app.yml
```

For the v1/v2 demonstration, change the image in the GitHub repository's root
`wil-app.yml` from `wil42/playground:v1` to `wil42/playground:v2`, then commit
and push to `main`. Argo CD updates the deployment automatically. Verify with
`curl --noproxy '*' http://localhost:8888`; the response should contain `"message": "v2"`.

After a failed Part 3 installation, rerun the two scripts from `p3`; the setup
repairs the partial Argo CD installation without deleting the cluster:

```bash
sudo bash scripts/installation.sh && sudo bash scripts/setup.sh
sudo kubectl --context=k3d-iot get pods -n argocd
sudo kubectl --context=k3d-iot get applications -n argocd
```

The Microsoft Teams missing-keyring warning in `apt-get update` comes from a
host APT source. It does not explain the VirtualBox driver or Kubernetes TLS
errors. Repair or disable that source if it prevents package installation.

## Bonus

```bash
cd bonus
sudo bash everything.sh run
```

This creates the `bonus` k3d cluster, installs GitLab with Helm in the `gitlab`
namespace, pushes `confs/wil-app.yml` to a local `root/service` project, and
points Argo CD at it. GitLab needs about 6 GB of free memory and can take up to
15 minutes to start. GitLab is served on `http://localhost:8181` (user `root`);
passwords are saved to `gitlab.password` and `argoCD.password`.

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

The tests simulate Secure Boot enrollment/reuse, fresh and existing clusters,
GitOps and endpoint failures, and port-forward recovery. They do not install
host packages, enroll firmware certificates, or boot VMs.
Vagrant configuration can be checked with `vagrant validate` from each part.
Use `vagrant validate --ignore-provider` when the VM provider is unavailable;
that checks the configuration without verifying provider options or VM boot.
