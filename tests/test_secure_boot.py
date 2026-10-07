import hashlib
import json
import os
from pathlib import Path
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
elif tool == "mokutil":
    if args == ["--sb-state"]:
        if os.environ.get("TEST_EFI_ERROR") == "1":
            sys.exit("Cannot read EFI variables")
        print("SecureBoot " + os.environ.get("TEST_SECURE_BOOT", "enabled"))
    elif args[0] == "--test-key":
        certificate = args[1]
        if os.environ.get("TEST_ENROLLED") == "1":
            print(certificate + " is already enrolled")
        elif os.environ.get("TEST_PENDING") == "1":
            print(certificate + " is already in the enrollment request")
        else:
            print(certificate + " is not enrolled")
        # mokutil 0.7.x can return zero for all three messages.
        sys.exit(0)
'''


class SecureBootTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        binaries = self.root / "bin"
        binaries.mkdir()
        for tool in ("id", "mokutil", "rcvboxdrv", "modprobe"):
            command = binaries / tool
            command.write_text(MOCK_TOOL)
            command.chmod(0o755)
        self.log = self.root / "calls.jsonl"
        self.mok = self.root / "mok"
        self.script = self.root / "fix-secure-boot.sh"
        source = (PROJECT / "p1/scripts/fix-secure-boot.sh").read_text()
        source = source.replace('export PATH="/usr/sbin:/usr/bin:/sbin:/bin:$PATH"', "")
        source = source.replace("MOK_DIR=/var/lib/shim-signed/mok", f"MOK_DIR={self.mok}")
        self.script.write_text(source)
        self.environment = {
            **os.environ,
            "PATH": str(binaries) + os.pathsep + os.environ["PATH"],
            "TEST_LOG": str(self.log),
        }

    def run_helper(self, **environment):
        self.log.write_text("")
        result = subprocess.run(
            ["/bin/bash", str(self.script)],
            env={**self.environment, **environment},
            capture_output=True,
            text=True,
            timeout=15,
        )
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        return result, calls

    def test_enrollment_then_reuse_without_replacing_key(self):
        result, calls = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("enrollment is pending", result.stdout)
        self.assertTrue(any(call[:2] == ["mokutil", "--import"] for call in calls))
        self.assertFalse(any(call[0] in ("rcvboxdrv", "modprobe", "reboot") for call in calls))
        key = self.mok / "MOK.priv"
        certificate = self.mok / "MOK.der"
        original = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in (key, certificate)}
        self.assertEqual(key.stat().st_mode & 0o777, 0o600)
        certificate_info = subprocess.check_output(
            ["openssl", "x509", "-inform", "DER", "-in", str(certificate), "-text", "-noout"],
            text=True,
        )
        self.assertIn("Code Signing", certificate_info)

        result, calls = self.run_helper(TEST_ENROLLED="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(["rcvboxdrv", "setup"], calls)
        self.assertIn(["modprobe", "-a", "vboxdrv", "vboxnetflt", "vboxnetadp"], calls)
        self.assertFalse(any(call[:2] == ["mokutil", "--import"] for call in calls))
        self.assertEqual(original, {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in original})

    def test_incomplete_key_is_preserved_and_rejected(self):
        self.mok.mkdir()
        key = self.mok / "MOK.priv"
        key.write_text("existing key")
        result, calls = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Incomplete signing key pair", result.stderr)
        self.assertEqual(key.read_text(), "existing key")
        self.assertFalse(any(call[:2] == ["mokutil", "--import"] for call in calls))
        self.assertFalse(any(call[0] == "rcvboxdrv" for call in calls))

    def test_pending_enrollment_waits_for_reboot(self):
        result, _ = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)

        result, calls = self.run_helper(TEST_PENDING="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("enrollment is pending", result.stdout)
        self.assertFalse(any(call[:2] == ["mokutil", "--import"] for call in calls))
        self.assertFalse(any(call[0] in ("rcvboxdrv", "modprobe", "reboot") for call in calls))

    def test_disabled_secure_boot_does_not_create_or_enroll_keys(self):
        result, calls = self.run_helper(TEST_SECURE_BOOT="disabled")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.mok.exists())
        self.assertFalse(any(call[:2] == ["mokutil", "--import"] for call in calls))
        self.assertIn(["rcvboxdrv", "setup"], calls)

    def test_unreadable_efi_state_stops_without_changing_keys_or_drivers(self):
        result, calls = self.run_helper(TEST_EFI_ERROR="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Cannot read EFI variables", result.stderr)
        self.assertFalse(self.mok.exists())
        self.assertFalse(any(call[0] in ("rcvboxdrv", "modprobe") for call in calls))


if __name__ == "__main__":
    unittest.main()
