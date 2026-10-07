import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
MOCK_TOOL = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

tool = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["TEST_LOG"], "a") as log:
    log.write(json.dumps([tool, *args]) + "\n")
if tool == "id":
    print("0")
elif tool == "k3d" and args[:2] == ["cluster", "list"]:
    print("NAME SERVERS AGENTS LOADBALANCER")
    if os.environ["TEST_EXISTING"] == "1":
        print(os.environ["CLUSTER_NAME"] + " 1/1 0/0 true")
elif tool == "curl":
    print(json.dumps({"data": [{"id": "stable", "latest": "v1.36.0+k3s1"}]}))
elif tool == "jq":
    channels = json.load(sys.stdin)["data"]
    print(next(channel["latest"] for channel in channels if channel["id"] == "stable"))
elif tool == "kubectl":
    if args[:2] == ["create", "namespace"]:
        print("apiVersion: v1\nkind: Namespace\nmetadata:\n  name: " + args[2])
    if "apply" in args and "-f" in args:
        source = args[args.index("-f") + 1]
        if source == "-":
            sys.stdin.read()
        elif source.startswith("https://"):
            if "--server-side" not in args or "--force-conflicts" not in args:
                sys.exit("metadata.annotations: Too long: must have at most 262144 bytes")
        elif not Path(source).is_file():
            sys.exit("Manifest not found: " + source)
    if args[:2] == ["get", "secret"]:
        print("dGVzdA==", end="")
'''


class SetupTest(unittest.TestCase):
    def run_setup(self, part, existing, image_override=True):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = root / part
            fixture.mkdir()
            for name in ("scripts", "confs"):
                shutil.copytree(PROJECT / part / name, fixture / name)
            binaries = root / "bin"
            binaries.mkdir()
            for name in ("id", "docker", "k3d", "kubectl", "helm", "bash", "curl", "jq"):
                command = binaries / name
                command.write_text(MOCK_TOOL)
                command.chmod(0o755)
            log = root / "calls.jsonl"
            environment = {
                **os.environ,
                "PATH": str(binaries) + os.pathsep + os.environ["PATH"],
                "TEST_LOG": str(log),
                "TEST_EXISTING": "1" if existing else "0",
                "CLUSTER_NAME": "test-" + part,
                "K3S_IMAGE": "rancher/k3s:v1.36.0-k3s1",
            }
            if not image_override:
                environment.pop("K3S_IMAGE")
            result = subprocess.run(
                ["/bin/bash", str(fixture / "scripts/setup.sh")],
                cwd=root,
                env=environment,
                capture_output=True,
                text=True,
                timeout=15,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            cluster_changes = [call for call in calls if call[:2] == ["k3d", "cluster"]]
            self.assertFalse(any("delete" in call for call in cluster_changes))
            creates = [call for call in cluster_changes if call[2] == "create"]
            self.assertEqual(len(creates), 0 if existing else 1)
            if not existing:
                self.assertIn("rancher/k3s:v1.36.0-k3s1", creates[0])
            else:
                self.assertTrue(any(call[:3] == ["k3d", "kubeconfig", "merge"] for call in calls))
                self.assertFalse(any(call[0] == "curl" for call in calls))
            argo_install = [
                call for call in calls
                if call[0] == "kubectl" and any(arg.endswith("/manifests/install.yaml") for arg in call)
            ]
            self.assertEqual(len(argo_install), 1)
            self.assertIn("--server-side", argo_install[0])
            self.assertIn("--force-conflicts", argo_install[0])
            established = next(call for call in calls if "--for=condition=Established" in call)
            application = next(call for call in calls if "confs/argocd-deploy.yml" in call)
            self.assertLess(calls.index(established), calls.index(application))
            self.assertTrue(any("statefulset/argocd-application-controller" in call for call in calls))

    def test_fresh_clusters(self):
        for part in ("p3", "bonus"):
            with self.subTest(part=part):
                self.run_setup(part, existing=False)

    def test_recover_existing_clusters(self):
        for part in ("p3", "bonus"):
            with self.subTest(part=part):
                self.run_setup(part, existing=True)

    def test_stable_channel_for_new_clusters(self):
        for part in ("p3", "bonus"):
            with self.subTest(part=part):
                self.run_setup(part, existing=False, image_override=False)


if __name__ == "__main__":
    unittest.main()
