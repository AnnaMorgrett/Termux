// S2 UI test: loads the real page in jsdom against a live webui.py and clicks through it.
// Usage: node s2_ui_test.js <port>   (needs the jsdom npm package; optional on the phone)
const { JSDOM } = require("jsdom");
const port = process.argv[2]; const base = "http://127.0.0.1:" + port;
let pass = 0, fail = 0;
const chk = (n, c, x) => { if (c) { pass++; console.log("  PASS: " + n); } else { fail++; console.log("  FAIL: " + n + " " + (x || "")); } };
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function until(fn, ms = 15000) { const e = Date.now() + ms; while (Date.now() < e) { try { if (fn()) return true; } catch (e) {} await sleep(150); } return false; }
(async () => {
  const errors = [];
  const dom = await JSDOM.fromURL(base + "/", { runScripts: "dangerously", resources: "usable", pretendToBeVisual: true,
    beforeParse(w) {
      w.fetch = (p, o) => fetch(new URL(p, base), o);
      w.confirm = () => true;
      w.addEventListener("error", e => errors.push(String(e.error || e.message)));
    } });
  const w = dom.window, d = w.document;
  chk("page loads, 4 stat tiles appear", await until(() => d.querySelectorAll("#stats .stat").length === 4));
  chk("bottom navigation has 4 tabs", d.querySelectorAll("nav button").length === 4);
  chk("worker pill shows idle", /idle/.test(d.getElementById("wpill").textContent));
  chk("Stop disabled / Start enabled while idle", d.getElementById("bStop").disabled && !d.getElementById("bStart").disabled);

  // add links from the UI
  d.getElementById("addbox").value = "https://s.com/ui1\nhttps://s.com/ui2\nhttps://s.com/uibad";
  d.getElementById("bAdd").click();
  chk("add shows 3 green results", await until(() => d.querySelectorAll("#addres div").length === 3));
  chk("textbox cleared after adding", d.getElementById("addbox").value === "");
  chk("toast says 3 queued", /3 queued/.test(d.getElementById("toast").textContent));
  chk("stats update: worker running or jobs counted", await until(() => { const t = [...d.querySelectorAll("#stats .stat b")].map(b => +b.textContent); return t.reduce((a, b) => a + b, 0) === 3; }));

  // queue tab
  d.querySelector('nav button[data-k="queue"]').click();
  chk("queue tab visible, others hidden", !d.getElementById("tab-queue").classList.contains("hide") && d.getElementById("tab-status").classList.contains("hide"));
  chk("all jobs finish: 2 done + 1 failed listed", await until(() => d.querySelectorAll("#joblist .job").length === 3 && d.querySelectorAll("#joblist .badge.done").length === 2 && d.querySelectorAll("#joblist .badge.failed").length === 1, 60000));
  chk("failed job shows its reason", /download failed/.test(d.querySelector("#joblist .err").textContent));
  chk("filter chips carry counts", [...d.querySelectorAll("#chips .chip")].map(c => c.textContent).join("|") === "All 3|Pending 0|Running 0|Failed 1|Done 2", [...d.querySelectorAll("#chips .chip")].map(c => c.textContent).join("|"));
  [...d.querySelectorAll("#chips .chip")].find(c => c.dataset.k === "failed").click();
  chk("Failed filter shows only the failed job", await until(() => d.querySelectorAll("#joblist .job").length === 1));
  const retry = [...d.querySelectorAll("#joblist button")].find(b => b.textContent === "Retry");
  chk("failed job has Retry and Remove buttons", !!retry && [...d.querySelectorAll("#joblist button")].some(b => b.textContent === "Remove"));
  retry.click();
  chk("Retry gives feedback", await until(() => /Queued again/.test(d.getElementById("toast").textContent)));
  chk("it fails again (still 1 failed)", await until(() => d.querySelectorAll("#joblist .badge.failed").length === 1, 30000));
  [...d.querySelectorAll("#joblist button")].find(b => b.textContent === "Remove").click();
  chk("Remove deletes it from the list", await until(() => /No jobs here/.test(d.getElementById("joblist").textContent)));
  d.getElementById("bClearDone").click();

  // XSS: a file NAME containing markup must be shown as text only
  const evil = process.env.EVIL_FILE;
  d.querySelector('nav button[data-k="status"]').click();
  d.getElementById("addbox").value = evil;
  d.getElementById("bAdd").click();
  chk("file with markup in its name is queued", await until(() => /1 queued/.test(d.getElementById("toast").textContent)));
  d.querySelector('nav button[data-k="queue"]').click();
  [...d.querySelectorAll("#chips .chip")].find(c => c.dataset.k === "").click();
  chk("it appears in the list", await until(() => [...d.querySelectorAll("#joblist .v")].some(v => v.textContent.includes("<img src=x"))));
  chk("shown as text: no <img> element, no script ran", d.querySelectorAll("#joblist img, #addres img, #toast img").length === 0 && !w.__pwn);
  await until(() => d.querySelectorAll("#joblist .badge.done").length >= 1, 60000);

  // logs tab
  d.querySelector('nav button[data-k="logs"]').click();
  chk("logs tab shows worker lines", await until(() => /Worker (start|finished)/.test(d.getElementById("logbox").textContent)));
  chk("events-only is on by default: no ffmpeg lines", d.getElementById("logev").checked && !/Stream mapping/.test(d.getElementById("logbox").textContent));
  d.getElementById("logev").checked = false; d.getElementById("logev").dispatchEvent(new w.Event("change"));
  chk("turning it off shows the raw ffmpeg output", await until(() => /Stream mapping|Input #0/.test(d.getElementById("logbox").textContent)));

  // settings tab
  d.querySelector('nav button[data-k="settings"]').click();
  chk("settings form has 7 fields with defaults", await until(() => d.querySelectorAll("#cfg [id^=cfg_]").length === 7) && d.getElementById("cfg_TARGET_LUFS").value === "-9" && d.getElementById("cfg_AUDIO_BITRATE").value === "192k");
  const pp = d.getElementById("cfg_PEAK_PERCENT"); pp.value = "50"; pp.dispatchEvent(new w.Event("input"));
  chk("peak percent shows its dB live (50% = -4.55 dB)", /-4\.55 dB/.test(d.getElementById("peakdb").textContent), d.getElementById("peakdb").textContent);
  pp.value = "100"; pp.dispatchEvent(new w.Event("input"));
  chk("100% = -0.10 dB", /-0\.10 dB/.test(d.getElementById("peakdb").textContent));
  chk("mode is a dropdown with peak and lufs", [...d.querySelectorAll("#cfg_NORM_MODE option")].map(o => o.value).join() === "peak,lufs");
  d.getElementById("cfg_TARGET_LUFS").value = "oops"; d.getElementById("bSave").click();
  chk("invalid value shows the server's message", await until(() => /TARGET_LUFS must be a number/.test(d.getElementById("toast").textContent)));
  d.getElementById("cfg_TARGET_LUFS").value = "-14"; d.getElementById("bSave").click();
  chk("valid value saved and marked as changed", await until(() => /Saved/.test(d.getElementById("toast").textContent)) && await until(() => /\(changed\)/.test(d.getElementById("cfg").textContent)));
  d.getElementById("bReset").click();
  chk("reset restores defaults", await until(() => d.getElementById("cfg_TARGET_LUFS").value === "-9" && !/\(changed\)/.test(d.getElementById("cfg").textContent)));

  chk("no JavaScript errors during the whole session", errors.length === 0, errors.join(" | "));
  console.log("\nRESULT: " + pass + " passed, " + fail + " failed");
  w.close(); process.exit(fail ? 1 : 0);
})().catch(e => { console.log("CRASH", e); process.exit(2); });
