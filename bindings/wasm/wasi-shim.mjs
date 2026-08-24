// A minimal WASI preview1 shim for the browser (no dependencies; node also
// runs it). It covers exactly what tile57-engine.wasm imports: a read-only
// in-memory file tree preopened at one path, the clock, randomness, and
// stdout/stderr to the console. Everything else returns ENOSYS.
//
// usage:
//   const fsys = new MemFS("/enc");
//   fsys.add("US5BDRAB/US5BDRAB.000", bytes);       // Uint8Array
//   const wasi = new WasiShim(fsys);
//   const inst = await WebAssembly.instantiate(mod, wasi.imports());
//   wasi.start(inst);                                // reactor _initialize

const E = {
  SUCCESS: 0, BADF: 8, INVAL: 28, IO: 29, ISDIR: 31,
  NOENT: 44, NOSYS: 52, NOTDIR: 54, NOTSUP: 58, ROFS: 69,
};
const FILETYPE = { DIR: 3, REGULAR: 4 };

/** A read-only in-memory file tree, preopened at `root` (e.g. "/enc"). */
export class MemFS {
  constructor(root) {
    this.root = root;
    this.tree = new Map(); // dir node: Map(name -> node); file node: Uint8Array
  }
  /** Add one file under the preopen root. `rel` uses "/" separators. */
  add(rel, bytes) {
    const parts = rel.split("/").filter(Boolean);
    let dir = this.tree;
    for (const part of parts.slice(0, -1)) {
      if (!dir.has(part)) dir.set(part, new Map());
      dir = dir.get(part);
      if (!(dir instanceof Map)) throw new Error(`${part}: file where a directory is needed`);
    }
    dir.set(parts[parts.length - 1], bytes);
  }
  /** The node at `rel` ("" or "." -> the root dir), or null. */
  lookup(rel) {
    let node = this.tree;
    for (const part of rel.split("/").filter((p) => p && p !== ".")) {
      if (!(node instanceof Map)) return null;
      node = node.get(part);
      if (node === undefined) return null;
    }
    return node;
  }
}

export class WasiShim {
  constructor(fsys) {
    this.fsys = fsys;
    this.memory = null;
    // fd table: 0/1/2 stdio, 3 = the preopen dir, others opened files.
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

  filestat(buf, node) {
    const d = this.view();
    const file = node instanceof Uint8Array;
    d.setBigUint64(buf, 0n, true); // dev
    d.setBigUint64(buf + 8, 0n, true); // ino
    d.setUint8(buf + 16, file ? FILETYPE.REGULAR : FILETYPE.DIR);
    d.setBigUint64(buf + 24, 1n, true); // nlink
    d.setBigUint64(buf + 32, BigInt(file ? node.length : 0), true); // size
    d.setBigUint64(buf + 40, 0n, true); // atim
    d.setBigUint64(buf + 48, 0n, true); // mtim
    d.setBigUint64(buf + 56, 0n, true); // ctim
  }

  // Copy out of `node` at `pos` through an iovec list; returns bytes copied.
  readv(node, pos, iovs, iovsLen) {
    const d = this.view(), m = this.bytes();
    let total = 0;
    for (let i = 0; i < iovsLen; i++) {
      const buf = d.getUint32(iovs + 8 * i, true);
      const len = d.getUint32(iovs + 8 * i + 4, true);
      const n = Math.min(len, node.length - pos);
      if (n <= 0) break;
      m.set(node.subarray(pos, pos + n), buf);
      pos += n; total += n;
    }
    return total;
  }

  imports() {
    const nosys = () => E.NOSYS;
    const shim = this;
    const file = (fd) => {
      const f = shim.fds.get(fd);
      return f && f.node instanceof Uint8Array ? f : null;
    };
    return {
      wasi_snapshot_preview1: {
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
          if (fd !== 1 && fd !== 2) return E.BADF;
          const d = shim.view();
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
          const dir = shim.fds.get(dirfd);
          if (!dir || dir.node instanceof Uint8Array) return E.BADF;
          if (oflags & 0b1101) return E.ROFS; // creat / excl / trunc: read-only tree
          const rel = (dir.path ? dir.path + "/" : "") + shim.str(path, pathLen);
          const node = shim.fsys.lookup(rel);
          if (node === null) return E.NOENT;
          if (oflags & 0b10 && node instanceof Uint8Array) return E.NOTDIR; // O_DIRECTORY
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
          const base = whence === 0 ? 0 : whence === 1 ? f.pos : f.node.length;
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
        fd_fdstat_get: (fd, buf) => {
          const f = shim.fds.get(fd);
          const d = shim.view();
          if (fd <= 2) {
            d.setUint8(buf, 2); // character device
          } else if (f) {
            d.setUint8(buf, f.node instanceof Uint8Array ? FILETYPE.REGULAR : FILETYPE.DIR);
          } else return E.BADF;
          d.setUint16(buf + 2, 0, true);
          d.setBigUint64(buf + 8, ~0n & 0xffffffffffffffffn, true); // all rights
          d.setBigUint64(buf + 16, ~0n & 0xffffffffffffffffn, true);
          return E.SUCCESS;
        },
        path_filestat_get: (dirfd, _flags, path, pathLen, buf) => {
          const dir = shim.fds.get(dirfd);
          if (!dir || dir.node instanceof Uint8Array) return E.BADF;
          const node = shim.fsys.lookup((dir.path ? dir.path + "/" : "") + shim.str(path, pathLen));
          if (node === null) return E.NOENT;
          shim.filestat(buf, node);
          return E.SUCCESS;
        },

        fd_readdir: (fd, buf, bufLen, cookie, used) => {
          const f = shim.fds.get(fd);
          if (!f) return E.BADF;
          if (f.node instanceof Uint8Array) return E.NOTDIR;
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
            d.setUint8(buf + off + 20, f.node.get(names[i]) instanceof Uint8Array ? FILETYPE.REGULAR : FILETYPE.DIR);
            m.set(name, buf + off + 24);
            off += need;
          }
          d.setUint32(used, off, true);
          return E.SUCCESS;
        },

        // The engine never reaches these on the read-only browser path.
        fd_fdstat_set_flags: nosys,
        fd_filestat_set_size: nosys,
        fd_filestat_set_times: nosys,
        fd_pwrite: nosys,
        fd_renumber: nosys,
        fd_sync: () => E.SUCCESS,
        path_create_directory: nosys,
        path_filestat_set_times: nosys,
        path_link: nosys,
        path_readlink: nosys,
        path_remove_directory: nosys,
        path_rename: nosys,
        path_symlink: nosys,
        path_unlink_file: nosys,
        poll_oneoff: nosys,
      },
    };
  }
}
