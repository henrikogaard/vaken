"""Public RFC 8032 test vector; no private keys are used or generated."""
import base64
import pathlib
import plistlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PUBLIC = bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
SIGNATURE = bytes.fromhex(
    "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555f"
    "b8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"
)


class AppcastTests(unittest.TestCase):
    def verify(self, *, url="https://example.com/Vaken.zip", version="1", length="0", corrupt=False, element_version=False):
        with tempfile.TemporaryDirectory(prefix="vaken-appcast-") as directory:
            root = pathlib.Path(directory)
            app = root / "Vaken.app" / "Contents"
            app.mkdir(parents=True)
            with (app / "Info.plist").open("wb") as output:
                plistlib.dump({"CFBundleVersion": "1", "SUPublicEDKey": base64.b64encode(PUBLIC).decode()}, output)
            archive = root / "Vaken.zip"
            archive.write_bytes(b"changed" if corrupt else b"")
            feed = root / "appcast.xml"
            signature = base64.b64encode(SIGNATURE).decode()
            version_element = f"<sparkle:version>{version}</sparkle:version>" if element_version else ""
            version_attribute = "" if element_version else f'sparkle:version="{version}"'
            feed.write_text(f'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
                {version_element}<enclosure url="{url}" {version_attribute} length="{length}" sparkle:edSignature="{signature}"/>
                </item></channel></rss>''')
            result = subprocess.run(["swift", str(ROOT / "scripts/verify-appcast.swift"), str(feed), str(archive), str(app.parent)],
                                    capture_output=True, text=True)
            if result.returncode and not (corrupt or version != "1" or length != "0" or url.startswith("http:")):
                self.fail(result.stderr)
            return result.returncode

    def test_public_vector_verifies(self):
        self.assertEqual(self.verify(), 0)

    def test_archive_tampering_rejected_even_with_updated_length(self):
        self.assertNotEqual(self.verify(corrupt=True, length="7"), 0)

    def test_generated_appcast_version_element_verifies(self):
        self.assertEqual(self.verify(element_version=True), 0)

    def test_generated_appcast_wrong_version_rejected(self):
        self.assertNotEqual(self.verify(element_version=True, version="2"), 0)

    def test_wrong_build_rejected(self):
        self.assertNotEqual(self.verify(version="2"), 0)

    def test_non_https_rejected(self):
        self.assertNotEqual(self.verify(url="http://example.com/Vaken.zip"), 0)

    def test_wrong_length_rejected(self):
        self.assertNotEqual(self.verify(length="1"), 0)


if __name__ == "__main__":
    unittest.main()
