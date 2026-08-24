// Promise RPC over a Worker running engine-worker.mjs: {id, op, args} out,
// {id, ok, result | error} back. One shared helper so the page's primary
// engine and the bake pool speak the same protocol.
export function makeRpc(worker) {
  const inflight = new Map();
  let nextId = 0;
  worker.onmessage = (e) => {
    const { id, ok, result, error } = e.data;
    const p = inflight.get(id);
    inflight.delete(id);
    if (ok) p.resolve(result);
    else p.reject(new Error(error));
  };
  return (op, args, transfer = []) =>
    new Promise((resolve, reject) => {
      const id = nextId++;
      inflight.set(id, { resolve, reject });
      worker.postMessage({ id, op, args }, transfer);
    });
}
