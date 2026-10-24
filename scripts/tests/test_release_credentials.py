#!/usr/bin/env python3
"""Exercise release credential setup with synthetic values and fake Apple tools."""

import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "setup-release-keychain.sh"
IDENTITY = "A" * 40
SECRETS = {
    "BUILD_CERTIFICATE_BASE64": base64.b64encode(b"synthetic p12 fixture").decode(),
    "P12_PASSWORD": "synthetic-export-password",
    "APPLE_ID": "release@example.com",
    "APPLE_TEAM_ID": "EXAMPLETEAM",
    "APPLE_APP_SPECIFIC_PASSWORD": "synthetic-notary-password",
}
FAKE_TOOL = '''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

program = Path(sys.argv[0]).name
arguments = sys.argv[1:]
with open(os.environ["TOOL_LOG"], "a") as log:
    log.write(json.dumps([program, *arguments]) + "\\n")
if " ".join([program, *arguments[:1]]) == os.environ.get("FAIL_COMMAND"):
    sys.exit(1)
if program == "security" and arguments[0] == "find-identity":
    print(os.environ["FAKE_IDENTITIES"])
'''


class ReleaseCredentialTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        binary = self.root / "bin"
        binary.mkdir()
        for tool in ["security", "xcrun"]:
            path = binary / tool
            path.write_text(FAKE_TOOL)
            path.chmod(0o755)
        self.environment_file = self.root / "github-env"
        self.log = self.root / "tool-log"
        # Do not inherit real credentials or platform bindings into these tests.
        self.environment = {
            "PATH": str(binary) + os.pathsep + os.defpath,
            "RUNNER_TEMP": str(self.root),
            "GITHUB_ENV": str(self.environment_file),
            "TOOL_LOG": str(self.log),
            "FAKE_IDENTITIES": f'  1) {IDENTITY} "Developer ID Application: Example (EXAMPLETEAM)"',
            **SECRETS,
        }

    def run_setup(self, **overrides):
        return subprocess.run(
            ["bash", str(SCRIPT)],
            env={**self.environment, **overrides},
            text=True,
            capture_output=True,
            check=False,
        )

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_each_missing_secret_fails_before_touching_keychain(self):
        for name in SECRETS:
            with self.subTest(secret=name):
                result = self.run_setup(**{name: ""})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"Missing Actions secret: {name}", result.stderr)
                self.assertFalse(self.log.exists())
                self.assertFalse(self.environment_file.exists())

    def test_valid_identity_scopes_credentials_to_temporary_keychain(self):
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        keychain = str(self.root / "macdiff-signing.keychain-db")
        exported = dict(line.split("=", 1) for line in self.environment_file.read_text().splitlines())
        self.assertEqual(exported, {
            "SIGNING_IDENTITY": IDENTITY,
            "SIGNING_KEYCHAIN": keychain,
            "NOTARY_PROFILE": "MacDiff-Notary",
        })
        store = next(call for call in self.calls() if call[:2] == ["xcrun", "notarytool"])
        self.assertEqual(store[2:6], ["store-credentials", "MacDiff-Notary", "--keychain", keychain])
        self.assertFalse((self.root / "macdiff-signing.p12").exists())
        for secret in [SECRETS["P12_PASSWORD"], SECRETS["APPLE_APP_SPECIFIC_PASSWORD"]]:
            self.assertNotIn(secret, result.stdout + result.stderr + self.environment_file.read_text())

    def test_development_identity_cannot_be_used_for_release(self):
        result = self.run_setup(FAKE_IDENTITIES=f'  1) {IDENTITY} "Apple Development: Example"')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.environment_file.exists())
        self.assertFalse(any(call[0] == "xcrun" for call in self.calls()))

    def test_ambiguous_developer_identities_are_rejected(self):
        identity = self.environment["FAKE_IDENTITIES"]
        result = self.run_setup(FAKE_IDENTITIES=identity + "\n" + identity.replace(IDENTITY, "B" * 40))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.environment_file.exists())

    def test_failed_import_removes_certificate_and_exports_no_identity(self):
        result = self.run_setup(FAIL_COMMAND="security import")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "macdiff-signing.p12").exists())
        self.assertFalse(self.environment_file.exists())

    def test_invalid_notary_credentials_export_no_identity(self):
        result = self.run_setup(FAIL_COMMAND="xcrun notarytool")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "macdiff-signing.p12").exists())
        self.assertFalse(self.environment_file.exists())

    def test_invalid_base64_fails_before_import(self):
        result = self.run_setup(BUILD_CERTIFICATE_BASE64="invalid!")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())
        self.assertFalse((self.root / "macdiff-signing.p12").exists())


if __name__ == "__main__":
    unittest.main()
