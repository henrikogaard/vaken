import importlib.util
import pathlib
import unittest
from unittest import mock
from urllib.error import HTTPError

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("release_metadata", ROOT / "scripts/release-metadata.py")
metadata = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(metadata)

SOURCE = 'static let releaseVersion = "0.1.0"\nstatic let releaseBuild = "1"\n'


class ReleaseMetadataTests(unittest.TestCase):
    def test_initial_tag_matches_committed_metadata(self):
        self.assertEqual(metadata.validate_metadata(SOURCE, "v0.1.0"), {"version": "0.1.0", "build": "1"})

    def test_invalid_or_mismatched_tags_are_rejected(self):
        for tag in ["0.1.0", "v0.2.0", "v01.1.0", "v0.1.0-beta.1", "v0.1.0\n", "v0.1.0; echo unsafe"]:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                metadata.validate_metadata(SOURCE, tag)

    def test_invalid_or_duplicate_metadata_is_rejected(self):
        for source in [SOURCE.replace('"1"', '"0"'), SOURCE.replace('"1"', '"01"'),
                       SOURCE.replace('"1"', '"1.2"'), SOURCE + SOURCE, ""]:
            with self.subTest(source=source), self.assertRaises(ValueError):
                metadata.validate_metadata(source, "v0.1.0")

    def test_repository_is_safe_and_canonical(self):
        self.assertEqual(metadata.validate_repository("henrikogaard/vaken"), "henrikogaard/vaken")
        for value in ["owner/repo/path", "owner/repo?token=x", "https://github.com/owner/repo", "owner/..", "owner/repo\n"]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                metadata.validate_repository(value)

    def test_existing_release_is_never_overwritten(self):
        with self.assertRaises(ValueError):
            metadata.validate_remote("owner/repo", "v0.1.0", {"version": "0.1.0", "build": "1"},
                                     lambda path: {"draft": True}, lambda url: b"")

    def test_first_release_needs_no_previous_feed(self):
        metadata.validate_remote("owner/repo", "v0.1.0", {"version": "0.1.0", "build": "1"},
                                 lambda path: None, lambda url: self.fail("No previous feed exists"))

    def test_existing_release_requires_increasing_version_and_build(self):
        latest = {"tag_name": "v0.1.0"}
        api = lambda path: latest if path.endswith("/latest") else None
        feed = lambda url: b'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>1</sparkle:version></item></channel></rss>'
        metadata.validate_remote("owner/repo", "v0.2.0", {"version": "0.2.0", "build": "2"}, api, feed)
        for value in [{"version": "0.1.0", "build": "2"}, {"version": "0.2.0", "build": "1"}]:
            with self.assertRaises(ValueError):
                metadata.validate_remote("owner/repo", "v0.2.0", value, api, feed)

    def test_api_or_feed_errors_do_not_become_a_first_release(self):
        def denied(path):
            raise RuntimeError("API denied")
        with self.assertRaises(RuntimeError):
            metadata.validate_remote("owner/repo", "v0.1.0", {"version": "0.1.0", "build": "1"}, denied, lambda url: b"")
        api = lambda path: {"tag_name": "v0.0.1"} if path.endswith("/latest") else None
        for data in [b"bad XML", b"<rss/>", b"<!DOCTYPE rss><rss/>"]:
            with self.assertRaises(ValueError):
                metadata.validate_remote("owner/repo", "v0.1.0", {"version": "0.1.0", "build": "2"}, api, lambda url: data)

    def test_legacy_enclosure_build_is_supported(self):
        data = b'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><enclosure sparkle:version="8"/></item></channel></rss>'
        self.assertEqual(metadata.published_build(data), 8)

    def test_http_adapter_treats_only_404_as_missing(self):
        for status in [401, 403, 429, 500]:
            error = HTTPError("https://api.github.com/test", status, "blocked", {}, None)
            with self.subTest(status=status), mock.patch.object(metadata.urllib.request, "urlopen", side_effect=error):
                with self.assertRaises(RuntimeError):
                    metadata.github_api("repos/owner/repo/releases/latest")
        error = HTTPError("https://api.github.com/test", 404, "missing", {}, None)
        with mock.patch.object(metadata.urllib.request, "urlopen", side_effect=error):
            self.assertIsNone(metadata.github_api("repos/owner/repo/releases/latest"))


if __name__ == "__main__":
    unittest.main()
