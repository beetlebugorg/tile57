// The demo app: boot the engine worker, wire the chrome, and run the render
// loop. Everything stateful lives in the focused modules - camera.mjs (the
// view), chart-store.mjs (charts on disk / resident in the engine),
// import.mjs (drops -> bakes), mariner.mjs (S-52 settings), pick-*.mjs (the
// cursor pick) - this file is the wiring between them and the DOM.

import { GpuRenderer } from "../gpu-renderer.mjs";
import { makeRpc } from "../worker-rpc.mjs";
import { STYLE, CHROME } from "./view.mjs";
import { PICK_STYLE, PICK_CHROME, PickReport } from "./pick-report.mjs";
import {
  cam, viewW, viewH, screenToWorld, worldToScreen, worldToLonLat, lonLatToWorld,
  scaleDenom, zoomAt, fitTo, restoreView, saveView,
} from "./camera.mjs";
import { wireGestures } from "./gestures.mjs";
import { ChartStore } from "./chart-store.mjs";
import { ChartImporter } from "./import.mjs";
import { loadStored, saveStored, SCHEMES } from "./mariner.mjs";
import { renderSettings } from "./settings-panel.mjs";

const q = new URLSearchParams(location.search);

// ---- chrome ---------------------------------------------------------------
const root = document.getElementById("root");
root.innerHTML = `<style>${STYLE}${PICK_STYLE}</style>${CHROME}${PICK_CHROME}`;
const $ = (id) => root.querySelector(`#${id}`);
const canvas = $("map"), img = $("mapimg");

function toast(msg, error = false) {
  const el = document.createElement("div");
  el.className = `toast${error ? " error" : ""}`;
  el.textContent = msg;
  $("toasts").append(el);
  setTimeout(() => { el.classList.add("out"); setTimeout(() => el.remove(), 350); }, 5000);
}
const sub = (msg, bad = false) => {
  $("db-sub").textContent = msg;
  $("db-sub").classList.toggle("bad", bad);
};
const splash = (label) => { $("splash-label").textContent = label; };
const splashDone = () => { $("splash").classList.add("hide"); setTimeout(() => $("splash").remove(), 500); };
setTimeout(splashDone, 30000); // never trap the user behind the splash

// ---- the engine, in its worker --------------------------------------------
const workerUrl = new URL("./engine-worker.mjs", location.href);
const wasmUrl = new URL(q.get("wasm") || "./tile57-engine.wasm", location.href).href;
const worker = new Worker(workerUrl, { type: "module" });
const rpc = makeRpc(worker);
worker.onerror = (e) => { console.error(e); toast(`engine worker failed: ${e.message ?? "see console"}`, true); };

const dpr = Math.min(devicePixelRatio || 1, 2);
const SCENE_MARGIN = Math.min(3, Math.max(1, parseFloat(q.get("margin")) || 1.6));
const store = new ChartStore(rpc, {
  margin: SCENE_MARGIN,
  maxOpen: Math.min(128, Math.max(4, parseInt(q.get("open")) || 64)),
});
const importer = new ChartImporter(rpc, store, {
  workerUrl, wasmUrl,
  workers: Math.min(8, Math.max(1, parseInt(q.get("workers")) || Math.min(4, (navigator.hardwareConcurrency || 2) - 1))),
});

const initPromise = rpc("init", { wasmUrl }); // engine downloads while we set up
await store.openLibrary();

let version = "";
try {
  ({ version } = await initPromise);
} catch (e) {
  console.error(e);
  splash(`The engine failed to start: ${e.message}`);
  throw e;
}

// ---- mariner settings + renderer ------------------------------------------
let mariner = loadStored(await rpc("marinerDefaults"));
const schemeIdx = () => Math.max(0, SCHEMES.indexOf(mariner.scheme));
const applySchemeChrome = () => {
  if (mariner.scheme === "day") delete root.dataset.scheme;
  else root.dataset.scheme = mariner.scheme;
};
applySchemeChrome();

let gpu = null, gpuWhy = "";
if (q.get("png")) gpuWhy = "?png=1";
else if (!isSecureContext) gpuWhy = "insecure context - WebGPU needs https or localhost";
else if (!GpuRenderer.supported()) gpuWhy = "navigator.gpu is not exposed";
else {
  try {
    splash("Baking symbol and glyph atlases…");
    gpu = await GpuRenderer.create(canvas, dpr, await rpc("gpuAssets", { pixelRatio: dpr, scheme: schemeIdx() }));
  } catch (e) {
    console.error(e);
    gpuWhy = e.message;
  }
}
const surface = gpu ? canvas : img;
if (!gpu) {
  canvas.style.display = "none";
  img.style.display = "block";
  if (gpuWhy !== "?png=1") toast(`PNG fallback: ${gpuWhy}`, false);
}
$("attr-engine").textContent = `tile57 ${version} · ${gpu ? "WebGPU" : "PNG"}`;

function sizeCanvas() {
  canvas.width = Math.max(1, Math.round(viewW() * dpr));
  canvas.height = Math.max(1, Math.round(viewH() * dpr));
}
sizeCanvas();

// ---- the render loop ------------------------------------------------------
let sceneCam = null, lastSet = { compose: 0, chart: 0 };
let rebuildTimer = 0, rebuilding = false, rebuildAgain = false, lastLive = 0;

function renderDims() {
  const w = Math.round(viewW() * dpr), h = Math.round(viewH() * dpr);
  const c = Math.abs(Math.cos(cam.rot)), sn = Math.abs(Math.sin(cam.rot));
  return [
    Math.min(4096, Math.round((w * c + h * sn) * SCENE_MARGIN)),
    Math.min(4096, Math.round((w * sn + h * c) * SCENE_MARGIN)),
  ];
}
function pngPlace() {
  if (!sceneCam) return;
  const [px, py] = worldToScreen(...lonLatToWorld(sceneCam.lon, sceneCam.lat));
  const k = 2 ** (cam.zoom - sceneCam.zoom);
  img.style.transform = `translate(${px - viewW() / 2}px, ${py - viewH() / 2}px) rotate(${cam.rot}rad) scale(${k})`;
}
let rafPending = false;
function redraw() {
  hud();
  if (!gpu || !store.catalog.length || rafPending) return;
  rafPending = true;
  requestAnimationFrame(() => { rafPending = false; gpu.draw(cam); });
}
function afterCamera() {
  hud();
  if (gpu) { redraw(); liveRebuild(); }
  else pngPlace();
}
function liveRebuild() {
  if (!gpu || rebuilding) return;
  const now = performance.now();
  if (now - lastLive < 250) return;
  lastLive = now;
  rebuild();
}
function scheduleRebuild(ms = 250) {
  clearTimeout(rebuildTimer);
  rebuildTimer = setTimeout(rebuild, ms);
}
async function rebuild() {
  if (!store.catalog.length) return;
  if (rebuilding) { rebuildAgain = true; return; }
  rebuilding = true;
  const t0 = performance.now();
  const [w, h] = renderDims();
  try {
    const set = await store.ensureView();
    lastSet = set;
    if (!set.compose && !set.chart) {
      if (gpu) { gpu.disposeScene(); gpu.draw(cam); } else img.removeAttribute("src");
      sceneCam = { ...cam };
      sub("no charts cover this view");
    } else {
      const view = { compose: set.compose, chart: set.chart, lon: cam.lon, lat: cam.lat, zoom: cam.zoom, w, h, mariner };
      if (gpu) {
        const scene = await rpc("gpuScene", { ...view, pixelRatio: dpr, atlasHave: gpu.atlasHave, halo: gpu.halo });
        gpu.setScene(scene);
        gpu.draw(cam);
      } else {
        const png = await rpc("png", view);
        if (img.dataset.url) URL.revokeObjectURL(img.dataset.url);
        img.dataset.url = URL.createObjectURL(new Blob([png], { type: "image/png" }));
        img.src = img.dataset.url;
        img.style.width = `${w / dpr}px`;
        img.style.height = `${h / dpr}px`;
        img.style.left = `${(viewW() - w / dpr) / 2}px`;
        img.style.top = `${(viewH() - h / dpr) / 2}px`;
      }
      sceneCam = { ...cam };
      if (!gpu) pngPlace();
      if ($("db-sub").textContent.startsWith("no charts")) sub("");
      saveView();
    }
  } catch (e) {
    console.error(e);
    sub(`render failed: ${e.message}`, true);
  }
  rebuilding = false;
  splashDone();
  if (rebuildAgain) { rebuildAgain = false; scheduleRebuild(0); }
  hud();
}

// ---- the data card --------------------------------------------------------
let cursorLL = null;
function hud() {
  const on = store.catalog.length > 0;
  $("databox").hidden = !on;
  $("welcome").hidden = on;
  if (!on) return;
  $("hud-scale").textContent = `1:${Math.round(scaleDenom(cam.zoom)).toLocaleString()}`;
  $("hud-z").textContent = `z${cam.zoom.toFixed(1)}`;
  const [lon, lat] = cursorLL ?? [cam.lon, cam.lat];
  $("hud-coord").textContent = `${lat.toFixed(4)}, ${lon.toFixed(4)}`;
  const hdg = Math.round((((-cam.rot * 180) / Math.PI) % 360 + 360) % 360);
  $("hud-hdg").textContent = hdg ? ` ↑${String(hdg).padStart(3, "0")}°` : "";
  $("needle").style.transform = `rotate(${cam.rot}rad)`;
}
function progress(done, total, label) {
  const box = $("db-prog");
  if (total === -1) { box.hidden = true; return; }
  box.hidden = false;
  $("databox").hidden = false;
  $("welcome").hidden = true;
  $("db-prog-title").textContent = "Importing charts";
  $("db-prog-action").textContent = label ?? "";
  $("db-prog-count").textContent = total ? `${done} of ${total}` : "";
  const fill = $("db-prog-fill");
  fill.classList.toggle("indet", !total);
  if (total) fill.style.width = `${Math.round((done / total) * 100)}%`;
}

// ---- importing ------------------------------------------------------------
async function importFiles(files) {
  const { added, failed, skipped } = await importer.loadFiles(files, {
    progress,
    onChart: () => hud(),
  });
  progress(0, -1);
  if (failed.length) toast(failed.slice(0, 2).join("; ") + (failed.length > 2 ? ` (+${failed.length - 2} more)` : ""), true);
  if (skipped) sub(`${skipped} chart${skipped > 1 ? "s" : ""} already in the library`);
  if (!added.length) { hud(); return; }
  fitTo(added);
  sub(`${store.catalog.length} chart${store.catalog.length > 1 ? "s" : ""} in the library`);
  await rebuild();
}
window.tile57Drops.handler = (files) => importFiles(files);
if (window.tile57Drops.pending.length) importFiles(window.tile57Drops.pending.splice(0));
addEventListener("t57-dragover", () => root.classList.add("droptarget"));
addEventListener("t57-dragleave", () => root.classList.remove("droptarget"));

// The bundled sample (staged by the docs workflow; absent locally is fine).
fetch("./sample.zip", { method: "HEAD" }).then((r) => {
  if (!r.ok) return;
  const btn = document.createElement("button");
  btn.className = "cta";
  btn.textContent = "⛵ Or try a sample harbor";
  btn.style.marginTop = "8px";
  btn.addEventListener("click", async () => {
    btn.disabled = true;
    const blob = await (await fetch("./sample.zip")).blob();
    await importFiles([new File([blob], "sample.zip")]);
  });
  root.querySelector("#welcome .card .cta").after(document.createElement("br"), btn);
}).catch(() => {});

// ---- gestures + controls --------------------------------------------------
wireGestures(surface, root, {
  enabled: () => store.catalog.length > 0,
  onMove: (mx, my) => {
    cursorLL = worldToLonLat(...screenToWorld(mx, my));
    hud();
  },
  onChange: afterCamera,
  onSettle: (ms) => scheduleRebuild(gpu ? Math.max(ms, 200) : Math.max(ms, 300)),
  onTap: async (mx, my) => {
    if (!lastSet.compose && !lastSet.chart) return;
    const [lon, lat] = worldToLonLat(...screenToWorld(mx, my));
    try {
      const features = await rpc("pick", { compose: lastSet.compose, chart: lastSet.chart, lon, lat, zoom: cam.zoom });
      if (!pick.show(features)) sub("nothing charted here");
    } catch (e) {
      console.error(e);
      sub(`pick failed: ${e.message}`, true);
    }
  },
});
const pick = new PickReport(root);

$("zi").addEventListener("click", () => { zoomAt(viewW() / 2, viewH() / 2, 1); afterCamera(); scheduleRebuild(0); });
$("zo").addEventListener("click", () => { zoomAt(viewW() / 2, viewH() / 2, -1); afterCamera(); scheduleRebuild(0); });
$("north").addEventListener("click", () => { cam.rot = 0; afterCamera(); scheduleRebuild(0); });
$("fs").addEventListener("click", () =>
  document.fullscreenElement ? document.exitFullscreen() : document.documentElement.requestFullscreen());
addEventListener("resize", () => { sizeCanvas(); if (gpu) redraw(); scheduleRebuild(200); });

$("lib").addEventListener("click", async () => {
  if (!confirm("Clear the chart library and reload the page?")) return;
  await store.clear();
  location.reload();
});

// ---- scheme + settings ----------------------------------------------------
async function applyMariner(patch) {
  const schemeChanged = patch.scheme && patch.scheme !== mariner.scheme;
  mariner = { ...mariner, ...patch };
  saveStored(mariner);
  if (schemeChanged) {
    applySchemeChrome();
    if (gpu) {
      try {
        gpu.setScheme(mariner.scheme, await rpc("spriteAtlas", { pixelRatio: dpr, scheme: schemeIdx() }));
      } catch (e) {
        console.warn("scheme atlas:", e);
      }
    }
  }
  scheduleRebuild(0);
}
$("scheme").addEventListener("click", () =>
  applyMariner({ scheme: SCHEMES[(schemeIdx() + 1) % SCHEMES.length] }));

const drawer = $("drawer");
const renderPanel = () => renderSettings($("settings-body"), mariner, (key, value) => {
  applyMariner({ [key]: value });
  renderPanel(); // groups are unit-aware; re-render keeps rows current
});
$("settings").addEventListener("click", () => {
  drawer.classList.toggle("open");
  if (drawer.classList.contains("open")) renderPanel();
});
$("drawer-close").addEventListener("click", () => drawer.classList.remove("open"));

// ---- land on the library --------------------------------------------------
splash("Opening the chart library…");
await store.loadSaved((n, total) => splash(`Indexing the library - ${n} of ${total}…`));
hud();
if (store.catalog.length) {
  if (!restoreView()) fitTo(store.catalog);
  sub(`${store.catalog.length} chart${store.catalog.length > 1 ? "s" : ""} in the library`);
  await rebuild();
} else {
  splashDone();
}
