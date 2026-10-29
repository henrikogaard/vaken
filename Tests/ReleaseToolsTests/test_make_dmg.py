import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
STUB = r'''
import os, pathlib, shutil, sys
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
if name == 'ditto':
    shutil.copytree(args[0], args[1], symlinks=True)
elif name == 'hdiutil':
    source = pathlib.Path(args[args.index('-srcfolder') + 1])
    assert sorted(p.name for p in source.iterdir()) == ['Applications', 'Vaken.app']
    assert (source / 'Applications').is_symlink()
    assert os.readlink(source / 'Applications') == '/Applications'
    if os.environ.get('TEST_FAIL_IMAGE'):
        sys.exit(1)
    pathlib.Path(args[-1]).write_bytes(b'fake-read-only-image')
elif name == 'xcrun':
    counter = pathlib.Path(os.environ['TEST_STAPLER_COUNT'])
    count = int(counter.read_text() or '0') + 1 if counter.exists() else 1
    counter.write_text(str(count))
    if count <= int(os.environ.get('TEST_STAPLER_FAILURES', '0')):
        print('The network connection was lost.', file=sys.stderr)
        sys.exit(68)
elif name != 'codesign':
    sys.exit('Unexpected tool')
'''


class MakeDMGTests(unittest.TestCase):
    def run_fixture(self, *, existing=False, fail=False, inside=False, stapler_failures=0):
        with tempfile.TemporaryDirectory(prefix="vaken-dmg-test-") as folder:
            root = pathlib.Path(folder)
            app = root / "Vaken.app"
            app.mkdir()
            (app / "fixture").write_text("app data")
            tools = root / "tools"
            tools.mkdir()
            stub = tools / "tool.py"
            stub.write_text("#!" + sys.executable + "\n" + STUB)
            stub.chmod(0o700)
            for name in ["ditto", "hdiutil", "codesign", "xcrun"]:
                (tools / name).symlink_to(stub)
            output = (app if inside else root) / "Vaken.dmg"
            if existing:
                output.write_bytes(b"existing-user-file")
            env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"], VAKEN_RETRY_DELAY="0",
                       TEST_STAPLER_COUNT=str(root / "stapler-count"), TEST_STAPLER_FAILURES=str(stapler_failures))
            if fail:
                env["TEST_FAIL_IMAGE"] = "1"
            result = subprocess.run(["bash", str(ROOT / "scripts/make-dmg.sh"), str(app), str(output)],
                                    env=env, capture_output=True, text=True)
            self.assertFalse(list(root.glob(".vaken-dmg-*")), "Staging directory leaked")
            self.stapler_calls = int((root / "stapler-count").read_text()) if (root / "stapler-count").exists() else 0
            return result, output.read_bytes() if output.exists() else None

    def test_image_contains_app_and_applications_link(self):
        result, output = self.run_fixture()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, b"fake-read-only-image")

    def test_transient_stapler_failure_is_retried(self):
        result, output = self.run_fixture(stapler_failures=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.stapler_calls, 2)
        self.assertEqual(output, b"fake-read-only-image")

    def test_permanent_stapler_failure_fails_with_original_status(self):
        result, output = self.run_fixture(stapler_failures=99)
        self.assertEqual(result.returncode, 68)
        self.assertEqual(self.stapler_calls, 3)
        self.assertIsNone(output)

    def test_existing_image_is_not_overwritten(self):
        result, output = self.run_fixture(existing=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output, b"existing-user-file")

    def test_image_creation_failure_cleans_staging(self):
        result, output = self.run_fixture(fail=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(output)

    def test_output_cannot_modify_the_source_app(self):
        result, output = self.run_fixture(inside=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(output)


if __name__ == "__main__":
    unittest.main()
