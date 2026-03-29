#!/usr/bin/env python3

import json
import os
import subprocess
import sys
import tempfile
from urllib.parse import unquote
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


JAVA_PID = sys.argv[1] if len(sys.argv) > 1 else ""
PORT = int(os.environ.get("VIRTUAL_MEDIA_API_PORT", "5891"))
MEDIA_ROOT = "/vmedia"
MEDIA_EXTENSIONS = (".iso", ".img", ".ima")
UPLOAD_CHUNK_SIZE = 1024 * 1024
MAX_UPLOAD_BYTES = int(
    os.environ.get("VIRTUAL_MEDIA_UPLOAD_MAX_BYTES", str(20 * 1024 * 1024 * 1024))
)


def spawn(command, extra_env=None):
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)

    subprocess.Popen(
        command,
        env=env,
        close_fds=True,
    )


def list_virtual_media_files():
    if not os.path.isdir(MEDIA_ROOT):
        return []

    files = []
    for root, _, names in os.walk(MEDIA_ROOT):
        for name in names:
            if not name.lower().endswith(MEDIA_EXTENSIONS):
                continue
            full_path = os.path.join(root, name)
            relative_path = os.path.relpath(full_path, MEDIA_ROOT)
            files.append(relative_path)
    files.sort()
    return files


def validate_media_file(relative_path):
    if not relative_path or relative_path.startswith("/"):
        return None

    normalized = os.path.normpath(relative_path)
    if normalized.startswith("..") or normalized == ".":
        return None

    full_path = os.path.join(MEDIA_ROOT, normalized)
    if not os.path.isfile(full_path):
        return None

    return normalized


def sanitize_upload_filename(raw_name):
    if not raw_name:
        return None

    decoded = unquote(str(raw_name)).strip().replace("\\", "/")
    base_name = os.path.basename(decoded)
    if not base_name or base_name in {".", ".."}:
        return None

    lowered = base_name.lower()
    if not lowered.endswith(MEDIA_EXTENSIONS):
        return None

    return base_name


def choose_upload_name(base_name):
    name_root, extension = os.path.splitext(base_name)
    candidate = base_name
    suffix = 1

    while os.path.exists(os.path.join(MEDIA_ROOT, candidate)):
        suffix += 1
        candidate = f"{name_root}-{suffix}{extension}"

    return candidate


def delete_media_file(relative_path):
    normalized = validate_media_file(relative_path)
    if not normalized:
        return None

    full_path = os.path.join(MEDIA_ROOT, normalized)
    os.unlink(full_path)
    return normalized


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def send_json(self, status_code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_json_body(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0:
            return {}

        try:
            return json.loads(self.rfile.read(length).decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError):
            return None

    def handle_upload(self):
        if not os.path.isdir(MEDIA_ROOT):
            os.makedirs(MEDIA_ROOT, exist_ok=True)

        raw_name = self.headers.get("X-File-Name", "")
        file_name = sanitize_upload_filename(raw_name)
        if not file_name:
            self.send_json(400, {"error": "Invalid or missing upload filename"})
            return

        try:
            content_length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            content_length = 0

        if content_length <= 0:
            self.send_json(400, {"error": "Missing upload body"})
            return

        if content_length > MAX_UPLOAD_BYTES:
            self.send_json(
                413,
                {
                    "error": (
                        f"File is larger than the upload limit of "
                        f"{MAX_UPLOAD_BYTES} bytes"
                    )
                },
            )
            return

        final_name = choose_upload_name(file_name)
        suffix = os.path.splitext(final_name)[1]
        temp_path = ""

        try:
            with tempfile.NamedTemporaryFile(
                dir=MEDIA_ROOT,
                prefix=".upload-",
                suffix=suffix,
                delete=False,
            ) as temp_file:
                temp_path = temp_file.name
                remaining = content_length

                while remaining > 0:
                    chunk = self.rfile.read(min(UPLOAD_CHUNK_SIZE, remaining))
                    if not chunk:
                        raise IOError("Upload stream ended unexpectedly")
                    temp_file.write(chunk)
                    remaining -= len(chunk)

            os.replace(temp_path, os.path.join(MEDIA_ROOT, final_name))
        except OSError as exc:
            if temp_path and os.path.exists(temp_path):
                os.unlink(temp_path)
            self.send_json(500, {"error": f"Failed to store upload: {exc}"})
            return
        except Exception as exc:  # pragma: no cover - defensive path
            if temp_path and os.path.exists(temp_path):
                os.unlink(temp_path)
            self.send_json(500, {"error": f"Upload failed: {exc}"})
            return

        self.send_json(
            200,
            {
                "message": f"Uploaded {final_name} to /vmedia",
                "file": final_name,
            },
        )

    def do_GET(self):
        if self.path == "/api/virtual-media/files":
            self.send_json(200, {"files": list_virtual_media_files()})
            return

        self.send_json(404, {"error": "Not found"})

    def do_POST(self):
        if not JAVA_PID:
            if self.path not in {"/api/virtual-media/upload", "/api/virtual-media/delete"}:
                self.send_json(503, {"error": "Java KVM session is not ready"})
                return

        if self.path == "/api/virtual-media/upload":
            self.handle_upload()
            return

        if self.path == "/api/virtual-media/picker":
            spawn(["/virtual-media-ui.sh", JAVA_PID])
            self.send_json(200, {"message": "Opening Virtual Media picker"})
            return

        if self.path == "/api/virtual-media/map":
            payload = self.read_json_body()
            if payload is None:
                self.send_json(400, {"error": "Invalid JSON payload"})
                return

            media_file = validate_media_file(str(payload.get("file", "")))
            if not media_file:
                self.send_json(400, {"error": "Invalid or missing media file"})
                return

            spawn(["/mountiso.sh", media_file, JAVA_PID], {"VIRTUAL_MEDIA_START_DELAY": "0"})
            self.send_json(200, {"message": f"Mapping {media_file} into Dell Virtual Media"})
            return

        if self.path == "/api/virtual-media/delete":
            payload = self.read_json_body()
            if payload is None:
                self.send_json(400, {"error": "Invalid JSON payload"})
                return

            media_file = str(payload.get("file", ""))
            try:
                deleted_file = delete_media_file(media_file)
            except OSError as exc:
                self.send_json(500, {"error": f"Failed to delete media file: {exc}"})
                return

            if not deleted_file:
                self.send_json(400, {"error": "Invalid or missing media file"})
                return

            self.send_json(200, {"message": f"Deleted {deleted_file} from /vmedia", "file": deleted_file})
            return

        self.send_json(404, {"error": "Not found"})


class ReusableServer(ThreadingHTTPServer):
    allow_reuse_address = True


def main():
    server = ReusableServer(("127.0.0.1", PORT), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
