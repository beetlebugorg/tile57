// Demo VIEW - the render chrome: the whole <style> sheet plus the static
// markup template. Both are PURE (no DOM, no state); app.mjs drops
// `<style>${STYLE}</style>${CHROME}` into the page and wires the ids.
//
// The look follows the chartplotter shell (chartplotter.view.mjs): the map IS
// the UI, chrome floats over it as round buttons and one bottom-centre data
// card, panels are caret popovers, and the --ui-* tokens re-skin everything
// for day / dusk / night via data-scheme on the root.

export const STYLE = `
  #root { position:fixed; inset:0; overflow:hidden; font:13px/1.4 system-ui,sans-serif;
    --tap-min:44px;
    --ui-bg:#fafafa; --ui-surface:#fff; --ui-surface-2:#eef1f4; --ui-text:#2a2f35;
    --ui-text-dim:#7a828b; --ui-text-faint:#9aa0a8; --ui-border:#e2e2e2; --ui-border-2:#ededed;
    --ui-border-strong:#cfcfcf; --ui-hover:#f0f3f6; --ui-accent:#1565c0; --ui-accent-hover:#1257a8;
    --ui-accent-text:#fff; --ui-shadow:rgba(0,0,0,.2); }
  #root[data-scheme="dusk"] {
    --ui-bg:#20262b; --ui-surface:#2a3137; --ui-surface-2:#333b42; --ui-text:#cdd6dc;
    --ui-text-dim:#9aa6ae; --ui-text-faint:#7d8990; --ui-border:#3a434a; --ui-border-2:#333b42;
    --ui-border-strong:#4a555d; --ui-hover:#353f47; --ui-accent:#4f9be6; --ui-accent-hover:#69abe9;
    --ui-accent-text:#0c1318; --ui-shadow:rgba(0,0,0,.5); }
  #root[data-scheme="night"] {
    --ui-bg:#14181b; --ui-surface:#1b2024; --ui-surface-2:#232a2f; --ui-text:#aeb8be;
    --ui-text-dim:#7e898f; --ui-text-faint:#626c72; --ui-border:#2a3137; --ui-border-2:#232a2f;
    --ui-border-strong:#38424a; --ui-hover:#232a30; --ui-accent:#3f7fb5; --ui-accent-hover:#4d8cc2;
    --ui-accent-text:#0a0e11; --ui-shadow:rgba(0,0,0,.6); }

  /* Full-bleed map; everything else floats over it. */
  /* Crosshair, the pick cursor - the hand only while actually grabbing. */
  #map, #mapimg { position:absolute; inset:0; width:100%; height:100%;
    touch-action:none; cursor:crosshair; user-select:none; }
  #mapimg { display:none; }
  #root.dragging #map, #root.dragging #mapimg { cursor:grabbing; }

  /* Round floating buttons (44px, translucent surface, blur). */
  .rbtn { flex:none; width:44px; height:44px; border-radius:50%; cursor:pointer; padding:0;
    display:flex; align-items:center; justify-content:center; color:var(--ui-text);
    background:color-mix(in srgb, var(--ui-surface) 90%, transparent); border:1px solid var(--ui-border);
    box-shadow:0 2px 10px rgba(0,0,0,.18); backdrop-filter:blur(6px);
    font:600 17px/1 system-ui,sans-serif;
    touch-action:manipulation; -webkit-user-select:none; user-select:none;
    transition:background .12s, color .12s, box-shadow .12s, transform .08s; }
  @media (hover:hover) { .rbtn:hover { color:var(--ui-accent); border-color:var(--ui-accent); box-shadow:0 3px 14px rgba(0,0,0,.24); } }
  .rbtn:active { transform:scale(.94); }
  .rbtn.on { background:var(--ui-accent); color:var(--ui-accent-text); border-color:var(--ui-accent); }
  .rbtn svg { width:21px; height:21px; display:block; }

  /* Compass, top-right: the needle tracks the view rotation. */
  #tr-controls { position:absolute; top:calc(12px + env(safe-area-inset-top,0px));
    right:calc(12px + env(safe-area-inset-right,0px)); z-index:7; display:flex; gap:8px; }
  #needle { display:block; transition:transform .12s ease; }
  /* Right-edge vertical stack: zoom + fullscreen, above the corner cluster. */
  #mr-controls { position:absolute; right:calc(12px + env(safe-area-inset-right,0px));
    bottom:calc(env(safe-area-inset-bottom,0px) + 130px); z-index:7;
    display:flex; flex-direction:column; gap:8px; }
  /* Bottom-right cluster: scheme · settings · clear-library. */
  #br-controls { position:absolute; right:calc(12px + env(safe-area-inset-right,0px));
    bottom:calc(env(safe-area-inset-bottom,0px) + 12px); z-index:7;
    display:flex; align-items:center; gap:8px; }

  /* Bottom-centre DATA CARD: the live readout (scale · zoom · position ·
     heading), job progress while a batch bakes, and warnings. One surface. */
  #databox { position:absolute; left:50%; bottom:calc(env(safe-area-inset-bottom,0px) + 14px);
    transform:translateX(-50%); z-index:6; box-sizing:border-box;
    display:flex; flex-direction:column; align-items:center; gap:6px; padding:8px 14px;
    width:min(94vw, 460px);
    background:color-mix(in srgb, var(--ui-surface) 92%, transparent); border:1px solid var(--ui-border);
    border-radius:13px; backdrop-filter:blur(7px); overflow:hidden;
    box-shadow:0 4px 18px rgba(0,0,0,.18);
    font:11px system-ui,sans-serif; color:var(--ui-text); }
  .db-readout { display:flex; align-items:center; justify-content:center; flex-wrap:wrap;
    gap:6px; row-gap:5px; width:100%;
    font-weight:600; font-size:12px; white-space:nowrap; font-variant-numeric:tabular-nums; }
  .db-readout .hud-scale { color:var(--ui-accent); }
  .db-readout .hud-z, .db-readout .hud-coord, .db-readout .hud-hdg { color:var(--ui-text-dim); }
  .db-readout .hud-sep { color:var(--ui-text-faint); }
  .db-sub { width:100%; text-align:center; color:var(--ui-text-dim); font-size:11px;
    overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .db-sub:empty { display:none; }
  .db-sub.bad { color:#c0392b; font-weight:600; }
  /* Job progress: title, action + count, track. Grows above the readout. */
  .db-prog { width:100%; box-sizing:border-box; display:flex; flex-direction:column; gap:7px;
    padding-bottom:9px; margin-bottom:2px; border-bottom:1px solid var(--ui-border); }
  .db-prog[hidden] { display:none; }
  .db-prog-title { font:600 12.5px/1.25 system-ui,sans-serif; color:var(--ui-text);
    overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .db-prog-status { display:flex; align-items:baseline; gap:10px;
    font:500 11.5px/1.3 system-ui,sans-serif; color:var(--ui-text-dim); }
  .db-prog-action { flex:1; min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .db-prog-count { flex:none; text-align:right; font-variant-numeric:tabular-nums; }
  .db-prog-track { position:relative; width:100%; height:6px; border-radius:3px; overflow:hidden; background:var(--ui-surface-2); }
  .db-prog-fill { position:absolute; left:0; top:0; bottom:0; width:0; border-radius:3px;
    background:var(--ui-accent); transition:width .3s ease; }
  .db-prog-fill.indet { width:30% !important; animation:db-sweep 1.9s ease-in-out infinite; }
  @keyframes db-sweep { 0% { left:-30%; } 100% { left:100%; } }
  @media (prefers-reduced-motion: reduce) { .db-prog-fill.indet { animation:none; left:0; width:100% !important; } }

  /* Toasts: bottom-centre stack above the data card (errors and notices). */
  #toasts { position:absolute; left:50%; bottom:calc(env(safe-area-inset-bottom,0px) + 96px);
    transform:translateX(-50%); z-index:9; display:flex; flex-direction:column; gap:8px;
    align-items:center; pointer-events:none; }
  .toast { pointer-events:auto; max-width:80vw; padding:9px 14px; border-radius:8px;
    font:600 12.5px/1.3 system-ui,sans-serif; color:var(--ui-text); background:var(--ui-surface);
    border:1px solid var(--ui-border-2); box-shadow:0 4px 16px rgba(0,0,0,.28);
    transition:opacity .3s ease, transform .3s ease; }
  .toast.error { border-color:#c0392b; color:#e06b5c; }
  .toast.out { opacity:0; transform:translateY(6px); }

  /* Attribution: one subtle line, bottom-left, with a soft halo over the chart. */
  #attr { position:absolute; left:calc(12px + env(safe-area-inset-left,0px));
    bottom:calc(env(safe-area-inset-bottom,0px) + 12px); z-index:5;
    font:500 10px/1.35 system-ui,sans-serif; letter-spacing:.01em; white-space:nowrap;
    color:var(--ui-text-dim);
    text-shadow:0 0 3px var(--ui-surface), 0 0 3px var(--ui-surface), 0 1px 1px var(--ui-surface); }
  #attr a { color:inherit; text-decoration:underline; text-decoration-color:var(--ui-text-faint); text-underline-offset:2px; }
  @media (hover:hover) { #attr a:hover { color:var(--ui-accent); } }

  /* Welcome card: the empty state (no charts yet). */
  #welcome { position:absolute; inset:0; display:flex; align-items:center; justify-content:center;
    z-index:4; pointer-events:none; }
  #welcome[hidden] { display:none; }
  #welcome .card { pointer-events:auto; background:var(--ui-surface); color:var(--ui-text);
    border-radius:16px; padding:30px 30px 24px; max-width:380px; text-align:center;
    box-shadow:0 8px 34px rgba(0,0,0,.22); }
  #welcome svg { width:44px; height:44px; margin-bottom:10px; color:var(--ui-accent); }
  #welcome h2 { margin:0 0 8px; font-size:21px; }
  #welcome p { color:var(--ui-text-dim); margin:0 0 14px; line-height:1.5; }
  #welcome .cta { display:inline-flex; align-items:center; gap:8px; background:var(--ui-accent);
    color:var(--ui-accent-text); border:none; border-radius:8px; padding:11px 22px;
    font:600 15px system-ui,sans-serif; cursor:pointer; text-decoration:none; }
  @media (hover:hover) { #welcome .cta:hover { background:var(--ui-accent-hover); } }
  #welcome .sub { margin-top:12px; font-size:12.5px; color:var(--ui-text-faint); line-height:1.5; }
  #root.droptarget #welcome .card { outline:2px dashed var(--ui-accent); outline-offset:6px; }

  /* Settings popover: pops UP from the bottom-right cluster with a caret
     pointing down at the settings button. */
  #drawer { --caret:9px; position:absolute; right:calc(12px + env(safe-area-inset-right,0px));
    bottom:calc(env(safe-area-inset-bottom,0px) + 66px);
    width:min(420px, calc(100vw - 24px)); max-height:calc(100dvh - 120px); z-index:9;
    background:var(--ui-bg); color:var(--ui-text); border:1px solid var(--ui-border); border-radius:14px;
    box-shadow:0 12px 38px rgba(0,0,0,.30); display:flex; flex-direction:column;
    transform-origin:bottom right; transform:translateY(6px) scale(.97); opacity:0; visibility:hidden;
    transition:opacity .15s ease, transform .15s ease, visibility 0s linear .15s; }
  #drawer.open { opacity:1; transform:none; visibility:visible; transition:opacity .15s ease, transform .15s ease; }
  #drawer::after { content:""; position:absolute; bottom:calc(-1 * var(--caret)); left:var(--caret-left,85%);
    transform:translateX(-50%); width:0; height:0;
    border-left:var(--caret) solid transparent; border-right:var(--caret) solid transparent;
    border-top:var(--caret) solid var(--ui-bg); filter:drop-shadow(0 2px 1px rgba(0,0,0,.08)); }
  .dhead { display:flex; align-items:center; gap:8px; padding:10px 14px; border-bottom:1px solid var(--ui-border); }
  .dhead strong { flex:1; font-size:14px; }
  .dhead .close { cursor:pointer; border:1px solid var(--ui-border-strong); background:var(--ui-surface);
    border-radius:6px; padding:5px 10px; font:inherit; color:var(--ui-text); }
  #drawer .body { overflow-y:auto; overscroll-behavior:contain; -webkit-overflow-scrolling:touch;
    padding:0 16px 16px; flex:1; border-radius:0 0 13px 13px; }

  /* Settings rows + controls (from settings-dialog.view.mjs). */
  .set-group { position:sticky; top:0; z-index:2; margin:0 -16px; padding:12px 16px 6px;
    font-size:11px; font-weight:700; letter-spacing:.06em; text-transform:uppercase;
    color:var(--ui-text-dim); background:var(--ui-bg); border-bottom:1px solid var(--ui-border-2); }
  .set-row { display:flex; flex-direction:column; padding:11px 0; border-bottom:1px solid var(--ui-border-2); }
  .set-row:last-child { border-bottom:none; }
  .set-row .set-head { display:flex; align-items:center; gap:16px; }
  .set-row .t { font-weight:600; font-size:13.5px; flex:1 1 auto; min-width:0; }
  .set-row .d { font-size:12px; color:var(--ui-text-faint); margin-top:4px; line-height:1.5; max-width:56ch; }
  .set-row .ctl { flex:none; margin-left:auto; display:flex; align-items:center; gap:6px; }
  .set-row .ctl input[type=number] { width:64px; text-align:right; border:1px solid var(--ui-border-strong);
    border-radius:7px; padding:6px 8px; font:inherit; font-size:14px; background:var(--ui-surface); color:var(--ui-text); }
  .set-row .ctl input[type=date] { border:1px solid var(--ui-border-strong); border-radius:7px;
    padding:5px 8px; font:inherit; font-size:13px; background:var(--ui-surface); color:var(--ui-text); }
  .set-row .ctl .unit { color:var(--ui-text-faint); font-size:12px; min-width:14px; }
  .switch { position:relative; width:38px; height:22px; display:inline-block; flex:none; }
  .switch input { opacity:0; width:0; height:0; }
  .switch .sl { position:absolute; inset:0; background:var(--ui-border-strong); border-radius:22px;
    cursor:pointer; transition:.15s; }
  .switch .sl:before { content:""; position:absolute; width:16px; height:16px; left:3px; top:3px;
    background:#fff; border-radius:50%; transition:.15s; box-shadow:0 1px 2px rgba(0,0,0,.3); }
  .switch input:checked + .sl { background:var(--ui-accent); }
  .switch input:checked + .sl:before { transform:translateX(16px); }
  .seg { display:inline-flex; border:1px solid var(--ui-border-strong); border-radius:8px; overflow:hidden; }
  .seg button { border:none; background:var(--ui-surface); padding:6px 12px; font:inherit; font-size:13px;
    cursor:pointer; border-left:1px solid var(--ui-border-2); color:var(--ui-text); }
  .seg button:first-child { border-left:none; }
  .seg button.sel { background:var(--ui-accent); color:var(--ui-accent-text); }

  /* Splash: painted before the engine downloads; faded out when it is up. */
  #splash { position:absolute; inset:0; z-index:9999; display:flex; flex-direction:column;
    align-items:center; justify-content:center; gap:14px;
    background:var(--ui-bg); color:var(--ui-text); font:15px/1.4 system-ui,sans-serif;
    transition:opacity .4s ease; }
  #splash.hide { opacity:0; pointer-events:none; }
  #splash .spinner { width:40px; height:40px; border-radius:50%;
    border:4px solid var(--ui-border-strong); border-top-color:var(--ui-accent);
    animation:spin .9s linear infinite; }
  #splash .note { color:var(--ui-text-dim); font-size:13px; }
  @keyframes spin { to { transform:rotate(360deg); } }
  @media (prefers-reduced-motion: reduce) { #splash .spinner { animation:none; } }
`;

const COMPASS_ICON = `<svg id="needle" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9.2"/><path d="M12 5.6 14.2 12l-2.2 6.4L9.8 12Z" fill="currentColor" stroke="none"/></svg>`;
const SETTINGS_ICON = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3.2"/><path d="M19.4 15a1.7 1.7 0 0 0 .34 1.87l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.7 1.7 0 0 0-1.87-.34 1.7 1.7 0 0 0-1.03 1.56V21a2 2 0 1 1-4 0v-.09A1.7 1.7 0 0 0 8.98 19.4a1.7 1.7 0 0 0-1.87.34l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.7 1.7 0 0 0 .34-1.87 1.7 1.7 0 0 0-1.56-1.03H3a2 2 0 1 1 0-4h.09A1.7 1.7 0 0 0 4.6 8.98a1.7 1.7 0 0 0-.34-1.87l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.7 1.7 0 0 0 1.87.34H9a1.7 1.7 0 0 0 1.03-1.56V3a2 2 0 1 1 4 0v.09c0 .68.4 1.3 1.03 1.56a1.7 1.7 0 0 0 1.87-.34l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.7 1.7 0 0 0-.34 1.87V9c.26.63.88 1.03 1.56 1.03H21a2 2 0 1 1 0 4h-.09a1.7 1.7 0 0 0-1.56 1.03Z"/></svg>`;
const SCHEME_ICON = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3a9 9 0 1 0 9 9c0-.46-.04-.92-.1-1.36a5.4 5.4 0 0 1-7.54-7.54A9.1 9.1 0 0 0 12 3Z"/></svg>`;
const TRASH_ICON = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h18M8 6V4a1 1 0 0 1 1-1h6a1 1 0 0 1 1 1v2m3 0v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6M10 11v6M14 11v6"/></svg>`;
const EXPAND_ICON = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M8 3H5a2 2 0 0 0-2 2v3m18 0V5a2 2 0 0 0-2-2h-3m0 18h3a2 2 0 0 0 2-2v-3M3 16v3a2 2 0 0 0 2 2h3"/></svg>`;
const ANCHOR_ICON = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="5" r="2"/><path d="M12 7v14M5 12a7 7 0 0 0 14 0M3 12h2m14 0h2M12 21a7 7 0 0 1-5-2m10 0a7 7 0 0 1-5 2"/></svg>`;

export const NOAA_ENC_URL = "https://charts.noaa.gov/ENCs/ENCs.shtml";

export const CHROME = `
  <canvas id="map"></canvas>
  <img id="mapimg" alt="chart view" draggable="false">

  <div id="tr-controls">
    <button class="rbtn" id="north" type="button" title="North up" aria-label="North up">${COMPASS_ICON}</button>
  </div>
  <div id="mr-controls">
    <button class="rbtn" id="zi" type="button" title="Zoom in" aria-label="Zoom in">+</button>
    <button class="rbtn" id="zo" type="button" title="Zoom out" aria-label="Zoom out">&minus;</button>
    <button class="rbtn" id="fs" type="button" title="Full screen" aria-label="Full screen">${EXPAND_ICON}</button>
  </div>
  <div id="br-controls">
    <button class="rbtn" id="scheme" type="button" title="Colour scheme - tap to cycle Day · Dusk · Night" aria-label="Colour scheme">${SCHEME_ICON}</button>
    <button class="rbtn" id="settings" type="button" title="Settings" aria-label="Settings">${SETTINGS_ICON}</button>
    <button class="rbtn" id="lib" type="button" title="Clear the chart library" aria-label="Clear the chart library">${TRASH_ICON}</button>
  </div>

  <div id="databox">
    <div id="db-prog" class="db-prog" hidden>
      <div id="db-prog-title" class="db-prog-title"></div>
      <div class="db-prog-status">
        <span id="db-prog-action" class="db-prog-action"></span>
        <span id="db-prog-count" class="db-prog-count"></span>
      </div>
      <div class="db-prog-track"><span id="db-prog-fill" class="db-prog-fill"></span></div>
    </div>
    <div class="db-readout">
      <span id="hud-scale" class="hud-scale"></span><span class="hud-sep">·</span>
      <span id="hud-z" class="hud-z"></span><span class="hud-sep">·</span>
      <span id="hud-coord" class="hud-coord"></span><span id="hud-hdg" class="hud-hdg"></span>
    </div>
    <div id="db-sub" class="db-sub"></div>
  </div>

  <div id="toasts"></div>

  <div id="attr">
    <a href="${NOAA_ENC_URL}" target="_blank" rel="noopener">NOAA ENC®</a>
    · not for navigation · <span id="attr-engine"></span>
  </div>

  <div id="welcome" hidden><div class="card">
    ${ANCHOR_ICON}
    <h2>Welcome aboard</h2>
    <p>Drop official NOAA charts anywhere on this page - an exchange-set
    <b>.zip</b>, or <b>.000</b> cells with their update files. They are baked
    and rendered right here in your browser; nothing is uploaded.</p>
    <a class="cta" href="${NOAA_ENC_URL}" target="_blank" rel="noopener">⚓ Get free NOAA charts</a>
    <div class="sub">Charts you drop are stored in this browser and load
    instantly next time.</div>
  </div></div>

  <div id="drawer">
    <div class="dhead"><strong>Chart display</strong><button class="close" id="drawer-close" type="button">✕</button></div>
    <div class="body" id="settings-body"></div>
  </div>

  <div id="splash">
    <div class="spinner"></div>
    <div id="splash-label">Loading the chart engine…</div>
    <div class="note">a few MB on first visit</div>
  </div>
`;
