#!/usr/bin/env python3
"""A pretend OSEE GoStream Deck for trying Churchfront Video without the real switcher.

    python3 Tools/fake_gostream.py 19010          # like the real Deck on firmware 2.1.4
    python3 Tools/fake_gostream.py 19010 --new    # fuller command set (firmware 2.3 and later)
    CUEVIDEO_HOST=127.0.0.1 CUEVIDEO_SWITCHER=gostream "./Churchfront Video.app/Contents/MacOS/CueVideo"

It follows the protocol as read from the Bitfocus Companion module, so it shows that the app's
plumbing works, not that a real GoStream behaves the same. Check the real one with Tools/gostream_probe.py.
"""
import json, socket, sys, threading
sys.path.insert(0, __import__("os").path.dirname(__file__))
from gostream_probe import pack, Decoder

class Deck:
    """By default behaves like the real Deck on firmware 2.1.4: sources count from 0, and most
    newer commands (inputList, transition style, record status, ...) answer with an error.
    Run with --new for the fuller command set of firmware 2.3 and later."""
    def __init__(self, new=False):
        self.new = new
        self.s = {"deviceName": ["OHStreamer"], "version": ["2.3.0" if new else "2.1.4"],
                  "buildInfo": ["0B6A372D"], "deviceId": ["GOSUET FAKE"], "live": [0]}
        if new:
            self.s.update({"pgmIndex": [1], "pvwIndex": [2], "transitionStatus": [0], "transitionStyle": ["Mix"],
                           "transitionMixRate": [25], "previewTransition": [0], "ftbStatus": [0],
                           "deviceType": [0], "inputList": [1, 2, 3, 4],
                           "liveStreamOutputStatus": [0, 0], "recordStatus": [0]})
        else:
            self.s.update({"pgmIndex": [1], "pvwIndex": [0]})

    def handle(self, cmd):
        """Returns the packets (id, value) to send back for one command."""
        id_, typ, val = cmd["id"], cmd["type"], cmd.get("value") or []
        out = []
        if typ == "get":
            if id_ in self.s:
                out.append((id_, self.s[id_]))
            else:  # the real Deck (firmware 2.1.4) answers an unknown ID like this, without naming it
                return [("parse_error", "err", ["PARSE_ERROR_NOT_FOND_ID"])]
        elif typ == "set":
            s = self.s
            if id_ in ("pgmIndex", "pvwIndex") or (self.new and id_ in ("transitionMixRate", "transitionStyle")):
                s[id_] = val; out.append((id_, val))
            elif id_ in ("cutTransition", "autoTransition"):
                if id_ == "autoTransition":
                    out.append(("autoTransition", [1]))
                s["pgmIndex"], s["pvwIndex"] = s["pvwIndex"], s["pgmIndex"]
                out += [("pgmIndex", s["pgmIndex"]), ("pvwIndex", s["pvwIndex"])]
                if id_ == "autoTransition":
                    out.append(("autoTransition", [0]))
            elif id_ == "ftb" and self.new:
                s["ftbStatus"] = [0 if s["ftbStatus"] == [1] else 1]; out.append(("ftbStatus", s["ftbStatus"]))
            elif id_ == "live":
                s["live"] = [val[0]]; out.append(("live", s["live"]))
                if self.new:
                    s["liveStreamOutputStatus"] = [0, val[0]]; out.append(("liveStreamOutputStatus", s["liveStreamOutputStatus"]))
            elif id_ in ("recordStart", "recordStop") and self.new:
                s["recordStatus"] = [1 if id_ == "recordStart" else 0]; out.append(("recordStatus", s["recordStatus"]))
        return [(i, "pus" if typ == "set" else "get", v) for i, v in out]

def serve(conn, deck):
    dec = Decoder()
    try:
        while True:
            data = conn.recv(4096)
            if not data:
                return
            for cmd in dec.feed(data):
                if not isinstance(cmd, dict):
                    continue
                print("<-", cmd)
                for id_, typ, val in deck.handle(cmd):
                    print("->", typ, id_, val)
                    conn.sendall(pack({"id": id_, "type": typ, "value": val}))
    except OSError:
        pass

if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    port = int(args[0]) if args else 19010
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", port)); srv.listen(4)
    deck = Deck(new="--new" in sys.argv)
    print(f"Fake GoStream on port {port}")
    while True:
        c, _ = srv.accept()
        threading.Thread(target=serve, args=(c, deck), daemon=True).start()
