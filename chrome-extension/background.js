// Akku Monitor – Tabs
// Schickt der Mac-App (lokal auf 127.0.0.1) die Liste der Tabs. Die App antwortet mit Tabs,
// deren Prozess sie noch nicht kennt. Für jeden davon läuft im Tab 0,15 s eine kleine Rechenlast,
// die App erkennt daran, welcher Chrome-Prozess zu dem Tab gehört. Es werden keine Daten
// aus den Seiten gelesen und nichts verlässt den Mac.

const BASE = "http://127.0.0.1:47830";
const HEADERS = { "Content-Type": "application/json", "X-Akku-Monitor": "1" };
const BURST_MS = 150;

let running = false;
let timer = null;

async function post(path, body) {
  const r = await fetch(BASE + path, { method: "POST", headers: HEADERS, body: JSON.stringify(body) });
  if (!r.ok) throw new Error("HTTP " + r.status);
  return r.json();
}

function schedule(delay = 1500) {
  clearTimeout(timer);
  timer = setTimeout(sync, delay);
}

function burst(ms) {
  const end = performance.now() + ms;
  let x = 0;
  while (performance.now() < end) x += Math.sqrt(x + 1);
  return x > 0;
}

function withTimeout(promise, ms) {
  return Promise.race([promise, new Promise((_, reject) => setTimeout(() => reject(new Error("timeout")), ms))]);
}

async function calibrate(tabId) {
  try {
    await post("/calib/start", { tabId });
    await withTimeout(chrome.scripting.executeScript({ target: { tabId }, func: burst, args: [BURST_MS] }), 4000);
    await post("/calib/end", { tabId });
  } catch (e) {
    try { await post("/calib/end", { tabId, failed: true }); } catch (_) {}
  }
}

async function sync() {
  if (running) { schedule(3000); return; }
  running = true;
  try {
    const tabs = await chrome.tabs.query({});
    const payload = tabs.map((t) => ({
      id: t.id,
      windowId: t.windowId,
      title: t.title || "",
      url: t.url || t.pendingUrl || "",
      active: !!t.active,
      audible: !!t.audible,
      discarded: !!t.discarded || !!t.frozen,
      pinned: !!t.pinned,
    }));
    const res = await post("/tabs", { tabs: payload });
    for (const id of res.calibrate || []) await calibrate(id);
    chrome.action.setBadgeText({ text: "" });
    chrome.action.setTitle({ title: "Akku Monitor: verbunden" });
  } catch (e) {
    chrome.action.setBadgeText({ text: "!" });
    chrome.action.setBadgeBackgroundColor({ color: "#d03b3b" });
    chrome.action.setTitle({ title: "Akku Monitor: App läuft nicht" });
  } finally {
    running = false;
  }
}

chrome.alarms.create("sync", { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener(() => sync());
chrome.tabs.onUpdated.addListener((_id, info) => {
  if (info.status === "complete" || info.audible !== undefined || info.discarded !== undefined || info.frozen !== undefined) schedule();
});
chrome.tabs.onRemoved.addListener(() => schedule());
chrome.tabs.onCreated.addListener(() => schedule(4000));
chrome.runtime.onStartup.addListener(() => schedule(5000));
chrome.runtime.onInstalled.addListener(() => schedule(500));
chrome.action.onClicked.addListener(() => sync());
