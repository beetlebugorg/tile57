// A minimal WASI preview1 shim for the browser (no dependencies; node also
// runs it). It covers what tile57-engine.wasm uses: an in-memory file tree
// preopened at one path (writable, so the engine's zip bake can write
// per-chart archives into it), the clock, randomness, and stdout/stderr to
// the console. Sockets and polling return ENOSYS.
//
// usage:
//   const fsys = new MemFS("/enc");
//   fsys.add("US5BDRAB/US5BDRAB.000", bytes);       // Uint8Array
//   const wasi = new WasiShim(fsys);
//   const inst = await WebAssembly.instantiate(mod, wasi.imports());
//   wasi.start(inst);                                // reactor _initialize

const E = {
  SUCCESS: 0, BADF: 8, EXIST: 20, INVAL: 28, IO: 29, ISDIR: 31,
  NOENT: 44, NOSYS: 52, NOTDIR: 54, NOTEMPTY: 55, NOTSUP: 58,
};
const FILETYPE = { DIR: 3, REGULAR: 4 };

/** A growable in-memory file. `data()` is the live content view. */
class FileNode {
  constructor(bytes) {
    this.buf = bytes ?? new Uint8Array(0);
    this.len = this.buf.length;
  }
  data() { return this.buf.subarray(0, this.len); }
  grow(need) {
    if (need <= this.buf.length) return;
    const next = new Uint8Array(Math.max(need, this.buf.length * 2, 4096));
    next.set(this.buf);
    this.buf = next;
  }
  write(pos, src) {
    this.grow(pos + src.length);
    this.buf.set(src, pos);
    this.len = Math.max(this.len, pos + src.length);
  }
  truncate(size) {
    this.grow(size);
    if (size > this.len) this.buf.fill(0, this.len, size);
    this.len = size;
  }
}

const parts = (rel) => rel.split("/").filter((p) => p && p !== ".");

/** An in-memory file tree, preopened at `root` (e.g. "/enc"). Directories are
 * Maps(name -> node); files are FileNodes. */
export class MemFS {
  constructor(root) {
    this.root = root;
    this.tree = new Map();
  }
  /** Add one file under the preopen root. `rel` uses "/" separators;
   * intermediate directories are created. */
  add(rel, bytes) {
    const p = parts(rel);
    let dir = this.tree;
    for (const part of p.slice(0, -1)) {
      if (!dir.has(part)) dir.set(part, new Map());
      dir = dir.get(part);
      if (!(dir instanceof Map)) throw new Error(`${part}: file where a directory is needed`);
    }
    dir.set(p[p.length - 1], new FileNode(bytes));
  }
  /** Remove the file or subtree at `rel`. A missing path is fine. */
  remove(rel) {
    const at = this.parent(rel);
    if (at) at[0].delete(at[1]);
  }
  /** Create directory `rel` and its parents. */
  mkdirs(rel) {
    let dir = this.tree;
    for (const part of parts(rel)) {
      if (!dir.has(part)) dir.set(part, new Map());
      dir = dir.get(part);
      if (!(dir instanceof Map)) throw new Error(`${part}: file where a directory is needed`);
    }
  }
  /** The node at `rel` ("" or "." -> the root dir), or null. */
  lookup(rel) {
    let node = this.tree;
    for (const part of parts(rel)) {
      if (!(node instanceof Map)) return null;
      node = node.get(part);
      if (node === undefined) return null;
    }
    return node;
  }
  /** File content at `rel`, or null. */
  read(rel) {
    const node = this.lookup(rel);
    return node instanceof FileNode ? node.data() : null;
  }
  /** [dirMap, name] for `rel`, or null when the parent path is missing. */
  parent(rel) {
    const p = parts(rel);
    if (p.length === 0) return null;
    const dir = this.lookup(p.slice(0, -1).join("/"));
    return dir instanceof Map ? [dir, p[p.length - 1]] : null;
  }
  /** Yield [path, FileNode] for every file under `rel` (default: all). */
  *files(rel = "") {
    const start = this.lookup(rel);
    if (!(start instanceof Map)) return;
    const stack = [[rel, start]];
    while (stack.length) {
      const [prefix, dir] = stack.pop();
      for (const [name, node] of dir) {
        const path = prefix ? `${prefix}/${name}` : name;
        if (node instanceof Map) stack.push([path, node]);
        else yield [path, node];
      }
    }
  }
}

export class WasiShim {
  constructor(fsys) {
    this.fsys = fsys;
    this.memory = null;
    // fd table: 0/1/2 stdio, 3 = the preopen dir, others opened nodes.
    this.fds = new Map([[3, { node: fsys.tree, path: "" }]]);
    this.nextFd = 4;
    this.lines = ["", ""]; // buffered stdout/stderr up to newline
  }

  start(instance) {
    this.memory = instance.exports.memory;
    instance.exports._initialize();
  }

  view() { return new DataView(this.memory.buffer); }
  bytes() { return new Uint8Array(this.memory.buffer); }
  str(ptr, len) { return new TextDecoder().decode(this.bytes().subarray(ptr, ptr + len)); }

  // The tree path a (dirfd, path string) pair names, or null on a bad dirfd.
  // Paths arrive relative to the dirfd OR absolute ("/enc/x" - Zig's std
  // resolves some opens that way); an absolute path resolves against the
  // preopen root, and one outside it stays unresolvable (NOENT at lookup).
  at(dirfd, ptr, len) {
    const dir = this.fds.get(dirfd);
    if (!dir || dir.node instanceof FileNode) return null;
    const p = this.str(ptr, len);
    if (p.startsWith("/")) {
      const root = this.fsys.root;
      if (p === root || p.startsWith(root + "/")) return p.slice(root.length).replace(/^\/+/, "");
      return p.replace(/^\/+/, "");
    }
    return (dir.path ? dir.path + "/" : "") + p;
  }

  filestat(buf, node) {
    const d = this.view();
    const file = node instanceof FileNode;
    d.setBigUint64(buf, 0n, true); // dev
    d.setBigUint64(buf + 8, 0n, true); // ino
    d.setUint8(buf + 16, file ? FILETYPE.REGULAR : FILETYPE.DIR);
    d.setBigUint64(buf + 24, 1n, true); // nlink
    d.setBigUint64(buf + 32, BigInt(file ? node.len : 0), true); // size
    d.setBigUint64(buf + 40, 0n, true); // atim
    d.setBigUint64(buf + 48, 0n, true); // mtim
    d.setBigUint64(buf + 56, 0n, true); // ctim
  }

  // Copy out of `node` at `pos` through an iovec list; returns bytes copied.
  readv(node, pos, iovs, iovsLen) {
    const d = this.view(), m = this.bytes(), data = node.data();
    let total = 0;
    for (let i = 0; i < iovsLen; i++) {
      const buf = d.getUint32(iovs + 8 * i, true);
      const len = d.getUint32(iovs + 8 * i + 4, true);
      const n = Math.min(len, data.length - pos);
      if (n <= 0) break;
      m.set(data.subarray(pos, pos + n), buf);
      pos += n; total += n;
    }
    return total;
  }

  // Write into `node` at `pos` from an iovec list; returns bytes written.
  writev(node, pos, iovs, iovsLen) {
    const d = this.view(), m = this.bytes();
    let total = 0;
    for (let i = 0; i < iovsLen; i++) {
      const buf = d.getUint32(iovs + 8 * i, true);
      const len = d.getUint32(iovs + 8 * i + 4, true);
      node.write(pos, m.subarray(buf, buf + len));
      pos += len; total += len;
    }
    return total;
  }

  imports() {
    const nosys = () => E.NOSYS;
    const shim = this;
    const file = (fd) => {
      const f = shim.fds.get(fd);
      return f && f.node instanceof FileNode ? f : null;
    };
    // wasm i32 arguments arrive SIGNED: past 2 GiB of linear memory every
    // pointer looks negative. Mask every numeric argument back to u32 before
    // an op touches memory (BigInt i64 arguments pass through untouched).
    const mask = (fn) => (...a) => fn(...a.map((x) => (typeof x === "number" ? x >>> 0 : x)));
    const masked = (ops) => Object.fromEntries(Object.entries(ops).map(([k, f]) => [k, mask(f)]));
    return {
      wasi_snapshot_preview1: masked({
        environ_sizes_get: (count, size) => {
          shim.view().setUint32(count, 0, true);
          shim.view().setUint32(size, 0, true);
          return E.SUCCESS;
        },
        environ_get: () => E.SUCCESS,
        clock_res_get: (_id, out) => {
          shim.view().setBigUint64(out, 1000n, true);
          return E.SUCCESS;
        },
        clock_time_get: (_id, _prec, out) => {
          shim.view().setBigUint64(out, BigInt(Date.now()) * 1000000n, true);
          return E.SUCCESS;
        },
        random_get: (buf, len) => {
          const m = shim.bytes();
          for (let off = 0; off < len; off += 65536)
            crypto.getRandomValues(m.subarray(buf + off, buf + Math.min(len, off + 65536)));
          return E.SUCCESS;
        },
        proc_exit: (code) => { throw new Error(`proc_exit(${code})`); },

        fd_write: (fd, iovs, iovsLen, nwritten) => {
          const d = shim.view();
          if (fd === 1 || fd === 2) {
            let total = 0, text = "";
            for (let i = 0; i < iovsLen; i++) {
              const buf = d.getUint32(iovs + 8 * i, true);
              const len = d.getUint32(iovs + 8 * i + 4, true);
              text += shim.str(buf, len);
              total += len;
            }
            const slot = fd - 1;
            shim.lines[slot] += text;
            for (let nl; (nl = shim.lines[slot].indexOf("\n")) !== -1; ) {
              (fd === 2 ? console.error : console.log)(shim.lines[slot].slice(0, nl));
              shim.lines[slot] = shim.lines[slot].slice(nl + 1);
            }
            d.setUint32(nwritten, total, true);
            return E.SUCCESS;
          }
          const f = file(fd);
          if (!f) return E.BADF;
          const n = shim.writev(f.node, f.pos, iovs, iovsLen);
          f.pos += n;
          d.setUint32(nwritten, n, true);
          return E.SUCCESS;
        },
        fd_pwrite: (fd, iovs, iovsLen, offset, nwritten) => {
          const f = file(fd);
          if (!f) return E.BADF;
          const n = shim.writev(f.node, Number(offset), iovs, iovsLen);
          shim.view().setUint32(nwritten, n, true);
          return E.SUCCESS;
        },

        fd_prestat_get: (fd, buf) => {
          if (fd !== 3) return E.BADF;
          const name = new TextEncoder().encode(shim.fsys.root);
          shim.view().setUint8(buf, 0); // preopen dir
          shim.view().setUint32(buf + 4, name.length, true);
          return E.SUCCESS;
        },
        fd_prestat_dir_name: (fd, path, len) => {
          if (fd !== 3) return E.BADF;
          const name = new TextEncoder().encode(shim.fsys.root);
          shim.bytes().set(name.subarray(0, len), path);
          return E.SUCCESS;
        },

        path_open: (dirfd, _dirflags, path, pathLen, oflags, _rb, _ri, _fdflags, outFd) => {
          const rel = shim.at(dirfd, path, pathLen);
          if (rel === null) return E.BADF;
          let node = shim.fsys.lookup(rel);
          if (node !== null && oflags & 0b100) return E.EXIST; // O_EXCL
          if (node === null) {
            if (!(oflags & 0b1)) return E.NOENT; // no O_CREAT
            const at = shim.fsys.parent(rel);
            if (!at) return E.NOENT;
            node = new FileNode();
            at[0].set(at[1], node);
          }
          if (oflags & 0b10 && node instanceof FileNode) return E.NOTDIR; // O_DIRECTORY
          if (oflags & 0b1000 && node instanceof FileNode) node.truncate(0); // O_TRUNC
          const fd = shim.nextFd++;
          shim.fds.set(fd, { node, path: rel, pos: 0 });
          shim.view().setUint32(outFd, fd, true);
          return E.SUCCESS;
        },
        fd_close: (fd) => (shim.fds.delete(fd) ? E.SUCCESS : E.BADF),

        fd_read: (fd, iovs, iovsLen, nread) => {
          const f = file(fd);
          if (!f) return E.BADF;
          const n = shim.readv(f.node, f.pos, iovs, iovsLen);
          f.pos += n;
          shim.view().setUint32(nread, n, true);
          return E.SUCCESS;
        },
        fd_pread: (fd, iovs, iovsLen, offset, nread) => {
          const f = file(fd);
          if (!f) return E.BADF;
          const n = shim.readv(f.node, Number(offset), iovs, iovsLen);
          shim.view().setUint32(nread, n, true);
          return E.SUCCESS;
        },
        fd_seek: (fd, offset, whence, out) => {
          const f = file(fd);
          if (!f) return E.BADF;
          const base = whence === 0 ? 0 : whence === 1 ? f.pos : f.node.len;
          const pos = base + Number(offset);
          if (pos < 0) return E.INVAL;
          f.pos = pos;
          shim.view().setBigUint64(out, BigInt(pos), true);
          return E.SUCCESS;
        },

        fd_filestat_get: (fd, buf) => {
          const f = shim.fds.get(fd);
          if (!f) return E.BADF;
          shim.filestat(buf, f.node);
          return E.SUCCESS;
        },
        fd_filestat_set_size: (fd, size) => {
          const f = file(fd);
          if (!f) return E.BADF;
          f.node.truncate(Number(size));
          return E.SUCCESS;
        },
        fd_fdstat_get: (fd, buf) => {
          const f = shim.fds.get(fd);
          const d = shim.view();
          if (fd <= 2) {
            d.setUint8(buf, 2); // character device
          } else if (f) {
            d.setUint8(buf, f.node instanceof FileNode ? FILETYPE.REGULAR : FILETYPE.DIR);
          } else return E.BADF;
          d.setUint16(buf + 2, 0, true);
          d.setBigUint64(buf + 8, 0xffffffffffffffffn, true); // all rights
          d.setBigUint64(buf + 16, 0xffffffffffffffffn, true);
          return E.SUCCESS;
        },
        path_filestat_get: (dirfd, _flags, path, pathLen, buf) => {
          const rel = shim.at(dirfd, path, pathLen);
          if (rel === null) return E.BADF;
          const node = shim.fsys.lookup(rel);
          if (node === null) return E.NOENT;
          shim.filestat(buf, node);
          return E.SUCCESS;
        },

        fd_readdir: (fd, buf, bufLen, cookie, used) => {
          const f = shim.fds.get(fd);
          if (!f) return E.BADF;
          if (f.node instanceof FileNode) return E.NOTDIR;
          const names = [...f.node.keys()];
          const d = shim.view(), m = shim.bytes();
          let off = 0;
          for (let i = Number(cookie); i < names.length; i++) {
            const name = new TextEncoder().encode(names[i]);
            const need = 24 + name.length;
            if (off + need > bufLen) { off = bufLen; break; } // truncated: host retries
            d.setBigUint64(buf + off, BigInt(i + 1), true); // d_next
            d.setBigUint64(buf + off + 8, 0n, true); // d_ino
            d.setUint32(buf + off + 16, name.length, true);
            d.setUint8(buf + off + 20, f.node.get(names[i]) instanceof FileNode ? FILETYPE.REGULAR : FILETYPE.DIR);
            m.set(name, buf + off + 24);
            off += need;
          }
          d.setUint32(used, off, true);
          return E.SUCCESS;
        },

        path_create_directory: (dirfd, path, pathLen) => {
          const rel = shim.at(dirfd, path, pathLen);
          if (rel === null) return E.BADF;
          if (shim.fsys.lookup(rel) !== null) return E.EXIST;
          const at = shim.fsys.parent(rel);
          if (!at) return E.NOENT;
          at[0].set(at[1], new Map());
          return E.SUCCESS;
        },
        path_rename: (dirfd, path, pathLen, newDirfd, newPath, newPathLen) => {
          const from = shim.at(dirfd, path, pathLen);
          const to = shim.at(newDirfd, newPath, newPathLen);
          if (from === null || to === null) return E.BADF;
          const src = shim.fsys.parent(from), dst = shim.fsys.parent(to);
          if (!src || !dst || !src[0].has(src[1])) return E.NOENT;
          dst[0].set(dst[1], src[0].get(src[1]));
          src[0].delete(src[1]);
          return E.SUCCESS;
        },
        path_unlink_file: (dirfd, path, pathLen) => {
          const rel = shim.at(dirfd, path, pathLen);
          if (rel === null) return E.BADF;
          const at = shim.fsys.parent(rel);
          if (!at || !at[0].has(at[1])) return E.NOENT;
          if (at[0].get(at[1]) instanceof Map) return E.ISDIR;
          at[0].delete(at[1]);
          return E.SUCCESS;
        },
        path_remove_directory: (dirfd, path, pathLen) => {
          const rel = shim.at(dirfd, path, pathLen);
          if (rel === null) return E.BADF;
          const at = shim.fsys.parent(rel);
          if (!at || !at[0].has(at[1])) return E.NOENT;
          const node = at[0].get(at[1]);
          if (!(node instanceof Map)) return E.NOTDIR;
          if (node.size !== 0) return E.NOTEMPTY;
          at[0].delete(at[1]);
          return E.SUCCESS;
        },

        // Timestamps are not kept; syncing memory is a no-op.
        fd_filestat_set_times: () => E.SUCCESS,
        path_filestat_set_times: () => E.SUCCESS,
        fd_sync: () => E.SUCCESS,
        fd_fdstat_set_flags: () => E.SUCCESS,
        fd_renumber: nosys,
        path_link: nosys,
        path_readlink: nosys,
        path_symlink: nosys,
        poll_oneoff: nosys,
      }),
    };
  }
}
