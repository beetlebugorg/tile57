// The cursor pick report, presented lookout-marine's way (PickReport.swift):
// one object at a time, decoded for the mariner - the operative fact as the
// title, the attributes in chart language, the raw S-57 rows one fold away -
// with the whole pick set in sight as chips, never a blind pager.
//
// The ENGINE composes each report (tile57_s57_report via the worker's pick
// op); this module only ranks the set (pick-model.mjs) and renders it.

import { rankPick } from "./pick-model.mjs";

const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/"/g, "&quot;");

export class PickReport {
  constructor(root) {
    this.el = root.querySelector("#pick");
    this.features = [];
    this.sel = 0;
    this.el.querySelector("#pick-close").addEventListener("click", () => this.hide());
    this.el.addEventListener("click", (e) => {
      const chip = e.target.closest("[data-pick]");
      if (chip) {
        this.sel = +chip.dataset.pick;
        this.renderBody();
      }
    });
  }

  /** Show a raw pick result (the worker's pick op output). */
  show(features) {
    this.features = rankPick(features);
    this.sel = 0;
    if (!this.features.length) {
      this.hide();
      return false;
    }
    this.el.hidden = false;
    this.renderBody();
    return true;
  }

  hide() {
    this.el.hidden = true;
    this.features = [];
  }
  get open() {
    return !this.el.hidden;
  }

  renderBody() {
    const chips = this.features.map((f, i) =>
      `<button type="button" class="pick-chip ${i === this.sel ? "sel" : ""}" data-pick="${i}">${esc(f.report?.chip || f.cls)}</button>`).join("");
    const f = this.features[this.sel];
    const r = f.report || {};
    const rows = (r.rows || []).map((row) =>
      `<div class="pick-row" style="padding-left:${(row.depth || 0) * 14}px">
        <span class="pk-l">${esc(row.label)}</span><span class="pk-v">${esc(row.value)}${row.file ? " 📄" : ""}${row.picture ? " 🖼" : ""}</span>
      </div>`).join("");
    const notes = (r.notes || []).map((n) => `<p class="pick-note">${esc(n)}</p>`).join("");
    const empty = r.empty
      ? `<div class="pick-empty">${r.empty === "none" ? "The chart states nothing further about this object." : "Only source metadata is recorded."}</div>`
      : "";
    const raw = `<details class="pick-raw"><summary>As the cell states it</summary><pre>${esc(JSON.stringify(f.s57, null, 1))}</pre></details>`;
    this.el.querySelector("#pick-chips").innerHTML = chips;
    this.el.querySelector("#pick-body").innerHTML = `
      <div class="pick-title">${esc(r.title || f.cls)}</div>
      ${r.subtitle ? `<div class="pick-sub">${esc(r.subtitle)}</div>` : ""}
      ${notes}${rows}${empty}${raw}
      <div class="pick-foot">${esc(r.footnote || f.chart)}</div>`;
  }
}

export const PICK_STYLE = `
  /* Pick report: a callout card on the left, the pick set as chips on top,
     one decoded object below (lookout-marine's presentation). */
  #pick { position:absolute; left:calc(12px + env(safe-area-inset-left,0px));
    top:calc(12px + env(safe-area-inset-top,0px)); z-index:8;
    width:min(340px, calc(100vw - 24px));
    max-height:calc(100dvh - 120px); display:flex; flex-direction:column;
    background:var(--ui-bg); color:var(--ui-text); border:1px solid var(--ui-border);
    border-radius:14px; box-shadow:0 12px 38px rgba(0,0,0,.30); overflow:hidden; }
  #pick[hidden] { display:none; }
  #pick .phead { display:flex; align-items:center; gap:6px; padding:10px 12px 8px;
    border-bottom:1px solid var(--ui-border-2); }
  #pick-chips { flex:1; display:flex; flex-wrap:wrap; gap:5px; min-width:0; }
  .pick-chip { border:1px solid var(--ui-border-strong); background:var(--ui-surface);
    color:var(--ui-text-dim); border-radius:999px; padding:3px 10px;
    font:600 11px/1.6 ui-monospace,SFMono-Regular,Menlo,monospace; cursor:pointer; }
  .pick-chip.sel { background:var(--ui-accent); color:var(--ui-accent-text); border-color:var(--ui-accent); }
  #pick-close { flex:none; cursor:pointer; border:none; background:none; color:var(--ui-text-dim);
    font:600 14px system-ui,sans-serif; padding:4px 6px; }
  #pick-body { overflow-y:auto; overscroll-behavior:contain; padding:12px 14px 12px; }
  .pick-title { font:700 15px/1.3 system-ui,sans-serif; }
  .pick-sub { color:var(--ui-text-dim); font-size:12.5px; margin-top:2px; }
  .pick-note { color:var(--ui-text); font-size:12.5px; line-height:1.5; margin:10px 0 0;
    padding:8px 10px; background:var(--ui-surface-2); border-radius:8px; }
  .pick-row { display:flex; align-items:baseline; gap:12px; padding:6px 0;
    border-bottom:1px solid var(--ui-border-2); font-size:12.5px; }
  .pick-row:first-of-type { margin-top:8px; }
  .pick-row .pk-l { flex:1; min-width:0; color:var(--ui-text-dim); }
  .pick-row .pk-v { flex:none; max-width:60%; text-align:right; font-weight:600; overflow-wrap:anywhere; }
  .pick-empty { color:var(--ui-text-faint); font-size:12.5px; padding:12px 0 4px; }
  .pick-raw { margin-top:10px; }
  .pick-raw summary { cursor:pointer; color:var(--ui-text-dim); font-size:12px; padding:4px 0; }
  .pick-raw pre { margin:6px 0 0; padding:8px 10px; background:var(--ui-surface-2); border-radius:8px;
    font:11px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace; overflow-x:auto; color:var(--ui-text); }
  .pick-foot { margin-top:10px; padding-top:8px; border-top:1px solid var(--ui-border-2);
    color:var(--ui-text-faint); font-size:11px; }
`;

export const PICK_CHROME = `
  <div id="pick" hidden>
    <div class="phead"><div id="pick-chips"></div><button id="pick-close" type="button" aria-label="Close">✕</button></div>
    <div id="pick-body"></div>
  </div>
`;
