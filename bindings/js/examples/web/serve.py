#!/usr/bin/env python3
"""Static file server with HTTP Range support, on 0.0.0.0:$PORT (default 3000).

pmtiles reads a .pmtiles archive via HTTP Range requests (the header, directory and
each tile are byte ranges). Python's stock http.server ignores Range and returns
200 with the whole file, which breaks pmtiles ("missing tiles"). This serves 206
Partial Content for Range requests. Run from the directory you want to serve."""
import http.server
import os
import re
import socketserver

PORT = int(os.environ.get("PORT", "3000"))


class RangeHandler(http.server.SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"  # keep-alive + proper range semantics

    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")  # allow cross-origin fetch
        self.send_header("Cache-Control", "no-store")  # always serve fresh (no stale app.js)
        super().end_headers()

    def do_GET(self):
        rng = self.headers.get("Range")
        if not rng:
            return super().do_GET()
        path = self.translate_path(self.path)
        if os.path.isdir(path):
            return super().do_GET()
        m = re.match(r"bytes=(\d*)-(\d*)$", rng.strip())
        if not m:
            return super().do_GET()
        try:
            f = open(path, "rb")
        except OSError:
            return self.send_error(404)
        try:
            size = os.fstat(f.fileno()).st_size
            g1, g2 = m.group(1), m.group(2)
            if g1 == "":  # suffix range: last N bytes
                start, end = max(0, size - int(g2)), size - 1
            else:
                start = int(g1)
                end = int(g2) if g2 else size - 1
            if start >= size:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.end_headers()
                return
            end = min(end, size - 1)
            length = end - start + 1
            self.send_response(206)
            self.send_header("Content-Type", self.guess_type(path))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.send_header("Content-Length", str(length))
            self.end_headers()
            f.seek(start)
            remaining = length
            while remaining > 0:
                chunk = f.read(min(1 << 16, remaining))
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    break  # client aborted (normal for tile readers) — don't crash
                remaining -= len(chunk)
        finally:
            f.close()


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    os.chdir(os.path.dirname(os.path.abspath(__file__)))  # serve the demo dir
    with Server(("0.0.0.0", PORT), RangeHandler) as httpd:
        print(f"serving (range-capable) on http://0.0.0.0:{PORT}/", flush=True)
        httpd.serve_forever()
