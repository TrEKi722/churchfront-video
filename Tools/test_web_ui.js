// Drives the iPad page in a real browser against Tools/fake_web_api.py and checks what it sends.
//   python3 Tools/fake_web_api.py 9930 &
//   node Tools/test_web_ui.js http://localhost:9930 [screenshot-folder]
const { chromium } = require("playwright");
const base = process.argv[2] || "http://localhost:9930";
const shots = process.argv[3] || null;
let failed = 0;
const ok = (c, m) => { console.log((c ? "PASS " : "FAIL ") + m); if (!c) failed++; };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const log = async () => (await fetch(base + "/_log")).json();

(async () => {
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1180, height: 820 }, deviceScaleFactor: 2, hasTouch: true });
  const page = await ctx.newPage();
  const errors = []; page.on("pageerror", e => errors.push(String(e))); page.on("console", m => { if (m.type() === "error" && !/status of 401/.test(m.text())) errors.push(m.text()); });  // 401s are expected in the bad-key check
  await fetch(base + "/_reset");

  // Login
  await page.goto(base);
  ok(await page.locator("#login").isVisible(), "login screen shows with no saved key");
  await page.fill("#pin", "000000"); await page.click("#go");
  await page.waitForFunction(() => document.querySelector("#loginErr").textContent.length > 0);
  ok((await page.textContent("#loginErr")).includes("isn't right"), "wrong PIN is refused with a message");
  await page.fill("#pin", "123456"); await page.click("#go");
  await page.waitForSelector("#app:not([hidden])");
  ok(true, "right PIN opens the booth");
  await page.waitForSelector("#tiles .tile");
  await sleep(1200);
  if (shots) await page.screenshot({ path: shots + "/landscape.png" });

  ok((await page.textContent("#monNext .label")) === "Cam 1" && (await page.textContent("#monLive .label")) === "Cam 2", "Next is Cam 1 and Live is Cam 2");
  ok(await page.locator("#monNext img.has").count() === 1, "the Next picture loads");
  ok((await page.locator("#tiles .tile").count()) === 3, "three source tiles");
  ok(/Cam 1/.test(await page.textContent("#camname")), "camera panel shows the camera on Next");

  // Take
  await page.click('#tiles .tile[data-input="3"]');
  await sleep(700);
  ok((await page.textContent("#monNext .label")) === "Cam 3", "tapping a tile puts it on Next");
  ok((await page.textContent("#camname")).includes("Put a camera on Next"), "no camera moves when the source on Next has none");
  ok(await page.locator("#pad.off").count() === 1, "joystick is dimmed with no camera on Next");
  await page.click('#tiles .tile[data-input="1"]'); await sleep(700);
  await page.click("#cut"); await sleep(700);
  ok((await page.textContent("#monLive .label")) === "Cam 1", "Cut puts Next on Live");
  await page.click("#fade"); await sleep(700);
  await page.click("#black"); await sleep(700);
  ok((await page.textContent("#black")).includes("ON"), "Black shows as on");
  await page.click("#black"); await sleep(500);

  // Joystick: Cam 2 is on Next after the fade; drag right and up, then let go.
  await page.waitForFunction(() => document.querySelector("#camname").textContent.includes("Cam"));
  const box = await page.locator("#pad").boundingBox();
  const cx = box.x + box.width / 2, cy = box.y + box.height / 2;
  await fetch(base + "/_reset");
  await page.click('#tiles .tile[data-input="1"]'); await sleep(600);
  await page.mouse.move(cx, cy); await page.mouse.down(); await page.mouse.move(cx + box.width * 0.4, cy - box.height * 0.3, { steps: 5 });
  await sleep(450);
  const mid = (await log()).filter(a => a.action === "drive");
  await page.mouse.up(); await sleep(500);
  const all = await log();
  const drives = all.filter(a => a.action === "drive");
  ok(mid.length >= 3 && mid.some(a => a.x > 0.2 && a.y > 0.1), "holding the pad sends repeated drive messages right and up (" + mid.length + ")");
  ok(drives[drives.length - 1].x === 0 && drives[drives.length - 1].y === 0, "letting go sends a zero drive");
  ok(all[all.length - 1].action === "stopcam", "and then a stop");

  // Zoom
  await fetch(base + "/_reset"); await sleep(500);
  const z = await page.locator("#zin").boundingBox();
  await page.mouse.move(z.x + 20, z.y + 20); await page.mouse.down(); await sleep(400); await page.mouse.up(); await sleep(400);
  const zooms = (await log()).filter(a => a.action === "zoom");
  ok(zooms.length >= 2 && zooms[0].speed === 0.5 && zooms[zooms.length - 1].speed === 0, "holding zoom in sends +0.5 repeatedly, then 0");

  // Track, shot, key, stream
  await fetch(base + "/_reset"); await sleep(500);
  await page.click("#track"); await sleep(600);
  ok((await log()).some(a => a.action === "track" && a.shot === "waist"), "Track starts following at Waist");
  ok((await page.textContent("#track")) === "TRACKING", "button shows TRACKING");
  await page.click('#sizes button[data-size="full"]'); await sleep(500);
  ok((await log()).some(a => a.action === "track" && a.shot === "full"), "changing the shot size while tracking reframes");
  await page.click("#track"); await sleep(600);
  ok((await log()).some(a => a.action === "untrack"), "Track again stops it");
  await page.click("#shots button >> text=Pulpit");
  ok((await log()).some(a => a.action === "shot" && a.shot === "Pulpit"), "a shot button recalls it");
  await page.click('#keys button >> text=Lower thirds'); await sleep(500);
  ok((await page.locator('#keys button.on').count()) === 1, "key button lights when on air");
  await page.click("#stream");
  ok(await page.locator("#modal").isVisible(), "Stream asks first");
  await page.click("#no"); ok(!(await log()).some(a => a.action === "stream"), "Cancel sends nothing");
  await page.click("#stream"); await page.click("#yes"); await sleep(600);
  ok((await log()).some(a => a.action === "stream" && a.on === true), "confirming starts the stream");
  ok((await page.textContent("#stream")) === "STREAMING", "stream button shows STREAMING");

  // Leaving the page stops the camera
  await fetch(base + "/_reset"); await sleep(400);
  await page.evaluate(() => window.dispatchEvent(new Event("pagehide"))); await sleep(300);
  ok((await log()).some(a => a.action === "stopcam"), "leaving the page sends a stop");

  // A bad key goes back to the PIN screen
  await page.evaluate(() => { token = "bad"; }); await sleep(900);
  ok(await page.locator("#login").isVisible(), "a rejected key returns to the PIN screen");

  // Portrait
  await page.setViewportSize({ width: 820, height: 1180 });
  await page.evaluate(() => { token = "tok-test"; }); await page.fill("#pin", "123456"); await page.click("#go");
  await page.waitForSelector("#app:not([hidden])"); await sleep(1200);
  if (shots) await page.screenshot({ path: shots + "/portrait.png", fullPage: true });
  ok(errors.length === 0, "no script errors" + (errors.length ? ": " + errors.join("; ") : ""));
  await browser.close();
  console.log(failed ? failed + " FAILED" : "ALL PASSED");
  process.exit(failed ? 1 : 0);
})();
