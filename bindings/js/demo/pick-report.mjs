// The cursor pick report, presented lookout-marine's way (PickReport.swift):
// two columns. The pick's objects stay in sight on the left as a column, the
// main data in each row, the object on show held selected; there is no pager
// to walk blind. The right column is the decoded report: the operative fact
// as the title, the attributes in chart language, the provenance as one
// muted line at the floor, and the raw S-57 rows one fold away. The chart's
// notes (M_* objects) pin at the list column's floor.
//
// The ENGINE composes each report (tile57_s57_report via the worker's pick
// op); this module only ranks the set (pick-model.mjs) and renders it.

import { rankPick } from "./pick-model.mjs";

const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/"/g, "&quot;");

const isNote = (f) => f.cls.startsWith("M_") || f.cls.startsWith("C_");

export class PickReport {
  constructor(root) {
    this.el = root.querySelector("#pick");
    this.features = [];
    this.sel = 0;
    this.fold = false;
    this.el.addEventListener("click", (e) => {
      const row = e.target.closest("[data-pick]");
      if (row) {
        this.sel = +row.dataset.pick;
        this.fold = false;
        this.render();
        return;
      }
      if (e.target.closest("#pick-close")) this.hide();
      else if (e.target.closest("#pick-copy")) this.copy();
      else if (e.target.closest("#pick-fold")) {
        this.fold = !this.fold;
        this.render();
      }
    });
  }

  /** Show a raw pick result (the worker's pick op output). */
  show(features) {
    this.features = rankPick(features);
    this.sel = 0;
    this.fold = false;
    if (!this.features.length) {
      this.hide();
      return false;
    }
    this.el.hidden = false;
    this.render();
    return true;
  }

  hide() {
    this.el.hidden = true;
    this.features = [];
  }
  get open() {
    return !this.el.hidden;
  }

  copy() {
    const f = this.features[this.sel];
    if (f) navigator.clipboard?.writeText(JSON.stringify({ cls: f.cls, chart: f.chart, s57: f.s57 }, null, 2)).catch(() => {});
  }

  listRow(f, i) {
    const r = f.report || {};
    const sel = i === this.sel ? " sel" : "";
    if (isNote(f)) {
      return `<button type="button" class="pl-row pl-note${sel}" data-pick="${i}">
        <span class="pl-glyph">🕮</span><span class="pl-title">${esc(r.chip || f.cls)}</span></button>`;
    }
    return `<button type="button" class="pl-row${sel}" data-pick="${i}">
      <span class="pl-title">${esc(r.title || f.cls)}</span>
      ${r.subtitle ? `<span class="pl-sub">${esc(r.subtitle)}</span>` : ""}</button>`;
  }

  // The raw S-57 rows, as the cell states them (one level flattened).
  rawRows(f) {
    const a = typeof f.s57 === "object" && f.s57 !== null ? f.s57 : {};
    return Object.entries(a).map(([k, v]) =>
      `<div class="pd-raw-row"><span class="pd-raw-k">${esc(k)}:</span><span class="pd-raw-v">${esc(
        typeof v === "object" ? JSON.stringify(v) : v)}</span></div>`).join("");
  }

  render() {
    const many = this.features.length > 1;
    this.el.classList.toggle("solo", !many);
    const main = this.features.map((f, i) => (isNote(f) ? "" : this.listRow(f, i))).join("");
    const notes = this.features.map((f, i) => (isNote(f) ? this.listRow(f, i) : "")).join("");
    this.el.querySelector("#pick-list").innerHTML = `
      <div class="pl-head">${this.features.length} OBJECT${this.features.length > 1 ? "S" : ""}</div>
      <div class="pl-rows">${main}</div>
      ${notes ? `<div class="pl-notes">${notes}</div>` : ""}`;

    const f = this.features[this.sel];
    const r = f.report || {};
    const rows = (r.rows || []).map((row) =>
      `<div class="pd-row" style="padding-left:${(row.depth || 0) * 12}px">
        <span class="pd-l">${esc(row.label)}</span>
        <span class="pd-v">${esc(row.value)}${row.file ? " 📄" : ""}${row.picture ? " 🖼" : ""}</span>
      </div>`).join("");
    const noteBlocks = (r.notes || []).map((n) => `<p class="pd-note">${esc(n)}</p>`).join("");
    const empty = r.empty
      ? `<div class="pd-empty">${r.empty === "none"
        ? "The cell carries no attributes for this object."
        : "The cell carries only source data for this object."}</div>`
      : "";
    const rawCount = typeof f.s57 === "object" && f.s57 !== null ? Object.keys(f.s57).length : 0;
    this.el.querySelector("#pick-detail").innerHTML = `
      <div class="pd-head">
        <div class="pd-head-main">
          <div class="pd-title">${esc(r.title || f.cls)}</div>
          ${r.subtitle ? `<div class="pd-sub">${esc(r.subtitle)}</div>` : ""}
        </div>
        <span class="pd-chip">${esc(r.chip || f.cls)}</span>
        <button type="button" id="pick-copy" title="Copy this report" aria-label="Copy this report">⧉</button>
        <button type="button" id="pick-close" aria-label="Close the pick report">✕</button>
      </div>
      <div class="pd-scroll">
        ${noteBlocks}${empty}${rows}
        ${this.fold ? `<div class="pd-raw">${this.rawRows(f)}</div>` : ""}
      </div>
      <div class="pd-floor">
        <div class="pd-foot">${esc(r.footnote || f.chart)}</div>
        <button type="button" id="pick-fold" class="pd-fold">
          <span class="pd-chev${this.fold ? " open" : ""}">›</span>
          S-57 source attributes (${rawCount})
        </button>
      </div>`;
  }
}

export const PICK_STYLE = `
  /* Pick report: lookout-marine's two-column card. The list keeps the whole
     pick in sight; the detail holds the object on show. */
  #pick { position:absolute; left:calc(12px + env(safe-area-inset-left,0px));
    top:calc(12px + env(safe-area-inset-top,0px)); z-index:8;
    display:flex; align-items:stretch;
    width:min(560px, calc(100vw - 24px));
    max-height:calc(100dvh - 120px);
    background:var(--ui-bg); color:var(--ui-text); border:1px solid var(--ui-border);
    border-radius:14px; box-shadow:0 12px 38px var(--ui-shadow); overflow:hidden; }
  #pick[hidden] { display:none; }
  #pick.solo { width:min(400px, calc(100vw - 24px)); }
  #pick.solo #pick-list { display:none; }

  #pick-list { flex:0 0 180px; min-width:0; display:flex; flex-direction:column;
    border-right:1px solid var(--ui-border-2); overflow-y:auto; overscroll-behavior:contain; }
  .pl-head { flex:none; font:600 10.5px/1 system-ui,sans-serif; letter-spacing:.08em;
    color:var(--ui-text-faint); padding:15px 14px 8px; }
  .pl-rows { flex:1 1 auto; }
  .pl-row { display:flex; flex-direction:column; align-items:flex-start; gap:2px; width:calc(100% - 12px);
    margin:1px 6px; padding:8px 9px; border:none; border-radius:7px; background:none;
    font:inherit; text-align:left; cursor:pointer; }
  @media (hover:hover) { .pl-row:hover { background:var(--ui-hover); } }
  .pl-row.sel { background:color-mix(in srgb, var(--ui-accent) 12%, transparent); }
  .pl-row .pl-title { font-weight:600; font-size:12.5px; color:var(--ui-text);
    max-width:100%; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .pl-row.sel .pl-title { color:var(--ui-accent); }
  .pl-row .pl-sub { font-size:11px; color:var(--ui-text-dim);
    max-width:100%; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  /* The chart's notes, pinned at the column's floor under a hairline. */
  .pl-notes { flex:none; border-top:1px solid var(--ui-border-2); padding:5px 0 6px; }
  .pl-note { flex-direction:row; align-items:center; gap:7px; }
  .pl-note .pl-glyph { flex:none; font-size:11px; color:var(--ui-text-dim); }
  .pl-note .pl-title { font-weight:500; color:var(--ui-text-dim); }
  .pl-note.sel .pl-glyph, .pl-note.sel .pl-title { color:var(--ui-accent); }

  #pick-detail { flex:1 1 auto; min-width:0; display:flex; flex-direction:column; }
  .pd-head { flex:none; display:flex; align-items:flex-start; gap:8px;
    padding:12px 12px 10px 16px; border-bottom:1px solid var(--ui-border-2); }
  .pd-head-main { flex:1 1 auto; min-width:0; }
  .pd-title { font:700 15px/1.3 system-ui,sans-serif; }
  .pd-sub { color:var(--ui-text-dim); font-size:12px; margin-top:1px; }
  .pd-chip { flex:none; margin-top:1px; font:600 10px/1.7 ui-monospace,SFMono-Regular,Menlo,monospace;
    color:var(--ui-text-dim); border:1px solid var(--ui-border-strong); border-radius:999px; padding:0 8px; }
  #pick-copy, #pick-close { flex:none; cursor:pointer; border:none; background:none;
    color:var(--ui-text-dim); font:600 13px system-ui,sans-serif; padding:3px 5px; border-radius:6px; }
  @media (hover:hover) { #pick-copy:hover, #pick-close:hover { background:var(--ui-hover); color:var(--ui-text); } }

  .pd-scroll { flex:1 1 auto; min-height:0; overflow-y:auto; overscroll-behavior:contain;
    padding:8px 16px 10px; }
  .pd-note { color:var(--ui-text); font-size:12.5px; line-height:1.5; margin:8px 0 2px;
    padding:8px 10px; background:var(--ui-surface-2); border-radius:8px; }
  .pd-empty { color:var(--ui-text-dim); font-size:12.5px; padding:12px 0; }
  .pd-row { display:flex; align-items:baseline; gap:12px; padding:6px 0; font-size:12.5px; }
  .pd-row .pd-l { flex:0 0 108px; color:var(--ui-text-dim); }
  .pd-row .pd-v { flex:1 1 auto; min-width:0; font-weight:600; font-variant-numeric:tabular-nums;
    overflow-wrap:anywhere; }
  .pd-raw { margin-top:8px; padding-top:6px; border-top:1px solid var(--ui-border-2); }
  .pd-raw-row { display:flex; align-items:baseline; gap:10px; padding:3px 0;
    font:11px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace; }
  .pd-raw-k { flex:0 0 92px; color:var(--ui-text-dim); overflow-wrap:anywhere; }
  .pd-raw-v { flex:1 1 auto; min-width:0; color:var(--ui-text); overflow-wrap:anywhere; }

  /* The floor: provenance as one muted line, then the fold's control. Both
     keep their place; what the fold opens scrolls above. */
  .pd-floor { flex:none; border-top:1px solid var(--ui-border-2); }
  .pd-foot { color:var(--ui-text-faint); font:11.5px/1.4 system-ui,sans-serif;
    font-variant-numeric:tabular-nums; padding:9px 16px 0; }
  .pd-fold { display:flex; align-items:center; gap:6px; width:100%; border:none; background:none;
    color:var(--ui-text-dim); font:12px system-ui,sans-serif; padding:8px 16px 11px;
    cursor:pointer; text-align:left; }
  @media (hover:hover) { .pd-fold:hover { color:var(--ui-text); } }
  .pd-chev { display:inline-block; font-weight:700; transition:transform .12s; }
  .pd-chev.open { transform:rotate(90deg); }

  @media (max-width:560px) {
    #pick { flex-direction:column; width:min(400px, calc(100vw - 24px)); }
    #pick-list { flex:0 0 auto; max-height:160px; border-right:none; border-bottom:1px solid var(--ui-border-2); }
  }
`;

export const PICK_CHROME = `
  <div id="pick" hidden>
    <div id="pick-list"></div>
    <div id="pick-detail"></div>
  </div>
`;
