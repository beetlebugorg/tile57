// A persistent chart library over OPFS (the browser's origin-private file
// system): baked PMTiles archives are written here as cells finish, and a
// page load opens the library instead of re-baking — baking is the expensive
// step, and it should happen once per chart, not once per session.
//
// Layout: one OPFS directory, `charts/`, holding `<CELL>.pmtiles` plus a
// `<CELL>.json` metadata sidecar (the tile57_info: bounds, scale, zooms) so
// a page load can catalog the library without opening a single archive.
// OPFS needs a secure context and main-thread `createWritable` support
// (current Firefox and Chrome; open() resolves null where any of that is
// missing, and the caller runs session-only).

export class ChartLibrary {
  static async open() {
    if (!navigator.storage?.getDirectory) return null;
    try {
      const root = await navigator.storage.getDirectory();
      return new ChartLibrary(root, await root.getDirectoryHandle("charts", { create: true }));
    } catch (e) {
      console.warn("chart library unavailable:", e);
      return null;
    }
  }
  constructor(root, dir) {
    this.root = root;
    this.dir = dir;
  }

  /** Bytes this origin stores (the library dominates it). One instant call —
   * per-file sizing crawls once a library holds thousands of charts. */
  async usage() {
    try {
      return (await navigator.storage.estimate())?.usage ?? 0;
    } catch {
      return 0;
    }
  }

  /** The catalog: [{name, info|null}], sorted by name. `info` is null only
   * for archives saved before metadata rode along. */
  async list() {
    const stems = [], metas = new Map();
    for await (const [name, handle] of this.dir.entries()) {
      if (handle.kind !== "file") continue;
      if (name.endsWith(".pmtiles")) stems.push(name.slice(0, -".pmtiles".length));
      else if (name.endsWith(".json")) {
        try {
          metas.set(name.slice(0, -".json".length), JSON.parse(await (await handle.getFile()).text()));
        } catch { /* a bad sidecar reads as missing */ }
      }
    }
    return stems.sort().map((name) => ({ name, info: metas.get(name) ?? null }));
  }

  /** One archive's bytes, or null when absent. */
  async get(stem) {
    try {
      const f = await (await this.dir.getFileHandle(`${stem}.pmtiles`)).getFile();
      return new Uint8Array(await f.arrayBuffer());
    } catch {
      return null;
    }
  }

  /** Write (or replace) one archive and its metadata sidecar. Reads `bytes`
   * without consuming it. */
  async put(stem, bytes, info) {
    const h = await this.dir.getFileHandle(`${stem}.pmtiles`, { create: true });
    const w = await h.createWritable();
    await w.write(bytes);
    await w.close();
    if (info) await this.putInfo(stem, info);
  }

  /** Write the metadata sidecar alone (backfilling a legacy save). */
  async putInfo(stem, info) {
    const h = await this.dir.getFileHandle(`${stem}.json`, { create: true });
    const w = await h.createWritable();
    await w.write(JSON.stringify(info));
    await w.close();
  }

  async remove(stem) {
    await this.dir.removeEntry(`${stem}.pmtiles`).catch(() => {});
    await this.dir.removeEntry(`${stem}.json`).catch(() => {});
  }

  /** Delete every archive — one recursive remove, not thousands of calls. */
  async clear() {
    await this.root.removeEntry("charts", { recursive: true });
    this.dir = await this.root.getDirectoryHandle("charts", { create: true });
  }
}
