import Foundation

/// The page WebServer serves: one self-contained HTML file (no outside libraries), written for an
/// iPad in landscape or portrait. Tools/test_web_ui.py loads it in a browser against a pretend
/// server, so keep it as one raw string.
enum WebUI {
    static let page = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="Booth">
<meta name="theme-color" content="#111214">
<title>Churchfront Video</title>
<style>
  :root {
    --bg: #111214; --surface: #1b1d21; --raised: #25282d; --line: #34383f;
    --ink: #f2f3f5; --muted: #a0a6b0; --live: #ef4444; --next: #4ade80; --accent: #bfe3ff; --warn: #f5a524;
    --gap: 12px; --radius: 14px;
  }
  * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
  html, body { margin: 0; height: 100%; background: var(--bg); color: var(--ink);
    font: 16px/1.3 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    -webkit-user-select: none; user-select: none; touch-action: manipulation; overscroll-behavior: none; }
  [hidden] { display: none !important; }
  button { font: inherit; color: inherit; border: 0; background: var(--raised); border-radius: var(--radius);
    padding: 12px 16px; min-height: 48px; cursor: pointer; }
  button:active { filter: brightness(1.25); }
  button:disabled { opacity: .4; }

  /* Login */
  #login { height: 100%; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 16px; padding: 24px; text-align: center; }
  #login h1 { margin: 0; font-size: 28px; }
  #login p { margin: 0; color: var(--muted); }
  #pin { font-size: 32px; letter-spacing: .4em; text-align: center; width: 12em; padding: 12px; border-radius: var(--radius);
    border: 1px solid var(--line); background: var(--surface); color: var(--ink); -webkit-user-select: text; user-select: text; }
  #loginErr { color: var(--live); min-height: 1.3em; }
  #go { background: var(--accent); color: #0b1a26; font-weight: 700; min-width: 12em; }

  /* App */
  #app { height: 100%; display: flex; flex-direction: column; gap: var(--gap);
    padding: max(12px, env(safe-area-inset-top)) max(12px, env(safe-area-inset-right)) max(12px, env(safe-area-inset-bottom)) max(12px, env(safe-area-inset-left)); }
  header { display: flex; align-items: center; gap: 10px; flex: none; }
  header .title { font-weight: 700; }
  #dot { width: 10px; height: 10px; border-radius: 50%; background: var(--muted); }
  #dot.on { background: var(--next); } #dot.off { background: var(--live); }
  #model { color: var(--muted); font-size: 14px; }
  header .sp { flex: 1; }
  .pill { min-height: 40px; padding: 6px 14px; font-weight: 700; letter-spacing: .04em; border: 1px solid var(--line); background: transparent; }
  .pill.on { background: var(--live); border-color: var(--live); }
  .pill.warn { background: var(--warn); border-color: var(--warn); color: #1b1200; }

  #monitors { display: grid; grid-template-columns: 1fr 1fr; gap: var(--gap); flex: 1 1 0; min-height: 0; }
  .mon { position: relative; background: #000; border-radius: var(--radius); border: 3px solid var(--line); overflow: hidden;
    display: flex; align-items: center; justify-content: center; min-height: 0; }
  .mon.next { border-color: var(--next); } .mon.live { border-color: var(--live); }
  .mon img { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: contain; display: none; }
  .mon img.has { display: block; }
  .mon .name { font-size: clamp(28px, 6vw, 64px); font-weight: 700; color: #cfd3da; text-align: center; padding: 8px; }
  .mon img.has ~ .name { display: none; }
  .tag { position: absolute; top: 10px; left: 10px; font-size: 14px; font-weight: 800; letter-spacing: .06em; padding: 4px 10px; border-radius: 8px; color: #fff; z-index: 2; }
  .next .tag { background: var(--next); color: #062b12; } .live .tag { background: var(--live); }
  .mon .label { position: absolute; left: 10px; bottom: 10px; z-index: 2; background: rgba(0,0,0,.6); padding: 4px 10px; border-radius: 8px; font-weight: 700; }
  .mon.fading::after { content: "FADING"; position: absolute; right: 10px; top: 10px; background: var(--live); padding: 4px 10px; border-radius: 8px; font-weight: 800; z-index: 2; }

  #tiles { display: flex; gap: var(--gap); flex: none; overflow-x: auto; padding-bottom: 2px; }
  .tile { position: relative; flex: 0 0 auto; width: 150px; height: 92px; border-radius: 12px; border: 3px solid var(--line); background: var(--surface);
    padding: 0; overflow: hidden; display: block; }
  .tile.next { border-color: var(--next); } .tile.live { border-color: var(--live); }
  .tile img { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; display: none; }
  .tile img.has { display: block; }
  .tile span { position: absolute; left: 6px; bottom: 5px; right: 6px; text-align: left; font-weight: 700; text-shadow: 0 1px 3px #000; }
  .tile em { position: absolute; right: 6px; top: 5px; font-style: normal; font-size: 11px; font-weight: 800; padding: 1px 6px; border-radius: 6px; }
  .tile.next em { background: var(--next); color: #062b12; } .tile.live em { background: var(--live); }

  #bottom { display: grid; grid-template-columns: minmax(220px, 1.1fr) minmax(300px, 1.5fr) minmax(260px, 1fr); gap: var(--gap); flex: none; align-items: stretch; }
  .panel { background: var(--surface); border-radius: var(--radius); padding: 12px; display: flex; flex-direction: column; gap: 10px; min-width: 0; }
  .panel h2 { margin: 0; font-size: 13px; letter-spacing: .08em; text-transform: uppercase; color: var(--muted); }
  #camname { font-size: 18px; font-weight: 700; }
  #camname small { font-size: 12px; background: var(--next); color: #062b12; padding: 2px 8px; border-radius: 6px; margin-left: 6px; }
  #shots { display: flex; flex-wrap: wrap; gap: 8px; }
  #shots button { flex: 1 1 90px; }
  .none { color: var(--muted); }

  #camctl { display: flex; gap: 14px; align-items: center; justify-content: center; flex: 1; }
  #pad { position: relative; width: 190px; height: 190px; border-radius: 50%; background: #0c0d0f; border: 2px solid var(--line); touch-action: none; flex: none; }
  #pad::after { content: ""; position: absolute; inset: 28%; border: 1px dashed var(--line); border-radius: 50%; }
  #knob { position: absolute; left: 50%; top: 50%; width: 70px; height: 70px; margin: -35px 0 0 -35px; border-radius: 50%; background: #3a3f47; border: 2px solid #565c66; touch-action: none; }
  #pad.off { opacity: .35; }
  #zoom { display: flex; flex-direction: column; gap: 10px; }
  #zoom button { width: 64px; height: 88px; font-size: 26px; touch-action: none; }

  #take { display: grid; grid-template-columns: 1fr 1fr; grid-template-rows: 1fr auto; gap: 10px; flex: 1; }
  #fade { background: var(--live); font-size: 26px; font-weight: 800; min-height: 96px; }
  #cut { background: var(--raised); font-size: 26px; font-weight: 800; }
  #black { grid-column: 1 / 3; background: #2b2e34; font-weight: 700; }
  #black.on { background: #fff; color: #000; }
  #keys { display: flex; flex-wrap: wrap; gap: 8px; }
  #keys button { flex: 1 1 110px; } #keys button.on { background: var(--live); }
  #trackrow { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
  #track.on { background: var(--accent); color: #0b1a26; font-weight: 700; }
  .seg { display: flex; border: 1px solid var(--line); border-radius: 10px; overflow: hidden; }
  .seg button { border-radius: 0; background: transparent; min-height: 40px; padding: 6px 12px; }
  .seg button.on { background: var(--accent); color: #0b1a26; font-weight: 700; }
  #trackstate { color: var(--muted); font-size: 13px; }

  #toast { position: fixed; left: 50%; bottom: max(18px, env(safe-area-inset-bottom)); transform: translateX(-50%); max-width: 90vw;
    background: #000c; border: 1px solid var(--line); padding: 10px 16px; border-radius: 12px; z-index: 20; }
  #modal { position: fixed; inset: 0; background: #000a; display: flex; align-items: center; justify-content: center; z-index: 30; }
  #modal .box { background: var(--surface); padding: 22px; border-radius: 18px; display: flex; flex-direction: column; gap: 16px; min-width: 280px; text-align: center; }
  #modal .row { display: flex; gap: 12px; } #modal .row button { flex: 1; }
  #offline { position: fixed; top: 0; left: 0; right: 0; background: var(--live); text-align: center; padding: 6px; font-weight: 700; z-index: 25; }

  /* Portrait: monitors stay side by side; the lower panels form two columns, with the joystick below them */
  @media (max-width: 900px) {
    #app { overflow-y: auto; }
    #monitors { flex: none; } .mon { aspect-ratio: 16 / 9; }
    #bottom { grid-template-columns: 1fr 1fr; }
    #bottom .panel:nth-child(2) { grid-column: 1 / 3; order: 3; }
  }
  /* Phones */
  @media (max-width: 560px) {
    #monitors { grid-template-columns: 1fr; }
    #bottom { grid-template-columns: 1fr; }
    #bottom .panel:nth-child(2) { grid-column: auto; order: 0; }
  }
</style>
</head>
<body>

<div id="login" hidden>
  <h1>Churchfront Video</h1>
  <p>Enter the PIN shown in Setup on the Mac.</p>
  <input id="pin" inputmode="numeric" pattern="[0-9]*" maxlength="6" autocomplete="off" placeholder="••••••">
  <div id="loginErr"></div>
  <button id="go">Connect</button>
</div>

<div id="app" hidden>
  <div id="offline" hidden>Can't reach the Mac. Trying again…</div>
  <header>
    <span id="dot"></span><span class="title">Booth</span><span id="model"></span>
    <span class="sp"></span>
    <button id="rec" class="pill" hidden>RECORD</button>
    <button id="stream" class="pill" hidden>STREAM</button>
  </header>

  <section id="monitors">
    <div class="mon next" id="monNext"><img alt=""><div class="name"></div><span class="tag">NEXT</span><span class="label"></span></div>
    <div class="mon live" id="monLive"><img alt=""><div class="name"></div><span class="tag">LIVE</span><span class="label"></span></div>
  </section>

  <section id="tiles"></section>

  <section id="bottom">
    <div class="panel" id="camPanel">
      <h2>Camera on Next</h2>
      <div id="camname"></div>
      <div id="shots"></div>
      <div id="trackrow">
        <button id="track">TRACK</button>
        <div class="seg" id="sizes"></div>
        <button id="focus">FOCUS</button>
      </div>
      <div id="trackstate"></div>
    </div>
    <div class="panel">
      <h2>Move camera</h2>
      <div id="camctl">
        <div id="pad" class="off"><div id="knob"></div></div>
        <div id="zoom"><button id="zin">＋</button><button id="zout">－</button></div>
      </div>
    </div>
    <div class="panel">
      <h2>Take</h2>
      <div id="take">
        <button id="fade">FADE</button>
        <button id="cut">CUT</button>
        <button id="black">BLACK</button>
      </div>
      <div id="keys"></div>
    </div>
  </section>
</div>

<div id="toast" hidden></div>
<div id="modal" hidden><div class="box"><div id="ask"></div><div class="row"><button id="no">Cancel</button><button id="yes" style="background:var(--live)">Yes</button></div></div></div>

<script>
"use strict";
const $ = s => document.querySelector(s);
let token = "";
try { token = localStorage.getItem("cv_token") || ""; } catch (e) {}
let st = null, polling = false, shotSize = "waist", camId = null, toastTimer = null;

function toast(msg) {
  const t = $("#toast"); t.textContent = msg; t.hidden = false;
  clearTimeout(toastTimer); toastTimer = setTimeout(() => { t.hidden = true; }, 3500);
}
function confirmAsk(text) {
  return new Promise(res => {
    $("#ask").textContent = text; $("#modal").hidden = false;
    const done = v => { $("#modal").hidden = true; $("#yes").onclick = $("#no").onclick = null; res(v); };
    $("#yes").onclick = () => done(true); $("#no").onclick = () => done(false);
  });
}

async function api(path, body) {
  const opt = { headers: { "x-token": token } };
  if (body !== undefined) { opt.method = "POST"; opt.body = JSON.stringify(body); }
  const r = await fetch(path, opt);
  if (r.status === 401) { showLogin(); throw new Error("login"); }
  return r;
}
async function act(body, quiet) {
  try {
    const r = await (await api("/api/do", body)).json();
    if (r.error && !quiet) toast(r.error);
    return r;
  } catch (e) { if (e.message !== "login" && !quiet) toast("Lost the connection to the Mac."); }
}

// ---- Login
function showLogin() {
  polling = false; st = null;
  for (const sel of ["#monNext img", "#monLive img"]) { const i = $(sel); clearTimeout(+i.dataset.retry || 0); i.dataset.input = ""; i.removeAttribute("src"); i.classList.remove("has"); }
  $("#app").hidden = true; $("#login").hidden = false; $("#pin").value = ""; $("#pin").focus();
}
async function login() {
  $("#loginErr").textContent = "";
  try {
    const r = await fetch("/api/login", { method: "POST", body: JSON.stringify({ pin: $("#pin").value }) });
    const j = await r.json();
    if (j.token) { token = j.token; try { localStorage.setItem("cv_token", token); } catch (e) {} start(); }
    else $("#loginErr").textContent = j.error || "That PIN isn't right.";
  } catch (e) { $("#loginErr").textContent = "Can't reach the Mac."; }
}
$("#go").onclick = login;
$("#pin").addEventListener("keydown", e => { if (e.key === "Enter") login(); });

function start() {
  $("#login").hidden = true; $("#app").hidden = false;
  if (!polling) { polling = true; poll(); picLoop(); }
}

// ---- State
async function poll() {
  if (!polling) return;
  try {
    st = await (await api("/api/state")).json();
    $("#offline").hidden = true;
    render();
  } catch (e) { if (e.message !== "login") $("#offline").hidden = false; }
  setTimeout(poll, 250);
}

function nameOf(s) { return s ? s.name : "Nothing"; }

function render() {
  $("#dot").className = st.link === "online" ? "on" : "off";
  $("#model").textContent = st.link === "online" ? (st.model || "") : st.link;
  $("#monNext .label").textContent = nameOf(st.next);
  $("#monLive .label").textContent = nameOf(st.live);
  $("#monNext .name").textContent = nameOf(st.next);
  $("#monLive .name").textContent = nameOf(st.live);
  $("#monLive").classList.toggle("fading", !!st.transition);

  const sb = $("#stream"), rb = $("#rec");
  sb.hidden = st.streaming === null || st.streaming === undefined;
  sb.classList.toggle("on", !!st.streaming); sb.classList.toggle("warn", !st.streaming && !!st.streamConnecting);
  sb.textContent = st.streaming ? "STREAMING" : (st.streamConnecting ? "CONNECTING" : "STREAM");
  rb.hidden = st.recording === null || st.recording === undefined;
  rb.classList.toggle("on", !!st.recording); rb.textContent = st.recording ? "RECORDING" : "RECORD";
  $("#black").classList.toggle("on", !!st.black); $("#black").textContent = st.black ? "BLACK · ON" : "BLACK";

  renderTiles(); renderKeys(); renderCamera(); updateStreams();
}

function renderTiles() {
  const box = $("#tiles"), want = st.sources.map(s => s.input).join(",");
  if (box.dataset.sig !== want) {
    box.dataset.sig = want; box.innerHTML = "";
    for (const s of st.sources) {
      const b = document.createElement("button");
      b.className = "tile"; b.dataset.input = s.input;
      b.innerHTML = '<img alt=""><em></em><span></span>';
      b.onclick = () => act({ action: "next", input: s.input });
      box.appendChild(b);
    }
  }
  for (const s of st.sources) {
    const b = box.querySelector('[data-input="' + s.input + '"]'); if (!b) continue;
    b.classList.toggle("live", s.live); b.classList.toggle("next", s.next && !s.live);
    b.querySelector("span").textContent = s.label;
    b.querySelector("em").textContent = s.live ? "LIVE" : (s.next ? "NEXT" : "");
    b.dataset.pic = s.picture ? "1" : "";
  }
}

function renderKeys() {
  const box = $("#keys"), want = st.keys.map(k => k.label).join("|");
  if (box.dataset.sig !== want) {
    box.dataset.sig = want; box.innerHTML = "";
    for (const k of st.keys) {
      const b = document.createElement("button"); b.textContent = k.label; b.dataset.label = k.label;
      b.onclick = () => act({ action: "key", button: k.label });
      box.appendChild(b);
    }
  }
  for (const k of st.keys) { const b = box.querySelector('[data-label="' + CSS.escape(k.label) + '"]'); if (b) b.classList.toggle("on", k.on); }
}

function curCam() { return st && st.cameras.find(c => c.onNext) || null; }

function renderCamera() {
  const c = curCam(); camId = c ? c.id : null;
  $("#pad").classList.toggle("off", !c);
  $("#zin").disabled = $("#zout").disabled = !c;
  $("#track").disabled = $("#focus").disabled = !c;
  const name = $("#camname");
  if (!c) {
    name.innerHTML = '<span class="none">Put a camera on Next to move it.</span>';
    $("#shots").innerHTML = ""; $("#shots").dataset.sig = ""; $("#trackstate").textContent = "";
    $("#track").classList.remove("on"); return;
  }
  name.innerHTML = ""; name.append(c.name); const small = document.createElement("small"); small.textContent = "ON NEXT"; name.append(small);
  const sig = c.id + "|" + c.shots.join("|"), shots = $("#shots");
  if (shots.dataset.sig !== sig) {
    shots.dataset.sig = sig; shots.innerHTML = "";
    if (!c.shots.length) shots.innerHTML = '<span class="none">No saved shots.</span>';
    for (const n of c.shots) {
      const b = document.createElement("button"); b.textContent = n;
      b.onclick = () => act({ action: "shot", camera: camId, shot: n });
      shots.appendChild(b);
    }
  }
  const sizes = $("#sizes");
  if (sizes.dataset.sig !== st.shotSizes.join()) {
    sizes.dataset.sig = st.shotSizes.join(); sizes.innerHTML = "";
    const names = { shoulders: "Close", waist: "Waist", full: "Full" };
    for (const z of st.shotSizes) {
      const b = document.createElement("button"); b.textContent = names[z] || z; b.dataset.size = z;
      b.onclick = () => { shotSize = z; renderSizes(); if (curCam() && curCam().tracking) act({ action: "track", camera: camId, shot: z }); };
      sizes.appendChild(b);
    }
  }
  if (c.tracking && c.trackShot) shotSize = c.trackShot;
  renderSizes();
  $("#track").classList.toggle("on", c.tracking);
  $("#track").textContent = c.tracking ? "TRACKING" : "TRACK";
  const label = { starting: "Looking for someone…", following: "Following", searching: "Lost them, looking", lost: "Lost them" };
  $("#trackstate").textContent = c.tracking ? (label[c.trackState] || "") : "";
}
function renderSizes() { for (const b of $("#sizes").children) b.classList.toggle("on", b.dataset.size === shotSize); }

// ---- Buttons
$("#cut").onclick = () => act({ action: "cut" });
$("#fade").onclick = () => act({ action: "fade" });
$("#black").onclick = () => act({ action: "black" });
$("#stream").onclick = async () => {
  const on = !(st && st.streaming);
  if (await confirmAsk(on ? "Start the stream?" : "Stop the stream?")) act({ action: "stream", on });
};
$("#rec").onclick = async () => {
  const on = !(st && st.recording);
  if (await confirmAsk(on ? "Start recording?" : "Stop recording?")) act({ action: "record", on });
};
$("#track").onclick = () => {
  const c = curCam(); if (!c) return;
  if (c.tracking) act({ action: "untrack", camera: c.id });
  else act({ action: "track", camera: c.id, shot: shotSize });
};
$("#focus").onclick = () => { if (camId) act({ action: "focus", camera: camId }); };

// ---- Joystick and zoom. Held movement is re-sent every 120 ms; the Mac stops the camera if it
// ---- stops hearing from us, and we stop it ourselves on release, cancel, or leaving the page.
const pad = $("#pad"), knob = $("#knob");
let padOn = false, vec = { x: 0, y: 0 }, padTimer = null, padCam = null;
function curve(v) { const dz = 0.12; if (Math.abs(v) < dz) return 0; return Math.sign(v) * Math.pow((Math.abs(v) - dz) / (1 - dz), 1.6) * 0.9; }
function padMove(e) {
  const r = pad.getBoundingClientRect();
  let dx = (e.clientX - (r.left + r.width / 2)) / (r.width / 2), dy = (e.clientY - (r.top + r.height / 2)) / (r.height / 2);
  const m = Math.hypot(dx, dy); if (m > 1) { dx /= m; dy /= m; }
  vec = { x: dx, y: -dy };
  knob.style.transform = "translate(" + (dx * r.width * 0.3) + "px," + (dy * r.height * 0.3) + "px)";
}
function sendDrive() { if (padCam) act({ action: "drive", camera: padCam, x: curve(vec.x), y: curve(vec.y) }, true); }
pad.addEventListener("pointerdown", e => {
  if (!camId) return;
  pad.setPointerCapture(e.pointerId); padOn = true; padCam = camId; padMove(e); sendDrive();
  padTimer = setInterval(sendDrive, 120);
});
pad.addEventListener("pointermove", e => { if (padOn) padMove(e); });
function padEnd() {
  if (!padOn) return;
  padOn = false; clearInterval(padTimer); vec = { x: 0, y: 0 }; knob.style.transform = "";
  const c = padCam; padCam = null;
  if (c) act({ action: "drive", camera: c, x: 0, y: 0 }, true).then(() => act({ action: "stopcam" }, true));
}
["pointerup", "pointercancel", "lostpointercapture"].forEach(ev => pad.addEventListener(ev, padEnd));

let zoomTimer = null, zoomCam = null;
function holdZoom(btn, speed) {
  btn.addEventListener("pointerdown", e => {
    if (!camId) return;
    btn.setPointerCapture(e.pointerId); zoomCam = camId;
    const send = () => act({ action: "zoom", camera: zoomCam, speed }, true);
    send(); zoomTimer = setInterval(send, 120);
  });
  const end = () => {
    if (!zoomTimer) return;
    clearInterval(zoomTimer); zoomTimer = null;
    const c = zoomCam; zoomCam = null;
    if (c) act({ action: "zoom", camera: c, speed: 0 }, true).then(() => act({ action: "stopcam" }, true));
  };
  ["pointerup", "pointercancel", "lostpointercapture"].forEach(ev => btn.addEventListener(ev, end));
}
holdZoom($("#zin"), 0.5); holdZoom($("#zout"), -0.5);
function stopEverything() { padEnd(); if (zoomTimer) { clearInterval(zoomTimer); zoomTimer = null; } if (token) act({ action: "stopcam" }, true); }
document.addEventListener("visibilitychange", () => { if (document.hidden) stopEverything(); });
window.addEventListener("pagehide", stopEverything);
window.addEventListener("blur", stopEverything);

// ---- Pictures. Next and Live are streams (the Mac pushes a new frame as soon as there is one, so there is no
// ---- polling delay). The small tiles refresh one at a time, so they never use up the browser's connections.
function hasPicture(input) { return !!(st && st.sources.some(s => s.input === input && s.picture)); }
function setStream(img, input) {
  const want = input && hasPicture(input) && !document.hidden ? String(input) : "";
  if (img.dataset.input === want) return;
  img.dataset.input = want;
  clearTimeout(+img.dataset.retry || 0);
  if (!want) { img.removeAttribute("src"); img.classList.remove("has"); return; }
  img.src = "/api/stream?input=" + want + "&w=800&fps=15&t=" + encodeURIComponent(token) + "&n=" + Date.now();
}
for (const sel of ["#monNext img", "#monLive img"]) {
  const img = $(sel);
  img.addEventListener("load", () => img.classList.add("has"));
  img.addEventListener("error", () => {
    img.classList.remove("has"); img.dataset.input = "";            // try again shortly, if it should still be showing
    img.dataset.retry = setTimeout(() => { if (st && polling) setStream(img, sel.includes("Next") ? st.next && st.next.input : st.live && st.live.input); }, 1500);
  });
}
function updateStreams() {
  setStream($("#monNext img"), st.next && st.next.input);
  setStream($("#monLive img"), st.live && st.live.input);
}
document.addEventListener("visibilitychange", () => { if (st) updateStreams(); });

async function loadTile(img, input) {
  if (!input || img.dataset.busy) return;
  img.dataset.busy = "1";
  try {
    const r = await api("/api/picture?input=" + input + "&w=240");
    if (r.status === 200) {
      const url = URL.createObjectURL(await r.blob()), old = img.dataset.url;
      img.src = url; img.dataset.url = url; img.classList.add("has");
      if (old) URL.revokeObjectURL(old);
    } else img.classList.remove("has");
  } catch (e) {}
  delete img.dataset.busy;
}
let tileTurn = 0;
function picLoop() {
  if (!polling) return;
  if (st && !document.hidden) {
    const tiles = [...$("#tiles").children].filter(b => b.dataset.pic);
    if (tiles.length) { const b = tiles[tileTurn++ % tiles.length]; loadTile(b.querySelector("img"), +b.dataset.input); }
  }
  setTimeout(picLoop, 500);
}

if (token) { start(); } else { showLogin(); }
</script>
</body>
</html>
"""#
}
