// The pick model - a JS port of lookout-marine's src/pick.zig: what a cursor
// pick reports, and in what order. The engine returns the features under the
// cursor in DRAW order, which puts the land area before the light that was
// tapped, so:
//   1. A meta object stays only when it carries something to read.
//   2. A feature with no attributes never leads.
//   3. The most SPECIFIC object wins: point, then line, then area - and what
//      the object IS decides within that (aids first, dangers, water, ground).
// Hold every change against the Zig original.

const INFORMATIONAL = ["INFORM", "NINFOM", "TXTDSC", "NTXTDS", "PICREP", "fileReference"];

const LINES = new Set([
  "DEPCNT", "COALNE", "SLCONS", "NAVLNE", "RECTRC", "CBLSUB", "PIPSOL",
  "TSELNE", "RIVERS", "FERYRT", "DWRTCL", "LNDELV", "CANALS",
]);
const AREAS = new Set([
  "DEPARE", "DRGARE", "SBDARE", "LNDARE", "BUAARE", "SEAARE", "ACHARE",
  "RESARE", "FAIRWY", "CBLARE", "PIPARE", "MIPARE", "DWRTPT", "TSSLPT",
  "UNSARE", "LNDRGN", "VEGATN", "HRBFAC", "BERTHS", "ADMARE", "CTNARE",
  "OSPARE", "SPLARE", "MARCUL", "DMPGRD",
]);
// What you steer by, then what can hurt you, then the water, then the ground.
const KINDS = [
  ["LIGHTS", "LITVES", "LITFLT"],
  ["BOYLAT", "BOYCAR", "BOYSAW", "BOYISD", "BOYSPP", "BOYINB", "BCNLAT", "BCNCAR", "BCNSAW", "BCNISD", "BCNSPP", "DAYMAR", "TOPMAR"],
  ["WRECKS", "OBSTRN", "UWTROC", "ROCKS", "MORFAC", "PILPNT"],
  ["SOUNDG", "DEPCNT", "DEPARE", "DRGARE", "SBDARE"],
  ["ACHARE", "RESARE", "TSSLPT", "TSELNE", "FAIRWY", "NAVLNE", "RECTRC", "CBLARE", "PIPARE", "CBLSUB", "PIPSOL", "DWRTPT", "MIPARE"],
  ["COALNE", "SLCONS", "PONTON", "HRBFAC", "BERTHS", "LNDMRK", "BUISGL"],
  ["LNDARE", "BUAARE", "SEAARE", "LNDRGN", "VEGATN"],
].map((g) => new Set(g));

const attrsOf = (f) => (typeof f.s57 === "object" && f.s57 !== null ? f.s57 : {});

function carriesInformation(f) {
  const a = attrsOf(f);
  return INFORMATIONAL.some((k) => a[k] !== undefined && a[k] !== "");
}
const isEmpty = (f) => Object.keys(attrsOf(f)).length === 0;
const isMeta = (f) => f.cls.startsWith("M_") || f.cls.startsWith("C_");

/** True when the pick should report the feature at all. */
export function keep(f) {
  // A sounding's depth is the figure on the chart; the rest is provenance.
  if (f.cls === "SOUNDG") return carriesInformation(f);
  if (!isMeta(f)) return true;
  return carriesInformation(f);
}

/** True when two picked features read as the same object - one feature draws
 * several times (fill, boundary, symbol) and every drawing answers. */
export function same(a, b) {
  return a.cls === b.cls && a.chart === b.chart
    && JSON.stringify(a.s57) === JSON.stringify(b.s57);
}

function primitive(cls) {
  if (LINES.has(cls)) return 1;
  if (AREAS.has(cls) || cls.endsWith("ARE")) return 2;
  return 0;
}
function kind(cls) {
  for (let i = 0; i < KINDS.length; i++) if (KINDS[i].has(cls)) return i;
  return 8;
}
function rank(f) {
  if (isEmpty(f)) return 10000; // nothing to read: never the answer
  if (isMeta(f)) return 900; // a note, but not what was aimed at
  return primitive(f.cls) * 100 + kind(f.cls);
}

/** Filter, dedup, and order a raw pick for presentation. */
export function rankPick(features) {
  const seen = [];
  const kept = [];
  for (const f of features) {
    if (!keep(f)) continue;
    if (seen.some((s) => same(s, f))) continue;
    seen.push(f);
    kept.push(f);
  }
  return kept
    .map((f, i) => ({ f, i, r: rank(f) }))
    .sort((a, b) => a.r - b.r || a.i - b.i) // stable between equals
    .map((x) => x.f);
}
