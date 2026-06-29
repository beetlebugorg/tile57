// Smoke test / example for @beetlebug/tile57-style-engine.
//
// Loads the wasm style engine, generates styles for a few mariner-setting
// combinations, validates the output is a well-formed MapLibre style with the
// expected layers + mariner-driven patches, and prints a summary.
//
//   node examples/generate.mjs
//
// Exits non-zero if any assertion fails (usable as a CI smoke test).

import assert from 'node:assert/strict';
import { loadStyleEngine, DEFAULT_SETTINGS } from '../index.js';

const engine = await loadStyleEngine();

// Tiny helper: find a layer by id.
const layer = (style, id) => style.layers.find((l) => l.id === id);

function check(label, settings, fn) {
  const style = engine.generateStyle(settings);
  assert.equal(style.version, 8, `${label}: style version should be 8`);
  assert.ok(Array.isArray(style.layers) && style.layers.length > 0, `${label}: has layers`);
  // Every chart-source layer must carry the AND-ed mariner display filter.
  const chartLayers = style.layers.filter((l) => l.source === 'chart');
  assert.ok(chartLayers.length > 0, `${label}: has chart-source layers`);
  for (const l of chartLayers) {
    assert.ok(Array.isArray(l.filter), `${label}: layer ${l.id} has a filter`);
  }
  fn?.(style);
  console.log(
    `  ok  ${label.padEnd(28)} ${style.layers.length} layers, ${chartLayers.length} filtered`,
  );
  return style;
}

console.log('tile57-style-engine smoke test\n');

// 1. Defaults (day, meters).
const day = check('defaults (day/meters)', {}, (s) => {
  assert.equal(layer(s, 'background').paint['background-color'], '#c9edff', 'day water DEPDW');
  // contour labels in whole metres (no feet conversion factor present)
  const styleStr = JSON.stringify(s);
  assert.ok(!styleStr.includes('3.280839895'), 'meters: no feet factor');
});

// 2. Night + feet — the headline example from the task.
const night = check('night + feet', { scheme: 'night', depth_unit: 'feet' }, (s) => {
  const styleStr = JSON.stringify(s);
  assert.ok(styleStr.includes('#aab7bf'), 'night neutral text ink present');
  assert.ok(styleStr.includes('rgba(0,0,0,0.85)'), 'night dark halo present');
  assert.ok(styleStr.includes('3.280839895'), 'feet: M->ft factor present');
  // night water background differs from day
  assert.notEqual(
    layer(s, 'background').paint['background-color'],
    layer(day, 'background').paint['background-color'],
    'night background differs from day',
  );
});

// 3. Depth/safety contours flow into the SEABED01 fill expression.
check('contours 5/15/40', { shallow_contour: 5, safety_contour: 15, deep_contour: 40 }, (s) => {
  const fill = JSON.stringify(layer(s, 'fill-areas').paint['fill-color']);
  assert.ok(fill.includes('15') && fill.includes('40'), 'safety/deep contours in SEABED case');
});

// 4. Plain boundary style changes the boundary filter.
const plain = check('plain boundaries', { boundary_style: 'plain' });
const sym = check('symbolized boundaries', { boundary_style: 'symbolized' });
assert.notEqual(JSON.stringify(plain.layers), JSON.stringify(sym.layers), 'boundary style changes filters');

// 5. Determinism: same settings + same nowUnix => identical bytes.
const a = engine.generateStyle({ scheme: 'dusk' }, { nowUnix: 1700000000, asString: true });
const b = engine.generateStyle({ scheme: 'dusk' }, { nowUnix: 1700000000, asString: true });
assert.equal(a, b, 'deterministic for fixed nowUnix');

console.log('\nDEFAULT_SETTINGS scheme/depth_unit:', DEFAULT_SETTINGS.scheme, '/', DEFAULT_SETTINGS.depth_unit);
console.log('\nAll checks passed.');
