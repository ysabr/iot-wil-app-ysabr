import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest


PROJECT = Path(__file__).resolve().parents[1]
MOCK_TOOL = r'''#!/usr/bin/env python3
import os
from pathlib import Path
import sys
import time

tool = Path(sys.argv[0]).name
if tool == "id":
    print("0")
elif tool == "pgrep":
    sys.exit(1)
elif tool == "kubectl" and sys.argv[1] == "port-forward":
    target = sys.argv[2].split("/")[-1]
    counter = Path(os.environ["TEST_PORT_DIR"]) / target
    attempts = int(counter.read_text()) if counter.exists() else 0
    pending = counter.with_suffix(".tmp")
    pending.write_text(str(attempts + 1))
    pending.replace(counter)
    if attempts == 0:
        sys.exit(1)
    time.sleep(30)
'''


class PortForwardTest(unittest.TestCase):
    def test_retry_after_disconnect(self):
        scripts = {
            "p3/scripts/port-forward.sh": ["argocd-server"],
            "bonus/scripts/port-forwarding.sh": ["argocd-server", "gitlab-webservice-default"],
        }
        for relative, targets in scripts.items():
            with self.subTest(script=relative), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                binaries = root / "bin"
                binaries.mkdir()
                for name in ("id", "pgrep", "kubectl"):
                    command = binaries / name
                    command.write_text(MOCK_TOOL)
                    command.chmod(0o755)
                script = root / "port-forward.sh"
                script.write_text((PROJECT / relative).read_text().replace("/tmp/", str(root) + "/"))
                process = subprocess.Popen(
                    ["/bin/bash", str(script)],
                    env={
                        **os.environ,
                        "PATH": str(binaries) + os.pathsep + os.environ["PATH"],
                        "TEST_PORT_DIR": str(root),
                    },
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    start_new_session=True,
                )
                try:
                    _, error = process.communicate(timeout=5)
                    self.assertEqual(process.returncode, 0, error)
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline:
                        if all((root / target).exists() and int((root / target).read_text()) >= 2 for target in targets):
                            break
                        time.sleep(0.05)
                    for target in targets:
                        self.assertTrue((root / target).exists(), target)
                        self.assertGreaterEqual(int((root / target).read_text()), 2, target)
                finally:
                    try:
                        os.killpg(process.pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                    process.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
