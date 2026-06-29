// tile57 web demo: MapLibre GL JS over PMTiles baked by `tile57 bake`, styled by
// the @beetlebug/tile57-style-engine npm module (the tile57 chartstyle engine
// compiled to WebAssembly). The module turns S-52 "mariner settings" into a
// MapLibre style entirely in the browser; this app just wires the style's source /
// sprite / glyphs to the assets served alongside.
import { loadStyleEngine } from './engine/index.js';

const err = (msg) => { document.getElementById('err').textContent = String(msg); console.error(msg); };
// Surface any uncaught error/rejection on-page (and in the console) for debugging.
addEventListener('error', (e) => err('JS error: ' + (e.message || e.error)));
addEventListener('unhandledrejection', (e) => err('promise rejected: ' + (e.reason?.message || e.reason)));

// pmtiles:// protocol so a MapLibre vector source can read a .pmtiles archive.
const protocol = new pmtiles.Protocol();
maplibregl.addProtocol('pmtiles', protocol.tile);

// Assets served next to this page (see ./bake.sh + ./serve.sh). Defaults to MLT
// (MapLibre Tile); ?fmt=mvt uses the MVT bake; ?pmtiles=<path> overrides the archive.
const params = new URLSearchParams(location.search);
const isMlt = params.get('fmt') !== 'mvt';
const pmtilesPath = params.get('pmtiles') || (isMlt ? 'bundle/tiles/chart.pmtiles' : 'chart/tiles/chart.pmtiles');
const PMTILES = 'pmtiles://' + new URL(pmtilesPath, location.href).href;
const SPRITE = new URL('bundle/assets/sprite-mln', location.href).href;
const GLYPHS = 'glyphs/{fontstack}/{range}.pbf'; // vendored Noto Sans Regular (self-contained)

// Read the mariner settings off the control panel (omitted fields fall back to the
// engine's canonical defaults).
function readSettings() {
  const el = (id) => document.getElementById(id);
  return {
    scheme: el('scheme').value,
    depth_unit: el('depth_unit').value,
    boundary_style: el('boundary_style').value,
    four_shade_water: el('four_shade_water').checked,
    safety_contour: Number(el('safety_contour').value),
    shallow_contour: Number(el('shallow_contour').value),
    deep_contour: Number(el('deep_contour').value),
    text_names: el('text_names').checked,
  };
}

async function main() {
  const engine = await loadStyleEngine();

  // The style engine only substitutes the mariner-driven bits; the source lives in
  // the template, so we repoint it (and sprite/glyphs) at what we serve.
  const buildStyle = () => {
    const style = engine.generateStyle(readSettings());
    // The source lives in the template; repoint it at our PMTiles. encoding:"mlt"
    // tells MapLibre (>=5.12) to decode MapLibre Tile vector data instead of MVT.
    style.sources.chart = { type: 'vector', url: PMTILES, ...(isMlt ? { encoding: 'mlt' } : {}) };
    style.sprite = SPRITE;
    style.glyphs = GLYPHS;
    return style;
  };

  // Camera: a data-rich default (a globe-spanning catalogue's manifest anchor is
  // its bbox centre — meaningless, e.g. lon 0). minZoom comes from the manifest so
  // you can't zoom out past the data's lowest level into a blank map.
  let center = [-76.49, 38.97]; // Annapolis — present in the NOAA catalogue
  let zoom = 12;
  let minZoom = 8;
  try {
    const mf = await (await fetch('bundle/manifest.json')).json();
    if (Number.isFinite(mf?.data?.minzoom)) minZoom = mf.data.minzoom;
    const bb = mf?.data?.bbox;
    const a = mf?.data?.anchor;
    // Use the manifest anchor only for a regional bake (non-global coverage).
    if (Array.isArray(a) && Array.isArray(bb) && bb[2] - bb[0] < 180) center = a;
  } catch { /* keep defaults */ }

  const map = new maplibregl.Map({ container: 'map', style: buildStyle(), center, zoom, minZoom, hash: true });
  map.addControl(new maplibregl.NavigationControl());
  map.on('error', (e) => err(e.error?.message || e.error || 'map error'));

  // Regenerate + apply the style whenever a control changes — the whole point of
  // the demo: live, client-side restyle with no round-trip.
  for (const c of document.querySelectorAll('#panel select, #panel input'))
    c.addEventListener('change', () => map.setStyle(buildStyle()));
}

main().catch(err);
