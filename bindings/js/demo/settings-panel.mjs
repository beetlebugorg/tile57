// The settings panel: renders the mariner model's groups into the drawer and
// routes every control change back through one callback. Control markup and
// behaviour follow the chartplotter settings dialog (settings-dialog.view.mjs):
// toggle switch, segmented buttons, number + unit, date.

import { settingsGroups } from "./mariner.mjs";

const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/"/g, "&quot;");

const ymdToInput = (v) =>
  /^\d{8}$/.test(String(v || "")) ? `${v.slice(0, 4)}-${v.slice(4, 6)}-${v.slice(6, 8)}` : "";

function control(item, value) {
  const k = `data-key="${esc(item.key)}"`;
  const view = item.transform ? item.transform.toView(value) : value;
  switch (item.type) {
    case "toggle":
      return `<label class="switch"><input type="checkbox" ${k} data-type="toggle" ${view ? "checked" : ""}><span class="sl"></span></label>`;
    case "segmented":
      return `<div class="seg">${(item.options || []).map(([v, lbl]) =>
        `<button type="button" ${k} data-type="segmented" data-val="${esc(v)}" class="${view === v ? "sel" : ""}">${esc(lbl)}</button>`).join("")}</div>`;
    case "number":
      return `<input type="number" ${k} data-type="number" step="${esc(item.step || "any")}" value="${esc(view)}">${item.unit ? `<span class="unit">${esc(item.unit)}</span>` : ""}`;
    case "date":
      return `<input type="date" ${k} data-type="date" value="${esc(ymdToInput(view))}">`;
    default:
      return "";
  }
}

function row(item, value) {
  const desc = item.desc ? `<div class="d">${esc(item.desc)}</div>` : "";
  return `<div class="set-row"><div class="set-head"><span class="t">${esc(item.label)}</span>
    <div class="ctl">${control(item, value)}</div></div>${desc}</div>`;
}

/** Render the whole panel for the current settings `m` into `body`, and wire
 * every control to `onChange(key, value)`. Re-rendered wholesale after each
 * change (the groups are unit-aware, so rows can change with the value). */
export function renderSettings(body, m, onChange) {
  const items = new Map();
  body.innerHTML = settingsGroups(m).map((g) => {
    for (const it of g.items) items.set(it.key, it);
    return `<div class="set-group">${esc(g.group)}</div>` + g.items.map((it) => row(it, m[it.key])).join("");
  }).join("");

  body.querySelectorAll("[data-key]").forEach((el) => {
    const item = items.get(el.dataset.key);
    const commit = (view) => {
      const value = item.transform ? item.transform.fromView(view) : view;
      onChange(item.key, value);
    };
    if (el.dataset.type === "toggle") el.addEventListener("change", () => commit(el.checked));
    else if (el.dataset.type === "segmented") el.addEventListener("click", () => commit(el.dataset.val));
    else if (el.dataset.type === "number") el.addEventListener("change", () => {
      const n = parseFloat(el.value);
      if (Number.isFinite(n)) commit(n);
    });
    else if (el.dataset.type === "date") el.addEventListener("change", () =>
      onChange(item.key, el.value ? el.value.replaceAll("-", "") : ""));
  });
}
