// Map gestures over one surface element: drag pan (Shift-drag rotates about
// the screen centre), wheel zoom at the cursor, double-click zoom, two-pointer
// pinch (zoom + twist + pan about the midpoint), a velocity flick on a fast
// pan release, and keyboard arrows / +/-.
//
// The camera work happens in camera.mjs; this module only turns events into
// camera changes and reports them:
//   onMove(mx, my)  every pointer move (the cursor readout)
//   onChange()      the camera moved (redraw the standing scene, live rebuild)
//   onSettle(ms)    a gesture ended or paused (schedule a scene rebuild)
//   onTap(mx, my)   a click/tap that never became a drag (the cursor pick)

import { cam, panBy, zoomAt, pinchAt, viewW, viewH } from "./camera.mjs";

export function wireGestures(surface, root, { enabled, onMove, onChange, onSettle, onTap }) {
  const pointers = new Map(); // pointerId -> {x, y}
  let drag = null, pinch = null, flick = 0;

  const stopFlick = () => {
    if (flick) cancelAnimationFrame(flick);
    flick = 0;
  };
  const startFlick = (vx, vy) => {
    let last = performance.now();
    const step = (now) => {
      const dt = Math.min(64, now - last);
      last = now;
      panBy(vx * dt, vy * dt);
      const f = Math.exp(-dt / 280);
      vx *= f; vy *= f;
      onChange();
      if (Math.hypot(vx, vy) > 0.02) flick = requestAnimationFrame(step);
      else { flick = 0; onSettle(0); }
    };
    stopFlick();
    flick = requestAnimationFrame(step);
  };

  const pinchState = () => {
    const [p1, p2] = [...pointers.values()];
    return {
      dist: Math.max(1, Math.hypot(p2.x - p1.x, p2.y - p1.y)),
      ang: Math.atan2(p2.y - p1.y, p2.x - p1.x),
      mx: (p1.x + p2.x) / 2, my: (p1.y + p2.y) / 2,
    };
  };

  surface.addEventListener("pointerdown", (e) => {
    if (!enabled()) return;
    stopFlick();
    surface.setPointerCapture(e.pointerId);
    pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (pointers.size === 2) {
      pinch = pinchState();
      drag = null;
    } else if (pointers.size === 1) {
      root.classList.add("dragging");
      drag = { x: e.clientX, y: e.clientY, sx: e.clientX, sy: e.clientY, moved: 0,
        mode: e.shiftKey ? "rotate" : "pan", vx: 0, vy: 0, t: performance.now(), t0: performance.now() };
    }
  });

  surface.addEventListener("pointermove", (e) => {
    onMove(e.clientX, e.clientY);
    if (pointers.has(e.pointerId)) pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (pinch && pointers.size === 2) {
      const now = pinchState();
      panBy(now.mx - pinch.mx, now.my - pinch.my);
      pinchAt(now.mx, now.my, Math.log2(now.dist / pinch.dist), now.ang - pinch.ang);
      pinch = now;
      onChange();
      onSettle(300);
      return;
    }
    if (!drag) return;
    const now = performance.now(), dt = Math.max(1, now - drag.t);
    if (drag.mode === "rotate") {
      const a0 = Math.atan2(drag.y - viewH() / 2, drag.x - viewW() / 2);
      const a1 = Math.atan2(e.clientY - viewH() / 2, e.clientX - viewW() / 2);
      cam.rot += a1 - a0;
    } else {
      const dx = e.clientX - drag.x, dy = e.clientY - drag.y;
      panBy(dx, dy);
      drag.vx = 0.8 * drag.vx + 0.2 * (dx / dt); // px/ms, smoothed for the flick
      drag.vy = 0.8 * drag.vy + 0.2 * (dy / dt);
    }
    drag.moved = Math.max(drag.moved, Math.hypot(e.clientX - drag.sx, e.clientY - drag.sy));
    drag.x = e.clientX; drag.y = e.clientY; drag.t = now;
    onChange();
  });

  const endPointer = (e) => {
    pointers.delete(e.pointerId);
    if (pointers.size < 2) pinch = null;
    if (pointers.size === 1) {
      // A pinch collapsed to one finger: continue as a pan from it.
      const [p] = pointers.values();
      drag = { x: p.x, y: p.y, mode: "pan", vx: 0, vy: 0, t: performance.now() };
      return;
    }
    if (!drag) { onSettle(200); return; }
    root.classList.remove("dragging");
    const { mode, vx, vy, moved, t0 } = drag;
    drag = null;
    // A press that never travelled is a TAP - the cursor pick.
    if (mode === "pan" && moved < 6 && performance.now() - t0 < 400) {
      onTap?.(e.clientX, e.clientY);
      return;
    }
    if (mode === "pan" && Math.hypot(vx, vy) > 0.15) startFlick(vx, vy);
    else onSettle(200);
  };
  surface.addEventListener("pointerup", endPointer);
  surface.addEventListener("pointercancel", endPointer);

  surface.addEventListener("wheel", (e) => {
    if (!enabled()) return;
    e.preventDefault();
    zoomAt(e.clientX, e.clientY, -e.deltaY * (e.deltaMode === 1 ? 0.05 : 0.0022));
    onChange();
    onSettle(300);
  }, { passive: false });

  surface.addEventListener("dblclick", (e) => {
    if (!enabled()) return;
    zoomAt(e.clientX, e.clientY, 1);
    onChange();
    onSettle(0);
  });

  addEventListener("keydown", (e) => {
    if (!enabled()) return;
    const pan = 120;
    const moves = {
      ArrowLeft: () => panBy(pan, 0), ArrowRight: () => panBy(-pan, 0),
      ArrowUp: () => panBy(0, pan), ArrowDown: () => panBy(0, -pan),
      "+": () => zoomAt(viewW() / 2, viewH() / 2, 1),
      "=": () => zoomAt(viewW() / 2, viewH() / 2, 1),
      "-": () => zoomAt(viewW() / 2, viewH() / 2, -1),
    };
    const move = moves[e.key];
    if (!move) return;
    e.preventDefault();
    move();
    onChange();
    onSettle(250);
  });

  return { stopFlick };
}
