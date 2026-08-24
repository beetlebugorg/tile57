// The chart store: the CATALOG of every known chart ({name, info}, no open
// handles), the persistent library behind it (OPFS via chart-library.mjs, or
// page memory without OPFS), and the view-windowed RESIDENT set - only the
// charts the current view needs are open in the engine, and a whole district
// on disk stays a handful of charts in memory.

import { ChartLibrary } from "../chart-library.mjs";
import { cam, cssWorld, viewW, viewH, lonLatToWorld, worldToLonLat, scaleDenom } from "./camera.mjs";

export class ChartStore {
  /** `rpc` is the primary engine worker's RPC; `margin` the scene prefetch
   * factor (selection covers the same box the scene request does). */
  constructor(rpc, { margin = 1.6, maxOpen = 64 } = {}) {
    this.rpc = rpc;
    this.margin = margin;
    this.maxOpen = maxOpen;
    this.catalog = []; // {name, info}
    this.library = null;
    this.sessionStore = new Map(); // archives when OPFS is unavailable
    this.auxSession = new Map(); // aux files when OPFS is unavailable
    this.openMap = new Map(); // name -> engine chart handle (the resident set)
    this.lastUsed = new Map(); // name -> viewSeq, for eviction
    this.compose = 0;
    this.composeKey = null;
    this.viewSeq = 0;
    this.storedBytes = 0;
  }

  async openLibrary() {
    this.library = await ChartLibrary.open();
    if (this.library) this.storedBytes = await this.library.usage();
    return this.library != null;
  }

  /** Catalog the stored library (metadata sidecars only - no archive opens).
   * Archives saved before metadata rode along are indexed once through the
   * engine; `onProgress(done, total)` reports that backfill. */
  async loadSaved(onProgress) {
    if (!this.library) return [];
    const saved = await this.library.list();
    const legacy = saved.filter((c) => !c.info);
    let n = 0;
    for (const c of legacy) {
      onProgress?.(++n, legacy.length);
      const bytes = await this.library.get(c.name);
      if (!bytes) continue;
      try {
        const { handle, info } = await this.rpc("openChartBytes", { bytes }, [bytes.buffer]);
        await this.rpc("closeChart", { handle });
        c.info = info;
        await this.library.putInfo(c.name, info);
      } catch (e) {
        console.warn(`library index ${c.name}:`, e);
      }
    }
    for (const c of saved) if (c.info) this.catalog.push(c);
    return this.catalog;
  }

  has(name) {
    return this.catalog.some((c) => c.name === name);
  }

  /** Save + catalog a freshly baked chart. Consumes `archive`'s buffer. */
  async register(name, archive, info) {
    if (this.has(name)) return null;
    if (this.library) {
      await this.library.put(name, archive, info).catch((e) => console.warn(`library save ${name}:`, e));
    } else this.sessionStore.set(name, archive);
    this.storedBytes += archive.length;
    const entry = { name, info };
    this.catalog.push(entry);
    return entry;
  }

  async refreshUsage() {
    if (this.library) this.storedBytes = await this.library.usage();
  }

  async clear() {
    if (this.library) await this.library.clear();
    this.sessionStore.clear();
  }

  /** Store an aux file (TXTDSC text, PICREP pictures) for a chart. */
  async putAux(stem, name, bytes) {
    try {
      if (this.library) await this.library.putAux(stem, name, bytes);
      else this.auxSession.set(`${stem}/${name}`, bytes);
    } catch (e) {
      console.warn(`aux save ${stem}/${name}:`, e);
    }
  }
  /** An aux file's bytes, or null. */
  async getAux(stem, name) {
    if (this.library) return this.library.getAux(stem, name);
    return this.auxSession.get(`${stem}/${name}`) ?? null;
  }

  async archiveBytes(name) {
    if (this.library) return this.library.get(name);
    const b = this.sessionStore.get(name);
    return b ? b.slice() : null; // a copy: opening transfers the buffer away
  }

  // The box the scene request covers: the rotated viewport's bounding box,
  // inflated by the prefetch margin - a chart is resident before the scene
  // needs it.
  viewBounds() {
    const s = cssWorld();
    const [cx, cy] = lonLatToWorld(cam.lon, cam.lat);
    const c = Math.abs(Math.cos(cam.rot)), sn = Math.abs(Math.sin(cam.rot));
    const hw = ((viewW() * c + viewH() * sn) * this.margin) / 2 / s;
    const hh = ((viewW() * sn + viewH() * c) * this.margin) / 2 / s;
    const [west, north] = worldToLonLat(cx - hw, Math.max(0.0001, cy - hh));
    const [east, south] = worldToLonLat(cx + hw, Math.min(0.9999, cy + hh));
    return { west, south, east, north };
  }

  selectCharts() {
    const vb = this.viewBounds();
    const denom = scaleDenom(cam.zoom);
    const hits = this.catalog.filter(({ info }) => info?.hasBounds
      && info.west < vb.east && info.east > vb.west
      && info.south < vb.north && info.north > vb.south);
    // g > 0: the chart is more GENERAL than the view's scale. Suitable charts
    // first, most general leading - over the cap that order decides who
    // draws, and generals cover the view in the fewest cells (the engine's
    // partition gives detailed charts precedence on overlap). Slots left over
    // go to out-of-window charts nearest the view's scale: an area only a
    // detailed chart covers shows that chart overscaled, never a hole.
    const scored = hits.map((c) => ({ c, g: Math.log2((c.info.nativeScale || denom) / denom) }));
    const inWin = scored.filter((sc) => Math.abs(sc.g) <= 3.5).sort((a, b) => b.g - a.g);
    const outWin = scored.filter((sc) => Math.abs(sc.g) > 3.5).sort((a, b) => Math.abs(a.g) - Math.abs(b.g));
    return inWin.concat(outWin).slice(0, this.maxOpen).map((sc) => sc.c);
  }

  /** Make the view's charts resident and composed; evict beyond the cap.
   * Returns {compose, chart} - one nonzero when anything covers the view. */
  async ensureView() {
    const sel = this.selectCharts();
    this.viewSeq++;
    for (const c of sel) this.lastUsed.set(c.name, this.viewSeq);
    const key = sel.map((c) => c.name).sort().join(",");
    if (key !== this.composeKey) {
      if (this.compose) {
        await this.rpc("composeClose", { handle: this.compose });
        this.compose = 0;
      }
      for (const c of sel) {
        if (this.openMap.has(c.name)) continue;
        const bytes = await this.archiveBytes(c.name);
        if (!bytes) continue;
        const { handle } = await this.rpc("openChartBytes", { bytes }, [bytes.buffer]);
        this.openMap.set(c.name, handle);
      }
      const handles = sel.map((c) => this.openMap.get(c.name)).filter((h) => h !== undefined);
      this.compose = handles.length > 1 ? await this.rpc("composeOpen", { handles }) : 0;
      this.composeKey = key;
      if (this.openMap.size > this.maxOpen) {
        const inUse = new Set(sel.map((c) => c.name));
        const victims = [...this.openMap.keys()].filter((n) => !inUse.has(n))
          .sort((a, b) => (this.lastUsed.get(a) || 0) - (this.lastUsed.get(b) || 0));
        while (this.openMap.size > this.maxOpen && victims.length) {
          const n = victims.shift();
          this.rpc("closeChart", { handle: this.openMap.get(n) }).catch(() => {});
          this.openMap.delete(n);
        }
      }
    }
    const sole = sel.length === 1 ? (this.openMap.get(sel[0].name) ?? 0) : 0;
    return { compose: this.compose, chart: this.compose ? 0 : sole };
  }
}
