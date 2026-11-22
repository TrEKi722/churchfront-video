#!/usr/bin/env python3
"""A pretend Churchfront Video web server, for developing and testing the iPad page without the Mac app.

    python3 Tools/fake_web_api.py 9912          # then open http://localhost:9912 (PIN 123456)

It serves the real page (read out of Sources/CueVideo/WebUI.swift) and answers the same endpoints
as Sources/CueVideo/WebServer.swift, keeping a little pretend switcher. GET /_log shows every
action it was sent. It follows the contract as written; it can't show how the Mac app behaves.
"""
import io, json, os, re, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "Sources", "CueVideo", "WebUI.swift")
PIN, TOKEN = "123456", "tok-test"

def page():
    text = open(SRC, encoding="utf-8").read()
    return re.search(r'static let page = #"""\n(.*)\n"""#', text, re.S).group(1)

class Booth:
    def __init__(self):
        self.reset()
    def reset(self):
        self.live, self.next = 2, 1
        self.transition = False; self.black = False; self.stream = False; self.record = False
        self.keys = {"Lower thirds": False}
        self.tracking = {}      # camera id -> shot
        self.log = []
        self.fails = 0
    sources = {1: "Cam 1", 2: "Cam 2", 3: "Cam 3"}
    cams = [{"id": "C1", "name": "Cam 1", "input": 1, "shots": ["Pulpit", "Wide"]},
            {"id": "C2", "name": "Cam 2", "input": 2, "shots": ["Band"]}]
    def state(self):
        cams = []
        for c in self.cams:
            t = self.tracking.get(c["id"])
            cams.append({**c, "onNext": c["input"] == self.next, "onLive": c["input"] == self.live, "answering": True,
                         "tracking": t is not None, "trackState": "following" if t else "", "trackShot": t or ""})
        s = lambda i: {"input": i, "name": self.sources[i]}
        return {"link": "online", "model": "OHStreamer (GoStream)", "live": s(self.live), "next": s(self.next),
                "transition": self.transition, "black": self.black, "streaming": self.stream, "streamConnecting": False,
                "recording": None,
                "sources": [{"input": i, "label": n, "live": i == self.live, "next": i == self.next, "picture": i != 3}
                            for i, n in self.sources.items()],
                "cameras": cams, "keys": [{"label": k, "on": v} for k, v in self.keys.items()],
                "shotSizes": ["shoulders", "waist", "full"]}
    def do(self, a):
        self.log.append(a)
        act = a.get("action")
        if act == "next": self.next = int(a["input"])
        elif act == "cut": self.live, self.next = self.next, self.live
        elif act == "fade":
            self.live, self.next = self.next, self.live
        elif act == "black": self.black = not self.black
        elif act == "stream": self.stream = bool(a["on"])
        elif act == "key": self.keys[a["button"]] = not self.keys[a["button"]]
        elif act in ("drive", "zoom"):
            c = next((c for c in self.cams if c["id"] == a.get("camera")), None)
            if not c or c["input"] != self.next:
                return {"error": "Only the camera on Next can be moved."}
        elif act == "track": self.tracking[a["camera"]] = a.get("shot", "waist")
        elif act == "untrack": self.tracking.pop(a["camera"], None)
        elif act in ("shot", "focus", "home", "stopcam", "record"): pass
        else: return {"error": "That isn't something the web page can do."}
        return {"ok": True}

B = Booth()

def jpeg(n):
    img = Image.new("RGB", (640, 360), [(40, 90, 160), (150, 60, 60), (60, 130, 80)][(n - 1) % 3])
    d = ImageDraw.Draw(img); d.text((20, 20), f"Input {n}  {time.strftime('%H:%M:%S')}.{int((time.time() % 1) * 100):02d}", fill="white")
    out = io.BytesIO(); img.save(out, "JPEG"); return out.getvalue()

STATS = {"stream_frames": 0, "streams_open": 0, "requests": 0}

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"          # keep-alive, like the Mac server
    def log_message(self, *a): pass
    def send(self, status, body, ctype="application/json"):
        if not isinstance(body, bytes): body = json.dumps(body).encode()
        self.send_response(status); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store"); self.end_headers(); self.wfile.write(body)
    def authed(self):
        return self.headers.get("x-token") == TOKEN
    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/": return self.send(200, page().encode(), "text/html; charset=utf-8")
        if u.path == "/_log": return self.send(200, B.log)
        if u.path == "/_stats": return self.send(200, STATS)
        if u.path == "/_reset": B.reset(); return self.send(200, {"ok": True})
        STATS["requests"] += 1
        q = parse_qs(u.query)
        if u.path == "/api/stream":      # a picture that keeps coming, like WebServer.serveStream
            if q.get("t", [""])[0] != TOKEN and not self.authed(): return self.send(401, {"error": "Log in with the PIN."})
            n = int(q.get("input", ["0"])[0]); fps = float(q.get("fps", ["12"])[0])
            if n not in (1, 2): return self.send(204, b"", "text/plain")
            self.send_response(200); self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
            self.send_header("Cache-Control", "no-store"); self.send_header("Connection", "close"); self.end_headers()
            STATS["streams_open"] += 1
            try:
                while True:
                    f = jpeg(n)
                    self.wfile.write(b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: " + str(len(f)).encode() + b"\r\n\r\n" + f + b"\r\n")
                    self.wfile.flush(); STATS["stream_frames"] += 1
                    time.sleep(1 / fps)
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
            finally:
                STATS["streams_open"] -= 1
                self.close_connection = True
            return
        if not self.authed(): return self.send(401, {"error": "Log in with the PIN."})
        if u.path == "/api/state": return self.send(200, B.state())
        if u.path == "/api/picture":
            n = int(parse_qs(u.query).get("input", ["0"])[0])
            return self.send(200, jpeg(n), "image/jpeg") if n in (1, 2) else self.send(204, b"", "text/plain")
        self.send(404, {"error": "Not found."})
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", 0) or 0))
        u = urlparse(self.path)
        if u.path == "/api/login":
            if B.fails >= 5: return self.send(429, {"error": "Too many wrong tries. Wait 30 seconds."})
            if json.loads(body or b"{}").get("pin") == PIN: B.fails = 0; return self.send(200, {"token": TOKEN})
            B.fails += 1; return self.send(401, {"error": "That PIN isn't right."})
        if not self.authed(): return self.send(401, {"error": "Log in with the PIN."})
        if u.path == "/api/do": return self.send(200, B.do(json.loads(body)))
        self.send(404, {"error": "Not found."})

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9912
    print(f"Pretend web server on http://localhost:{port}  (PIN {PIN})")
    ThreadingHTTPServer(("0.0.0.0", port), H).serve_forever()
