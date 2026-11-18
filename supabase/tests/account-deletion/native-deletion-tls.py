"""Loopback-only TLS gateway for native deletion acceptance."""

import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import ssl
import sys
import threading
from urllib.parse import parse_qs, urlencode, urlsplit

API_PORT = 55471
EDGE_PORT = 55473
TLS_PORT = 55474
ORIGIN = f"https://127.0.0.1:{TLS_PORT}"
ROOT = Path(sys.argv[1]).resolve()
if ROOT.stat().st_mode & 0o077:
    raise SystemExit("Fixture directory must be private (mode 0700).")
runtime = json.loads((ROOT / "runtime.json").read_text())
config = json.loads((ROOT / "actors.json").read_text())
actors = {actor["email"]: actor for actor in config.values()}
hop = {"connection", "content-length", "host", "transfer-encoding", "accept-encoding"}
observed_deletion_count = 0
lock = threading.Lock()

def upstream(method, path, *, port=API_PORT, headers=None, data=None):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=40)
    try:
        conn.request(method, path, data, headers or {})
        response = conn.getresponse()
        return response.status, response.getheaders(), response.read()
    finally:
        conn.close()

def admin(method, path, data=None):
    headers = {"apikey": runtime["service"], "Authorization": "Bearer " + runtime["service"]}
    data = None if data is None else json.dumps(data)
    if data is not None:
        headers["Content-Type"] = "application/json"
    return upstream(method, path, headers=headers, data=data)

def readback(actor):
    status, _, body = admin("GET", "/auth/v1/admin/users/" + actor["id"])
    if status not in (200, 404):
        raise ValueError("Unexpected Auth read status")
    if status == 200 and json.loads(body).get("id") != actor["id"]:
        raise ValueError("Mismatched Auth read")
    data_status, _, rows = admin("GET", "/rest/v1/goals?" + urlencode({"id": "eq." + actor["goal"],
                                                                    "owner_id": "eq." + actor["id"]}))
    if data_status != 200:
        raise ValueError("Unexpected row read status")
    storage_status, _, object_bytes = admin("GET", "/storage/v1/object/uploads/" + actor["path"])
    if storage_status not in (200, 400, 404):
        raise ValueError("Unexpected Storage read status")
    if storage_status == 200 and object_bytes != actor["label"].encode():
        raise ValueError("Expected exact Storage bytes")
    return {"auth_exists": status == 200, "goal_exists": len(json.loads(rows)) == 1,
            "object_exists": storage_status == 200}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def emit(self, status, obj):
        self.respond(status, [("Content-Type", "application/json")], json.dumps(obj).encode())

    def respond(self, status, headers, raw):
        self.send_response(status)
        for key, value in headers:
            if key.lower() not in hop:
                self.send_header(key, value)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def qa(self, url):
        if self.command != "GET":
            self.emit(405, {})
            return
        if url.path == "/qa/ready":
            self.emit(200, {"target_id": config["target"]["id"], "witness_id": config["witness"]["id"], "origin": ORIGIN})
        elif url.path == "/qa/otp":
            emails = parse_qs(url.query).get("email") or []
            if len(emails) != 1 or emails[0] not in actors:
                self.emit(400, {})
                return
            status, _, raw = admin("POST", "/auth/v1/admin/generate_link", {"type": "magiclink", "email": emails[0]})
            if status != 200:
                self.emit(502, {})
                return
            self.emit(200, {"code": json.loads(raw)["email_otp"]})
        elif url.path == "/qa/evidence":
            with lock:
                count = observed_deletion_count
            self.emit(200, {"target": readback(config["target"]), "witness": readback(config["witness"]),
                            "native_deletion_count": count})
        else:
            self.emit(404, {})

    def dispatch(self):
        global observed_deletion_count
        url = urlsplit(self.path)
        try:
            if url.path.startswith("/qa/"):
                self.qa(url)
                return
            if url.path in ("/functions/v1/deleteUserData-staged", "/functions/v1/guardedStorageUpload"):
                port = EDGE_PORT
            elif url.path.startswith(("/auth/v1/", "/rest/v1/", "/storage/v1/")) and "/admin/" not in url.path:
                port = API_PORT
            else:
                self.emit(404, {})
                return
            raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            headers = {key: value for key, value in self.headers.items() if key.lower() not in hop}
            response = upstream(self.command, self.path, port=port, headers=headers, data=raw or None)
            if self.command == "POST" and url.path == "/functions/v1/deleteUserData-staged":
                if response[0] == 200:
                    with lock:
                        observed_deletion_count += 1
                print(f"POST staged deletion returned HTTP {response[0]}.", flush=True)
            self.respond(*response)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLEOFError):
            return
        except (ValueError, KeyError, OSError, http.client.HTTPException) as error:
            print("Fixture gateway failure:", type(error).__name__, flush=True)
            self.emit(502, {})

    do_GET = do_POST = do_OPTIONS = do_DELETE = do_PATCH = dispatch

server = ThreadingHTTPServer(("127.0.0.1", TLS_PORT), Handler)
tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls.load_cert_chain(ROOT / "tls.crt", ROOT / "tls.key")
server.socket = tls.wrap_socket(server.socket, server_side=True)
server.serve_forever()
