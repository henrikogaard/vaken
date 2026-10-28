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
elif name not in ['codesign', 'xcrun']:
    sys.exit('Unexpected tool')
'''


class MakeDMGTests(unittest.TestCase):
    def run_fixture(self, *, existing=False, fail=False, inside=False):
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
            env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"])
            if fail:
                env["TEST_FAIL_IMAGE"] = "1"
            result = subprocess.run(["bash", str(ROOT / "scripts/make-dmg.sh"), str(app), str(output)],
                                    env=env, capture_output=True, text=True)
            self.assertFalse(list(root.glob(".vaken-dmg-*")), "Staging directory leaked")
            return result, output.read_bytes() if output.exists() else None

    def test_image_contains_app_and_applications_link(self):
        result, output = self.run_fixture()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, b"fake-read-only-image")

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
