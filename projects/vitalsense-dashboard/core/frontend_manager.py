import subprocess


class FrontendManager:
    def __init__(self):
        self.process = None

    def start(self):
        import os
        frontend_path = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "frontend"
        )

        # FIX (Issue 4 - browser cache): `python3 -m http.server` sends no
        # Cache-Control headers at all, so browsers apply their own default
        # heuristic caching to the served HTML/JS/CSS and can keep showing
        # a stale build until the cache is manually cleared. This inline
        # server serves the exact same directory on the exact same port as
        # before, but attaches explicit no-cache headers to every response
        # so the browser always re-fetches the latest build automatically
        # -- no manual cache clearing required during local development.
        cache_busting_server_code = """
import http.server
import socketserver


class NoCacheHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()


class ReusableTCPServer(socketserver.TCPServer):
    allow_reuse_address = True


with ReusableTCPServer(("", 8080), NoCacheHandler) as httpd:
    httpd.serve_forever()
"""

        self.process = subprocess.Popen(
            ["python3", "-c", cache_busting_server_code],
            cwd=frontend_path,
        )

    def stop(self):
        if self.process:
            self.process.terminate()
