#!/usr/bin/env python3
"""Summarise Churchfront Video's tracking log, to tune auto tracking.

    python3 Tools/analyze_tracking.py                       # ~/Library/Logs/CueVideo/tracking.csv
    python3 Tools/analyze_tracking.py path/to/tracking.csv --last 90

Run it right after tracking someone for a minute or so, and paste the output. It reads the
log the app writes (one row per analysed frame) and reports, per camera and for the last
--last seconds of tracking (default 120):

  * how often the camera reverses direction (hunting) and how far the person gets from the mark
  * how often the person reached the edge alarm
  * the angle of view the camera reported, and the turn-rate gain the app learned
  * the delay between the app asking the camera to pan and the picture responding

Pure Python, no packages needed. Reads only; changes nothing.
"""
import argparse, csv, math, os, statistics, sys

DEFAULT = os.path.expanduser("~/Library/Logs/CueVideo/tracking.csv")

def load(path):
    rows = []
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            try:
                rows.append({k: (float(v) if k != "camera" else v) for k, v in r.items() if v is not None})
            except ValueError:
                continue
    return rows

def pct(n, d):
    return f"{100 * n / d:.0f}%" if d else "n/a"

def resample(rows, key, hz=10):
    """Value of `key` at regular times, holding the last row's value."""
    t0, t1 = rows[0]["time"], rows[-1]["time"]
    out, i = [], 0
    n = int((t1 - t0) * hz)
    for k in range(n):
        t = t0 + k / hz
        while i + 1 < len(rows) and rows[i + 1]["time"] <= t:
            i += 1
        out.append(rows[i][key])
    return out

def lag_estimate(rows, hz=10, max_lag=1.5):
    """Seconds from a pan command to the picture reacting: the lag at which pan_sent and the
    picture's motion are most opposed (panning right moves the person left in the picture)."""
    cmd = resample(rows, "pan_sent", hz)
    pic = resample(rows, "picture_vx", hz)
    if len(cmd) < 40:
        return None
    mc, mp = statistics.fmean(cmd), statistics.fmean(pic)
    c = [x - mc for x in cmd]
    p = [x - mp for x in pic]
    sc = math.sqrt(sum(x * x for x in c)) or 1.0
    sp = math.sqrt(sum(x * x for x in p)) or 1.0
    best = None
    for lag in range(0, int(max_lag * hz) + 1):
        n = len(c) - lag
        if n < 30:
            break
        r = sum(c[i] * p[i + lag] for i in range(n)) / (sc * sp)
        if best is None or r < best[1]:
            best = (lag / hz, r)
    return best

def report(name, rows):
    dur = rows[-1]["time"] - rows[0]["time"]
    n = len(rows)
    print(f"\n=== {name}: {n} frames over {dur:.0f} s ({n / dur:.1f} frames/s analysed) ===")
    # How fast frames are being looked at. detect_ms and dropped are in newer logs only.
    if "detect_ms" in rows[0]:
        ms = sorted(r["detect_ms"] for r in rows if r["detect_ms"] > 0)
        dropped = rows[-1].get("dropped", 0) - rows[0].get("dropped", 0)
        if ms:
            print(f"looking at a frame takes {statistics.median(ms):.0f} ms (90th percentile {ms[int(0.9 * (len(ms) - 1))]:.0f} ms); "
                  f"{n / dur:.1f} frames a second looked at, {dropped:.0f} skipped while busy ({pct(dropped, dropped + n)} of the frames that arrived)")
            print("  the picture the tracker steers by is at least that much older than the camera's own picture, so the `latency` setting "
                  "should be the camera-to-Mac delay plus about this")
    fov = [r["fov_deg"] for r in rows]
    gain = [r["pan_gain"] for r in rows]
    if statistics.median(fov) < 12:
        print(f"NOTE: the camera was zoomed in tight most of the time (median {statistics.median(fov):.1f} degrees). "
              "At that angle a small pan error throws the person out of frame; tracking zoomed in to hold the "
              "shot size on someone far away. Try a looser shot size, or turn off zoom-to-hold-size in Setup > Tracking.")
    print(f"angle of view: {min(fov):.1f} to {max(fov):.1f} degrees (median {statistics.median(fov):.1f})")
    print(f"learned pan gain (real turn rate / asked; 1.0 = camera turns as asked): "
          f"min {min(gain):.2f}, median {statistics.median(gain):.2f}, max {max(gain):.2f}"
          + ("   <- stuck at its upper limit" if statistics.median(gain) >= 1.45 else "")
          + ("   <- stuck at its lower limit" if statistics.median(gain) <= 0.08 else ""))

    # Hunting: how often the commanded pan flips sign.
    sent = [r["pan_sent"] for r in rows if r["pan_sent"] != 0]
    flips = sum(1 for a, b in zip(sent, sent[1:]) if a * b < 0)
    minutes = dur / 60
    print(f"pan direction reversals: {flips} ({flips / minutes:.1f} per minute); "
          f"moving {pct(len(sent), n)} of the time; peak command {max((abs(x) for x in sent), default=0) / 100:.0f} deg/s")

    err = [abs(r["err_x"]) for r in rows]
    print(f"person's distance from the mark (fraction of frame width): median {statistics.median(err):.2f}, "
          f"90th percentile {sorted(err)[int(0.9 * (len(err) - 1))]:.2f}, worst {max(err):.2f}")
    hot = sum(1 for r in rows if r["edge_urgency"] > 0.3)
    print(f"time the edge alarm was on (person near the frame edge): {pct(hot, n)}")

    # Rough hunting period from the err_x sign changes.
    xs = [(r["time"], r["err_x"]) for r in rows if abs(r["err_x"]) > 0.05]
    cross = [t for (t, a), (_, b) in zip(xs, xs[1:]) if a * b < 0]
    if len(cross) >= 4:
        periods = [b - a for a, b in zip(cross, cross[1:])]
        print(f"person crossed the mark {len(cross)} times; median {statistics.median(periods):.1f} s between crossings "
              "(a steady 2 to 6 s rhythm while they stand still means the loop is hunting)")

    lag = lag_estimate(rows)
    if lag:
        print(f"picture delay (command to picture response): about {lag[0]:.2f} s (match strength {-lag[1]:.2f}; "
              f"the app assumes 0.45 s unless trackTuning.latency is set)")
    else:
        print("picture delay: not enough movement to estimate")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log", nargs="?", default=DEFAULT)
    ap.add_argument("--last", type=float, default=120, help="only the last N seconds of the log")
    args = ap.parse_args()
    if not os.path.exists(args.log):
        sys.exit(f"No log at {args.log}. Track someone for a minute first.")
    rows = load(args.log)
    if not rows:
        sys.exit("The log is empty.")
    end = rows[-1]["time"]
    rows = [r for r in rows if r["time"] >= end - args.last]
    cams = {}
    for r in rows:
        cams.setdefault(r["camera"], []).append(r)
    for name, rs in cams.items():
        if len(rs) < 20:
            print(f"\n=== {name}: only {len(rs)} frames, skipped ===")
            continue
        report(name, rs)

if __name__ == "__main__":
    main()
