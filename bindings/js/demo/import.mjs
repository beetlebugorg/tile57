// Chart import: dropped .000 cells (with their update files) and exchange-set
// zips, baked in parallel across a pool of engine workers and registered in
// the chart store as each cell finishes.
//
// The zip stays in the PRIMARY engine (which lists and extracts it); each
// cell's extracted files shuttle to a pool slot for the bake, so extraction
// streams while bakes run wide. Extracted files and the zips free as soon as
// they are done with, so a big batch stays flat in memory.

import { BakePool } from "../bake-pool.mjs";

export class ChartImporter {
  /** `progress(done, total, label)` drives the data card's job row;
   * `onChart(entry)` fires as each chart lands in the store. */
  constructor(rpc, store, { workerUrl, wasmUrl, workers = 4 } = {}) {
    this.rpc = rpc;
    this.store = store;
    this.workerUrl = workerUrl;
    this.wasmUrl = wasmUrl;
    this.workers = workers;
    this.loading = false;
    this.dropSeq = 0;
  }

  /** Import dropped File objects. Returns {added, failed, skipped}. */
  async loadFiles(files, { progress, onChart } = {}) {
    if (this.loading) return { added: [], failed: ["still loading the previous drop"], skipped: 0 };
    this.loading = true;
    const added = [], failed = [];
    let skipped = 0;
    const zipPaths = [];
    try {
      // Classify the drop: zips, and .000 cells grouped with their updates.
      const groups = new Map();
      const zips = [];
      for (const f of files) {
        if (/\.zip$/i.test(f.name)) zips.push(f);
        else if (/\.\d{3}$/.test(f.name)) {
          const stem = f.name.replace(/\.\d{3}$/, "");
          if (!groups.has(stem)) groups.set(stem, []);
          groups.get(stem).push(f);
        }
      }

      const work = []; // {stem, run: async (pool|null) => {archive, info}|null}
      for (const [stem, cellFiles] of groups) {
        if (!cellFiles.some((f) => /\.000$/.test(f.name))) {
          failed.push(`${stem}: update files without the .000 base`);
          continue;
        }
        if (this.store.has(stem)) { skipped++; continue; }
        work.push({
          stem,
          run: async (pool) => {
            const bytes = await Promise.all(cellFiles.map(async (f) => ({
              name: f.name,
              bytes: new Uint8Array(await f.arrayBuffer()),
            })));
            if (pool) return pool.bake(stem, bytes);
            try {
              for (const f of bytes)
                await this.rpc("addFile", { path: `drops/${stem}/${f.name}`, bytes: f.bytes }, [f.bytes.buffer]);
              return await this.rpc("bakeCell", { path: `/enc/drops/${stem}/${stem}.000` });
            } finally {
              this.rpc("remove", { path: `drops/${stem}` }).catch(() => {});
            }
          },
        });
      }

      for (const zf of zips) {
        const id = `z${this.dropSeq++}`;
        const bytes = new Uint8Array(await zf.arrayBuffer());
        await this.rpc("addFile", { path: `zips/${id}.zip`, bytes }, [bytes.buffer]);
        zipPaths.push(`zips/${id}.zip`);
        progress?.(0, 0, `reading ${zf.name}…`);
        const entries = await this.rpc("zipList", { path: `/enc/zips/${id}.zip` });
        const byDir = new Map();
        for (const en of entries) {
          const dir = en.name.replace(/[^/]*$/, "");
          if (!byDir.has(dir)) byDir.set(dir, []);
          byDir.get(dir).push(en.name);
        }
        for (const en of entries) {
          if (!/\.000$/.test(en.name)) continue;
          const stem = en.name.replace(/^.*\//, "").replace(/\.000$/, "");
          if (this.store.has(stem)) { skipped++; continue; }
          const dir = en.name.replace(/[^/]*$/, "");
          // The cell and everything beside it (updates, referenced text).
          const names = byDir.get(dir).filter((n) => !n.endsWith("/"));
          const outPaths = names.map((n) => `/enc/drops/${id}/${stem}/${n.replace(/^.*\//, "")}`);
          work.push({
            stem,
            run: async (pool) => {
              try {
                await this.rpc("zipExtract", { path: `/enc/zips/${id}.zip`, names, outPaths });
                // The cell files (.000 + .NNN updates) go to the bake; the
                // rest (TXTDSC text, PICREP pictures) go to the library so
                // the pick report can show them later.
                const cellFiles = [];
                for (const p of outPaths) {
                  const name = p.replace(/^.*\//, "");
                  if (/\.\d{3}$/.test(name)) {
                    if (pool) cellFiles.push({ name, bytes: await this.rpc("readFile", { path: p }) });
                  } else {
                    await this.store.putAux(stem, name, await this.rpc("readFile", { path: p }));
                  }
                }
                if (!pool) return await this.rpc("bakeCell", { path: `/enc/drops/${id}/${stem}/${stem}.000` });
                return pool.bake(stem, cellFiles);
              } finally {
                this.rpc("remove", { path: `/enc/drops/${id}/${stem}` }).catch(() => {});
              }
            },
          });
        }
      }

      // Bake, `lanes` cells at a time. Registrations land as bakes finish.
      const lanes = Math.min(this.workers, work.length);
      const pool = lanes > 1 ? new BakePool(this.workerUrl, this.wasmUrl, lanes) : null;
      let done = 0, next = 0;
      progress?.(0, work.length);
      const lane = async () => {
        while (next < work.length) {
          const { stem, run } = work[next++];
          try {
            const res = await run(pool);
            if (!res) { failed.push(`${stem}: produced no archive`); continue; }
            const entry = await this.store.register(stem, res.archive, res.info);
            if (entry) { added.push(entry); onChart?.(entry); }
          } catch (e) {
            console.error(e);
            failed.push(`${stem}: ${e.message}`);
          } finally {
            done++;
            progress?.(done, work.length, stem);
          }
        }
      };
      try {
        await Promise.all(Array.from({ length: Math.max(1, lanes) }, lane));
      } finally {
        pool?.close();
      }
    } finally {
      // The batch is over: the zips (and anything left under drops/) free.
      for (const p of zipPaths) this.rpc("remove", { path: p }).catch(() => {});
      this.rpc("remove", { path: "drops" }).catch(() => {});
      await this.store.refreshUsage();
      this.loading = false;
    }
    return { added, failed, skipped };
  }
}
