// A pool of engine workers for parallel cell bakes. One wasm instance is
// single-threaded, so parallel baking means N instances - each pool slot runs
// its own engine-worker.mjs with its own engine and file tree. A cell bake is
// pure (cell bytes in, archive bytes out), so the slots share nothing; chart
// handles, the compositor, and rendering stay on the page's PRIMARY engine
// worker.
//
// The pool is sized for a batch and closed after it: each engine instance
// holds tens of megabytes of linear memory that wasm never returns, so slots
// are cheap to respawn (~a few hundred ms) and expensive to keep.
//
// usage:
//   const pool = new BakePool(workerUrl, wasmUrl, 4);
//   const archive = await pool.bake("US5BDRAB", files); // {name, bytes}[]
//   pool.close();

import { makeRpc } from "./worker-rpc.mjs";

export class BakePool {
  constructor(workerUrl, wasmUrl, size) {
    this.slots = [];
    this.idle = [];
    this.waiters = [];
    for (let i = 0; i < size; i++) {
      const w = new Worker(workerUrl, { type: "module" });
      const rpc = makeRpc(w);
      // init in flight now; the first bake on the slot awaits it.
      const slot = { w, rpc, ready: rpc("init", { wasmUrl }) };
      this.slots.push(slot);
      this.idle.push(slot);
    }
  }

  acquire() {
    if (this.idle.length) return Promise.resolve(this.idle.pop());
    return new Promise((r) => this.waiters.push(r));
  }
  release(slot) {
    const waiter = this.waiters.shift();
    if (waiter) waiter(slot);
    else this.idle.push(slot);
  }

  /** Bake one cell on the next free slot: `files` are the cell's .000 plus
   * its update and text files ({name, bytes}; the bytes transfer out). Returns
   * the archive bytes, or null when the cell produced nothing. */
  async bake(stem, files) {
    const slot = await this.acquire();
    try {
      await slot.ready;
      for (const f of files)
        await slot.rpc("addFile", { path: `drops/${stem}/${f.name}`, bytes: f.bytes }, [f.bytes.buffer]);
      return await slot.rpc("bakeCell", { path: `/enc/drops/${stem}/${stem}.000` });
    } finally {
      // Free the cell's files before the next cell lands on this slot. The
      // worker runs its queue in order, so no await is needed here.
      slot.rpc("remove", { path: `drops/${stem}` }).catch(() => {});
      this.release(slot);
    }
  }

  close() {
    for (const s of this.slots) s.w.terminate();
    this.slots = [];
    this.idle = [];
  }
}
