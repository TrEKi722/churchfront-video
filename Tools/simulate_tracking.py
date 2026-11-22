#!/usr/bin/env python3
"""Simulates the auto tracking pan loop, to compare controller settings without a camera.

    python3 Tools/simulate_tracking.py                  # compare P, PD and PID on a few scenarios
    python3 Tools/simulate_tracking.py --delay 0.5      # a faster picture
    python3 Tools/simulate_tracking.py --kp 1.2 --ki 0.1 --kd 0.3 --scenario walk

A simplified copy of the loop in Sources/CueVideo/Tracker.swift (pan only): the picture the controller
sees is `delay` seconds old and noisy, the camera follows its speed command with a lag, the
error is corrected for how far the camera has turned since the picture was taken, the walking speed
is estimated and fed forward, there's a dead zone with a hysteresis, and speed changes are rate
limited. It's a model, not the app: use it to compare settings and spot hunting, then check on a camera.

Units: positions in frame widths (0 to 1 across the picture), speeds in frames a second.
"""
import argparse, math, random, statistics

def simulate(scenario, kp=1.2, ki=0.0, kd=0.0, delay=0.9, lag=0.2, noise=0.008, ease=1.0,
             dead=0.11, seed=1, seconds=24.0, hz=12.0, gain_error=1.0, ff=True, lead=False, assumed=None):
    rnd = random.Random(seed)
    assumed = delay if assumed is None else assumed
    dt = 0.01
    ctl_dt = 1 / hz
    n = int(seconds / dt)
    person = 0.0          # world position in frames, same scale as the camera
    cam = 0.0
    vcam = 0.0            # real camera speed
    u_prev = 0.0          # last commanded speed
    cmd = 0.0
    pos_hist, cam_hist = [], []
    move_est = 0.0
    panning = False
    walk_dir, walk_since = 0, 0.0
    integ = 0.0
    last_tick = 0.0
    last_world = None
    sign_flips, last_sign = 0, 0
    errs, still_motion = [], []
    max_after_step = 0.0
    for k in range(n):
        t = k * dt
        # The person
        if scenario == "step":
            person = 0.25 if t >= 2 else 0.0
        elif scenario == "walk":
            person = 0.18 * max(0.0, min(t, 10) - 2) if t >= 2 else 0.0
        elif scenario == "drift":      # slow, small movements inside the dead zone: should not move the camera
            person = 0.04 * math.sin(2 * math.pi * t / 5.0)
        # The camera
        vcam += (cmd - vcam) * dt / lag
        cam += vcam * gain_error * dt
        pos_hist.append(person); cam_hist.append(cam)
        err_true = person - cam
        errs.append((t, err_true, vcam))
        # The controller runs at the analysis rate
        if t - last_tick >= ctl_dt - 1e-9:
            last_tick = t
            i = max(0, k - int(delay / dt))
            seen = pos_hist[i] - cam_hist[i] + rnd.gauss(0, noise)       # error as the delayed picture shows it
            turned = cam - cam_hist[i]                                   # camera has turned since
            e = seen - turned
            # Estimate how fast the person is really moving (picture drift plus the camera's own turn)
            world = seen + cam_hist[i]
            if last_world is not None:
                v = (world - last_world) / ctl_dt
                move_est += (v - move_est) * 0.2
            last_world = world
            d = 1 if move_est > 0.12 else (-1 if move_est < -0.12 else 0)
            if d != walk_dir: walk_dir, walk_since = d, t
            walk = move_est if (d != 0 and t - walk_since > 0.5) else 0.0
            if lead:   # the person has moved on since the picture was taken: add that, from how fast they're walking
                e += max(-0.25, min(0.25, walk * assumed))
            if abs(e) > dead or walk != 0: panning = True
            elif abs(e) < dead * 0.5 and walk == 0: panning = False
            # Integral: only while moving and clear of the inner zone; forgotten on crossing the mark
            if ki > 0 and panning and abs(e) > dead * 0.5:
                if integ * e < 0: integ = 0.0
                imax = 0.12 / ki
                integ = max(-imax, min(imax, integ + e * ctl_dt))
            else:
                integ = 0.0
            deriv = move_est - u_prev                                    # error rate: person's speed minus the camera's
            want = (walk if ff else 0.0) + kp * e + ki * integ + kd * deriv if panning else 0.0
            accel, decel = 0.5 * ease * ctl_dt, 0.8 * ease * ctl_dt
            step = decel if (abs(want) < abs(u_prev) or want * u_prev < 0) else accel
            u = u_prev + max(-step, min(step, want - u_prev))
            u_prev = cmd = u
        s = 1 if vcam > 0.02 else (-1 if vcam < -0.02 else 0)
        if s and last_sign and s != last_sign: sign_flips += 1
        if s: last_sign = s
    # Metrics
    if scenario == "step":
        after = [e for (t, e, _) in errs if t >= 2]
        worst_over = max([-e for e in after[after.index(max(after)):]] + [0.0])   # past the mark (negative error after being positive)
        settle = next((t for (t, e, v) in errs if t > 2.5 and all(abs(x[1]) < 0.06 for x in errs if t <= x[0] <= t + 3)), None)
        return {"peak_err": max(abs(e) for (_, e, _) in errs if True), "overshoot": worst_over,
                "reversals": sign_flips, "settle_s": None if settle is None else settle - 2}
    if scenario == "walk":
        w = [abs(e) for (t, e, _) in errs if 4 <= t <= 11]
        return {"walk_rms": math.sqrt(statistics.fmean(x * x for x in w)), "peak_err": max(abs(e) for (_, e, _) in errs),
                "reversals": sign_flips}
    moved = sum(1 for (_, _, v) in errs if abs(v) > 0.02) * 0.01
    return {"camera_moving_s": moved, "reversals": sign_flips}

def avg(scenario, runs=8, **kw):
    rows = [simulate(scenario, seed=s, **kw) for s in range(runs)]
    out = {}
    for key in rows[0]:
        vals = [r[key] for r in rows if r[key] is not None]
        out[key] = statistics.fmean(vals) if vals else None
    return out

def fmt(d):
    return "  ".join(f"{k} {('%.3f' % v) if isinstance(v, float) else v}" for k, v in d.items())

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--delay", type=float, default=0.9)
    ap.add_argument("--kp", type=float, default=None); ap.add_argument("--ki", type=float, default=None); ap.add_argument("--kd", type=float, default=None)
    ap.add_argument("--scenario", choices=["step", "walk", "drift"], default=None)
    ap.add_argument("--compare-lead", action="store_true", help="walking, with and without the lead term")
    a = ap.parse_args()
    variants = [("P only (before)", dict(kp=1.2, ki=0, kd=0)), ("PD", dict(kp=1.2, ki=0, kd=0.3)),
                ("PI", dict(kp=1.2, ki=0.1, kd=0)), ("PID", dict(kp=1.2, ki=0.1, kd=0.3))]
    if a.kp is not None or a.ki is not None or a.kd is not None:
        variants = [("yours", dict(kp=a.kp if a.kp is not None else 1.2, ki=a.ki or 0.0, kd=a.kd or 0.0))]
    if a.compare_lead:
        print(f"\n== walking, picture delay {a.delay:.2f} s: without and with the lead term")
        for name, kw in (("no lead", dict(lead=False)), ("lead", dict(lead=True)), ("lead, delay guessed 0.45", dict(lead=True, assumed=0.45)),
                         ("lead, delay guessed 1.2", dict(lead=True, assumed=1.2))):
            print(f"{name:26s} {fmt(avg('walk', delay=a.delay, kp=1.2, ki=0.0, kd=0.0, **kw))}")
        return
    for scen in ([a.scenario] if a.scenario else ["step", "walk", "drift"]):
        print(f"\n== {scen}, picture delay {a.delay:.2f} s")
        for name, kw in variants:
            print(f"{name:16s} {fmt(avg(scen, delay=a.delay, **kw))}")

if __name__ == "__main__":
    main()
