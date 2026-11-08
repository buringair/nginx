#!/usr/bin/env python3

import json
import os
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit


CONFIG_ROOT = Path(os.environ.get("SSO_CONFIG_ROOT", "/home/uadmin/nginx/root"))
CONFIG_FILE = CONFIG_ROOT / "config/1.2.1/ssoconf.xml"
UPLOAD_DIRECTORY = Path(os.environ.get("SSO_UPLOAD_DIR", str(CONFIG_ROOT / "bigquery")))
LOG_DIRECTORY = Path(os.environ.get("SSO_LOG_DIR", "/home/uadmin/nginx/sso-logs"))
UPLOAD_AUDIT_FILE = LOG_DIRECTORY / "uploads.jsonl"
MAX_BODY_BYTES = int(os.environ.get("SSO_MAX_BODY_BYTES", "1048576"))
LOG_LOCK = threading.Lock()


def store_upload(content, received_at):
    base_name = received_at.strftime("%Y%m%dT%H%M%S.%fZ")
    suffix = 0

    while True:
        name = base_name if suffix == 0 else f"{base_name}-{suffix}"
        path = UPLOAD_DIRECTORY / name
        try:
            descriptor = os.open(
                path,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
            )
        except FileExistsError:
            suffix += 1
            continue

        try:
            with os.fdopen(descriptor, "wb") as upload_file:
                upload_file.write(content)
        except OSError as write_error:
            try:
                path.unlink()
            except OSError as cleanup_error:
                raise OSError(
                    f"{write_error}; could not remove incomplete upload: {cleanup_error}"
                ) from write_error
            raise

        return name


class OriginHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if urlsplit(self.path).path != "/config/1.2.1/ssoconf.xml":
            self.send_error(404)
            return

        try:
            body = CONFIG_FILE.read_bytes()
        except FileNotFoundError:
            self.log_error("Configuration file is missing: %s", CONFIG_FILE)
            self.send_error(404, "Configuration file not found")
            return
        except OSError as error:
            self.log_error("Could not read configuration file: %s", error)
            self.send_error(500)
            return

        self.send_response(200)
        self.send_header("Content-Type", "application/xml; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if urlsplit(self.path).path != "/sso/log":
            self.send_error(404)
            return

        if self.headers.get("Transfer-Encoding"):
            self.send_error(411, "Content-Length is required")
            return

        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            self.send_error(411, "Content-Length is required")
            return

        if length < 0:
            self.send_error(400, "Invalid Content-Length")
            return
        if length > MAX_BODY_BYTES:
            self.send_error(413, "Request body is too large")
            return

        request_body = self.rfile.read(length)
        if len(request_body) != length:
            self.send_error(400, "Incomplete request body")
            return

        try:
            payload = json.loads(request_body)
        except (UnicodeDecodeError, json.JSONDecodeError):
            self.send_error(400, "Request body must be valid JSON")
            return

        if not isinstance(payload, dict):
            self.send_error(400, "JSON body must be an object")
            return

        original_filename = payload.get("filename")
        file_content = payload.get("content")
        if not isinstance(original_filename, str) or not original_filename.strip():
            self.send_error(400, "JSON filename must be a non-empty string")
            return
        if not isinstance(file_content, str):
            self.send_error(400, "JSON content must be a UTF-8 string")
            return

        received_at = datetime.now(timezone.utc)
        try:
            content = file_content.encode("utf-8")
        except UnicodeEncodeError:
            self.send_error(400, "JSON content cannot be encoded as UTF-8")
            return

        try:
            with LOG_LOCK:
                stored_filename = store_upload(content, received_at)
                record = {
                    "received_at": received_at.isoformat(timespec="microseconds"),
                    "original_filename": original_filename,
                    "stored_filename": stored_filename,
                    "content_type": self.headers.get("Content-Type", ""),
                    "file_size_bytes": len(content),
                }
                encoded_record = json.dumps(record, separators=(",", ":")).encode("utf-8") + b"\n"
                try:
                    descriptor = os.open(
                        UPLOAD_AUDIT_FILE,
                        os.O_WRONLY | os.O_APPEND | os.O_CREAT,
                        0o600,
                    )
                    with os.fdopen(descriptor, "ab") as log_file:
                        log_file.write(encoded_record)
                except OSError:
                    try:
                        (UPLOAD_DIRECTORY / stored_filename).unlink()
                    except OSError as cleanup_error:
                        self.log_error("Could not remove upload after audit-log failure: %s", cleanup_error)
                    raise
        except OSError as error:
            self.log_error("Could not store uploaded file: %s", error)
            self.send_error(500)
            return

        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_DELETE(self):
        self.send_error(405)

    def do_HEAD(self):
        self.send_error(405)

    def do_OPTIONS(self):
        self.send_error(405)

    def do_PATCH(self):
        self.send_error(405)

    def do_PUT(self):
        self.send_error(405)


def main():
    if MAX_BODY_BYTES <= 0:
        raise ValueError("SSO_MAX_BODY_BYTES must be positive")
    if not CONFIG_ROOT.is_dir():
        raise FileNotFoundError(f"Configuration root does not exist: {CONFIG_ROOT}")

    UPLOAD_DIRECTORY.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(UPLOAD_DIRECTORY, 0o700)
    LOG_DIRECTORY.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(LOG_DIRECTORY, 0o700)

    host = os.environ.get("SSO_LISTEN_HOST", "127.0.0.1")
    port = int(os.environ.get("SSO_LISTEN_PORT", "8080"))
    server = ThreadingHTTPServer((host, port), OriginHandler)
    server.daemon_threads = True
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
