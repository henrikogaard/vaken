"""Exercise orchestration with fake credentials and tools, never a real keychain/API."""
import base64
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
TOOLS = r'''
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['TEST_LOG'], 'a') as log:
    log.write(json.dumps([name, args[0] if args else '']) + '\n')
if name == 'uname':
    print('arm64')
elif name == 'uuidgen':
    print('temporary-test-password')
elif name == 'security':
    if args[0] == 'find-identity':
        print('Developer ID Application: Henrik Ogard (45AD7E7G5G)')
    if args[0] == 'import' and os.environ.get('TEST_FAIL_IMPORT'):
        sys.exit(1)
elif name == 'bash':
    if args[0] == 'scripts/make-app.sh':
        for secret in ['APPLE_CERTIFICATE_P12', 'APPLE_CERTIFICATE_PASSWORD', 'APPLE_NOTARY_KEY_P8', 'SPARKLE_PRIVATE_KEY']:
            assert secret not in os.environ, 'Private values inherited by build tools'
        target = pathlib.Path('build/Vaken.app/Contents/MacOS/vaken')
        target.parent.mkdir(parents=True)
        target.write_text('#!' + sys.executable + '\nimport sys\nprint("1" if "--build-number" in sys.argv else "0.1.0")\n')
        target.chmod(0o700)
    elif args[0] == 'scripts/prepare-update.sh':
        key = pathlib.Path(os.environ['VAKEN_SPARKLE_KEY_FILE'])
        assert key.stat().st_mode & 0o077 == 0
        assert key.read_text() == 'fake-sparkle-key'
        output = pathlib.Path(args[-1])
        output.mkdir(parents=True)
        (output / 'Vaken.zip').write_bytes(b'fake-archive')
        (output / 'appcast.xml').write_text('<rss/>')
    elif args[0] == 'scripts/make-dmg.sh':
        pathlib.Path(args[-1]).write_bytes(b'fake-dmg')
    else:
        sys.exit('Unexpected bash child')
elif name == 'ditto':
    pathlib.Path(args[-1]).write_bytes(b'fake-notarization-archive')
elif name == 'xcrun':
    if args[:2] == ['notarytool', 'submit']:
        key = pathlib.Path(args[args.index('--key') + 1])
        assert key.stat().st_mode & 0o077 == 0
        assert key.read_bytes() == b'fake-notary-key'
        log = [json.loads(line) for line in pathlib.Path(os.environ['TEST_LOG']).read_text().splitlines()]
        count = sum(entry == ['xcrun', 'notarytool'] for entry in log)
        status = os.environ.get('TEST_DMG_NOTARY_STATUS' if count == 2 else 'TEST_NOTARY_STATUS', 'Accepted')
        print(json.dumps({'status': status}))
elif name not in ['codesign', 'spctl']:
    sys.exit('Unexpected stub tool')
'''


class CIReleaseTests(unittest.TestCase):
    def run_fixture(self, **changes):
        with tempfile.TemporaryDirectory(prefix="vaken-ci-release-") as directory:
            root = pathlib.Path(directory)
            (root / "scripts").mkdir()
            script = root / "scripts/ci-release.sh"
            shutil.copyfile(ROOT / "scripts/ci-release.sh", script)
            runner = root / "runner"
            runner.mkdir()
            tools = root / "tools"
            tools.mkdir()
            tool = tools / "tool.py"
            tool.write_text("#!" + sys.executable + "\n" + TOOLS)
            tool.chmod(0o700)
            for name in ["security", "uname", "uuidgen", "bash", "ditto", "xcrun", "codesign", "spctl"]:
                (tools / name).symlink_to(tool)
            log = root / "calls.jsonl"
            env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
                       GITHUB_ACTIONS="true", RUNNER_ENVIRONMENT="github-hosted", RUNNER_TEMP=str(runner),
                       APPLE_CERTIFICATE_P12=base64.b64encode(b"fake-certificate").decode(),
                       APPLE_CERTIFICATE_PASSWORD="fake-password",
                       APPLE_NOTARY_KEY_P8=base64.b64encode(b"fake-notary-key").decode(),
                       APPLE_NOTARY_KEY_ID="fake-id", APPLE_NOTARY_ISSUER_ID="fake-issuer",
                       SPARKLE_PRIVATE_KEY="fake-sparkle-key", VAKEN_PUBLIC_ED_KEY="fake-public-key",
                       VAKEN_FEED_URL="https://example.com/appcast.xml", VAKEN_BUILD_NUMBER="1",
                       VAKEN_VERSION="0.1.0", VAKEN_DOWNLOAD_PREFIX="https://example.com/v0.1.0/", TEST_LOG=str(log))
            env.update(changes)
            result = subprocess.run(["/bin/bash", str(script)], env=env, capture_output=True, text=True)
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            assets = sorted(p.name for p in (root / "build/release-assets").glob("*"))
            self.assertEqual(list(runner.iterdir()), [], "Temporary credentials were not cleaned up")
            for secret in ["fake-password", "fake-notary-key", "fake-sparkle-key"]:
                self.assertNotIn(secret, result.stdout + result.stderr)
            return result, calls, assets

    def test_success_prepares_only_distribution_assets_and_cleans_credentials(self):
        result, calls, assets = self.run_fixture()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(assets, ["SHA256SUMS", "Vaken.dmg", "Vaken.dmg.sha256", "Vaken.zip", "appcast.xml"])
        self.assertIn(["security", "delete-keychain"], calls)

    def test_notarization_rejection_does_not_produce_assets(self):
        result, calls, assets = self.run_fixture(TEST_NOTARY_STATUS="Invalid")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(assets, [])
        self.assertIn(["security", "delete-keychain"], calls)

    def test_import_failure_also_cleans_credentials(self):
        result, calls, assets = self.run_fixture(TEST_FAIL_IMPORT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(assets, [])
        self.assertIn(["security", "delete-keychain"], calls)

    def test_dmg_notarization_rejection_blocks_distribution(self):
        result, calls, assets = self.run_fixture(TEST_DMG_NOTARY_STATUS="Invalid")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(assets, [])
        self.assertEqual(calls.count(["xcrun", "notarytool"]), 2)
        self.assertIn(["security", "delete-keychain"], calls)

    def test_local_execution_is_refused_before_keychain_access(self):
        result, calls, assets = self.run_fixture(GITHUB_ACTIONS="false")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])
        self.assertEqual(assets, [])


if __name__ == "__main__":
    unittest.main()
