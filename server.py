#!/usr/bin/env python3
"""
WiFi Heatmap - local test server.

Run this on a computer that is connected to your router with an Ethernet cable,
then open the printed address in Safari on your iPhone. Speed tests then measure
only the Wi-Fi link (phone <-> router), not your internet plan.

    python3 server.py          # port 8080
    python3 server.py 9000     # another port

No extra packages needed (Python 3.7+). Works on Windows, macOS and Linux.
"""
import os
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
ROOT = os.path.dirname(os.path.abspath(__file__))
BLOCK = os.urandom(1 << 20)          # 1 MB of random data, reused for downloads
MAX_DOWN = 200_000_000
STATIC = {
    ".html": "text/html; charset=utf-8",
    ".png": "image/png",
    ".webmanifest": "application/manifest+json",
    ".json": "application/json",
    ".js": "text/javascript",
    ".css": "text/css",
}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "WifiHeat/1.0"

    def log_message(self, fmt, *args):
        pass  # keep the console quiet

    def _common(self):
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-WifiHeat", "1")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Expose-Headers", "X-WifiHeat")

    def _empty(self, code=200):
        self.send_response(code)
        self._common()
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_OPTIONS(self):
        self.send_response(204)
        self._common()
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        url = urlparse(self.path)
        path = url.path

        if path == "/ping":
            return self._empty()

        if path == "/down":
            try:
                n = int(parse_qs(url.query).get("bytes", ["0"])[0] or 0)
            except ValueError:
                n = 0
            n = max(0, min(n, MAX_DOWN))
            self.send_response(200)
            self._common()
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(n))
            self.end_headers()
            view = memoryview(BLOCK)
            sent = 0
            try:
                while sent < n:
                    k = min(len(BLOCK), n - sent)
                    self.wfile.write(view[:k])
                    sent += k
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                self.close_connection = True
            return

        # static files from this folder only
        name = "index.html" if path in ("/", "") else os.path.basename(path)
        ext = os.path.splitext(name)[1].lower()
        full = os.path.join(ROOT, name)
        if ext not in STATIC or not os.path.isfile(full):
            return self._empty(404)
        with open(full, "rb") as f:
            body = f.read()
        self.send_response(200)
        self._common()
        self.send_header("Content-Type", STATIC[ext])
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if urlparse(self.path).path != "/up":
            return self._empty(404)
        left = int(self.headers.get("Content-Length") or 0)
        try:
            while left > 0:
                chunk = self.rfile.read(min(left, 1 << 16))
                if not chunk:
                    break
                left -= len(chunk)
        except (ConnectionResetError, ConnectionAbortedError):
            self.close_connection = True
            return
        self._empty()


def lan_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))  # no packet is actually sent
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


if __name__ == "__main__":
    ThreadingHTTPServer.daemon_threads = True
    httpd = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print("WiFi Heatmap test server running.")
    print(f"On your iPhone (same Wi-Fi), open:  http://{lan_ip()}:{PORT}")
    print("Tip: connect this computer to the router with a cable for accurate results.")
    print("Press Ctrl+C to stop.")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
