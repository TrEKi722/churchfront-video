#!/usr/bin/env python3
"""Read-only probe for an OSEE GoStream (Deck, Duet). Sends only `get` commands.

    python3 Tools/gostream_probe.py 192.168.0.215            # default port 19010
    python3 Tools/gostream_probe.py 192.168.0.215 --port 19010 --seconds 5

Asks one question at a time and prints every packet the switcher sends back, so we can confirm the IDs and value
shapes in Sources/CueATEM/GoStream.swift against real hardware. Press buttons on the
switcher while it runs to see its `pus` pushes. Never sends set commands.
"""
import argparse, json, socket, struct, time

HEAD = b"\xEB\xA6"

def crc16(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc

def pack(obj: dict) -> bytes:
    body = json.dumps(obj, separators=(",", ":")).encode()
    frame = HEAD + b"\x00" + struct.pack("<H", len(body) + 2) + body
    return frame + struct.pack("<H", crc16(frame))

class Decoder:
    def __init__(self):
        self.buf = b""

    def feed(self, data: bytes):
        self.buf += data
        out = []
        while True:
            i = self.buf.find(HEAD)
            if i < 0:
                self.buf = self.buf[-1:] if self.buf.endswith(HEAD[:1]) else b""
                return out
            self.buf = self.buf[i:]
            if len(self.buf) < 5:
                return out
            length = struct.unpack_from("<H", self.buf, 3)[0]
            total = 5 + length
            if length < 3:
                self.buf = self.buf[2:]
                continue
            if len(self.buf) < total:
                return out
            frame, self.buf = self.buf[:total], self.buf[total:]
            if struct.unpack_from("<H", frame, total - 2)[0] != crc16(frame[:-2]):
                out.append(("bad crc", frame.hex(" ")))
                continue
            try:
                out.append(json.loads(frame[5:-2]))
            except ValueError:
                out.append(("bad json", frame[5:-2]))

GETS = [
    ("deviceType", None), ("deviceName", None), ("version", None), ("buildInfo", None), ("deviceId", None),
    ("inputList", None),
    ("pgmIndex", None), ("pvwIndex", None),
    ("transitionStatus", None), ("transitionStyle", None), ("transitionMixRate", None),
    ("transitionRate", None), ("previewTransition", None), ("ftbStatus", None),
    ("liveStreamOutputStatus", [0]), ("liveStreamOutputEnable", [0]), ("live", None),
    ("recordStatus", None), ("recordFormat", None), ("recordDuration", None),
]

def show(pkt, asked=None):
    if not isinstance(pkt, dict):
        print("<-", pkt)
    elif pkt.get("type") == "err":
        print(f"<- ERROR for {asked or '?'}: {pkt.get('value')}")
    else:
        print("<-", json.dumps(pkt))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("host")
    ap.add_argument("--port", type=int, default=19010)
    ap.add_argument("--seconds", type=float, default=4.0,
                    help="how long to keep listening after the queries, to catch pushes when you press buttons")
    args = ap.parse_args()

    s = socket.create_connection((args.host, args.port), timeout=5)
    s.settimeout(0.1)
    dec = Decoder()

    def listen(duration, asked=None):
        end = time.time() + duration
        while time.time() < end:
            try:
                data = s.recv(65536)
            except socket.timeout:
                continue
            if not data:
                print("switcher closed the connection")
                return False
            for pkt in dec.feed(data):
                show(pkt, asked)
        return True

    # One at a time, so an error reply can be matched to the command that caused it.
    for id_, value in GETS:
        obj = {"id": id_, "type": "get"}
        if value is not None:
            obj["value"] = value
        print("->", json.dumps(obj))
        s.sendall(pack(obj))
        if not listen(0.4, id_):
            return
    print(f"-- listening for {args.seconds:g} s: press buttons on the switcher to see what it pushes --")
    listen(args.seconds)
    s.close()

if __name__ == "__main__":
    main()
