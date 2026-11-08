import json
import tempfile
import threading
import unittest
from datetime import datetime, timezone
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

import sso_origin


class OriginHandlerTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.root = Path(self.temporary_directory.name)
        self.config_file = self.root / "root/config/1.2.1/ssoconf.xml"
        self.config_file.parent.mkdir(parents=True)
        self.config_file.write_bytes(b"<config>test</config>")
        self.upload_directory = self.root / "root/bigquery"
        self.upload_directory.mkdir(parents=True)
        self.log_file = self.root / "sso-logs/uploads.jsonl"
        self.log_file.parent.mkdir()

        patches = (
            patch.object(sso_origin, "CONFIG_FILE", self.config_file),
            patch.object(sso_origin, "UPLOAD_DIRECTORY", self.upload_directory),
            patch.object(sso_origin, "UPLOAD_AUDIT_FILE", self.log_file),
            patch.object(sso_origin, "MAX_BODY_BYTES", 1024),
        )
        for patcher in patches:
            patcher.start()
            self.addCleanup(patcher.stop)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), sso_origin.OriginHandler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.start()
        self.addCleanup(self.stop_server)
        self.connection = HTTPConnection("127.0.0.1", self.server.server_port)
        self.addCleanup(self.connection.close)

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def test_get_returns_xml(self):
        self.connection.request("GET", "/config/1.2.1/ssoconf.xml")
        response = self.connection.getresponse()

        self.assertEqual(response.status, 200)
        self.assertEqual(response.getheader("Content-Type"), "application/xml; charset=utf-8")
        self.assertEqual(response.read(), b"<config>test</config>")

    def test_get_unknown_path_returns_404(self):
        self.connection.request("GET", "/")

        self.assertEqual(self.connection.getresponse().status, 404)

    def test_get_missing_xml_returns_404(self):
        self.config_file.unlink()
        self.connection.request("GET", "/config/1.2.1/ssoconf.xml")

        self.assertEqual(self.connection.getresponse().status, 404)

    def test_post_stores_body_as_jsonl_and_returns_no_content(self):
        payload = json.dumps({"filename": "hello.txt", "content": "hello"})
        self.connection.request(
            "POST",
            "/sso/log",
            body=payload,
            headers={"Content-Type": "application/json; charset=utf-8"},
        )
        response = self.connection.getresponse()

        self.assertEqual(response.status, 204)
        record = json.loads(self.log_file.read_text().strip())
        stored_file = self.upload_directory / record["stored_filename"]
        self.assertEqual(record["original_filename"], "hello.txt")
        self.assertRegex(record["stored_filename"], r"^\d{8}T\d{6}\.\d{6}Z$")
        self.assertEqual(record["content_type"], "application/json; charset=utf-8")
        self.assertEqual(record["file_size_bytes"], 5)
        self.assertEqual(stored_file.read_bytes(), b"hello")
        self.assertEqual(stored_file.stat().st_mode & 0o777, 0o600)
        self.assertIn("received_at", record)

    def test_post_rejects_oversized_body(self):
        self.connection.request("POST", "/sso/log", body=b"x" * 1025)

        self.assertEqual(self.connection.getresponse().status, 413)

    def test_post_rejects_invalid_json(self):
        self.connection.request("POST", "/sso/log", body=b"not-json")

        self.assertEqual(self.connection.getresponse().status, 400)
        self.assertEqual(list(self.upload_directory.iterdir()), [])

    def test_post_rejects_missing_content(self):
        payload = json.dumps({"filename": "hello.txt"})
        self.connection.request("POST", "/sso/log", body=payload)

        self.assertEqual(self.connection.getresponse().status, 400)
        self.assertEqual(list(self.upload_directory.iterdir()), [])

    def test_post_unknown_path_returns_404(self):
        self.connection.request("POST", "/", body=b"log")

        self.assertEqual(self.connection.getresponse().status, 404)

    def test_timestamp_collision_creates_unique_name(self):
        received_at = datetime(2026, 11, 8, 13, 30, 0, 123456, tzinfo=timezone.utc)
        first = sso_origin.store_upload(b"first", received_at)
        second = sso_origin.store_upload(b"second", received_at)

        self.assertEqual(first, "20261108T133000.123456Z")
        self.assertEqual(second, "20261108T133000.123456Z-1")
        self.assertEqual((self.upload_directory / second).read_bytes(), b"second")

    def test_put_returns_method_not_allowed(self):
        self.connection.request("PUT", "/sso/log", body=b"log")

        self.assertEqual(self.connection.getresponse().status, 405)


if __name__ == "__main__":
    unittest.main()
