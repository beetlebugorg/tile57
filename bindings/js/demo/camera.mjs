// The camera: centre, zoom, and view rotation, with the screen/world
// transforms every consumer shares. Geometry stays north-up in world space
// (web mercator, [0,1], y down); the camera turns, and every transform here
// honours that turn - the cursor readout, pan, anchored zoom and rotation,
// and the PNG placement all go through these.

import { lonLatToWorld, worldToLonLat, scaleDenom } from "../gpu-renderer.mjs";

export { lonLatToWorld, worldToLonLat, scaleDenom };

export const cam = { lon: -76.4875, lat: 38.975, zoom: 11, rot: 0 };

export const viewW = () => innerWidth;
export const viewH = () => innerHeight;
export const cssWorld = () => 256 * 2 ** cam.zoom; // CSS px per world unit
const rotCS = () => [Math.cos(cam.rot), Math.sin(cam.rot)];
const clampY = (y) => Math.min(0.9999, Math.max(0.0001, y));

export function screenToWorld(mx, my) {
  const S = cssWorld(), [c, sn] = rotCS();
  const dx = mx - viewW() / 2, dy = my - viewH() / 2;
  const [cx, cy] = lonLatToWorld(cam.lon, cam.lat);
  return [cx + (c * dx + sn * dy) / S, cy + (-sn * dx + c * dy) / S];
}
export function worldToScreen(wx, wy) {
  const S = cssWorld(), [c, sn] = rotCS();
  const [cx, cy] = lonLatToWorld(cam.lon, cam.lat);
  const rx = (wx - cx) * S, ry = (wy - cy) * S;
  return [viewW() / 2 + c * rx - sn * ry, viewH() / 2 + sn * rx + c * ry];
}
/** Re-centre so world point `p` lands at screen (mx, my). */
export function centerOn(p, mx, my) {
  const S = cssWorld(), [c, sn] = rotCS();
  const dx = mx - viewW() / 2, dy = my - viewH() / 2;
  [cam.lon, cam.lat] = worldToLonLat(p[0] - (c * dx + sn * dy) / S, clampY(p[1] - (-sn * dx + c * dy) / S));
}
export function panBy(dxCss, dyCss) {
  const S = cssWorld(), [c, sn] = rotCS();
  const [cx, cy] = lonLatToWorld(cam.lon, cam.lat);
  [cam.lon, cam.lat] = worldToLonLat(cx - (c * dxCss + sn * dyCss) / S, clampY(cy - (-sn * dxCss + c * dyCss) / S));
}
export function zoomAt(mx, my, dz) {
  const p = screenToWorld(mx, my);
  cam.zoom = Math.min(18, Math.max(2, cam.zoom + dz));
  centerOn(p, mx, my);
}
/** Zoom and rotate together, anchored at (mx, my) - the pinch gesture. */
export function pinchAt(mx, my, dz, dRot) {
  const p = screenToWorld(mx, my);
  cam.zoom = Math.min(18, Math.max(2, cam.zoom + dz));
  cam.rot += dRot;
  centerOn(p, mx, my);
}

/** Fit the camera to a chart list ({info} entries). One overview chart can
 * span an ocean and drag the union's centre off the detailed cluster, so
 * charts with a footprint over ~8x the median stay out of the fit. */
export function fitTo(list) {
  const bounded = list.filter((c) => c.info?.hasBounds);
  if (!bounded.length) return;
  const area = (c) => Math.max(0, c.info.east - c.info.west) * Math.max(0, c.info.north - c.info.south);
  const sorted = bounded.map(area).sort((a, b) => a - b);
  const median = sorted[Math.floor(sorted.length / 2)];
  let fit = bounded.filter((c) => area(c) <= median * 8);
  if (!fit.length) fit = bounded;
  let west = 180, south = 90, east = -180, north = -90;
  for (const c of fit) {
    west = Math.min(west, c.info.west); south = Math.min(south, c.info.south);
    east = Math.max(east, c.info.east); north = Math.max(north, c.info.north);
  }
  const [wx0, wy0] = lonLatToWorld(west, north), [wx1, wy1] = lonLatToWorld(east, south);
  const z = Math.log2(Math.min((viewW() * 0.9) / (256 * (wx1 - wx0)), (viewH() * 0.9) / (256 * (wy1 - wy0))));
  cam.zoom = Math.min(16, Math.max(3, z));
  [cam.lon, cam.lat] = worldToLonLat((wx0 + wx1) / 2, (wy0 + wy1) / 2);
}

// ---- persistence: the last view survives a reload -------------------------
const KEY = "tile57.view";
export function restoreView() {
  try {
    const v = JSON.parse(localStorage.getItem(KEY));
    if (!v || ![v.lat, v.lon, v.zoom].every(Number.isFinite)) return false;
    cam.lat = Math.max(-85, Math.min(85, v.lat));
    cam.lon = Math.max(-180, Math.min(180, v.lon));
    cam.zoom = Math.max(2, Math.min(18, v.zoom));
    cam.rot = Number.isFinite(v.rot) ? v.rot : 0;
    return true;
  } catch {
    return false;
  }
}
export function saveView() {
  try {
    localStorage.setItem(KEY, JSON.stringify({ lat: cam.lat, lon: cam.lon, zoom: cam.zoom, rot: cam.rot }));
  } catch { /* private mode; the view just does not persist */ }
}
