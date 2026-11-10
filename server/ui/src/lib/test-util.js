// Unit-test helpers (shared, not a test file): a Response-shaped stub for fetch and
// an event capture for the bubbling `digup:*` CustomEvents.
export function mockReply(status, body) {
  return { status, ok: status >= 200 && status < 300, json: async () => body };
}

export function installFetch(routes) {
  const calls = [];
  globalThis.fetch = async (path, options = {}) => {
    calls.push({ path, options, headers: options.headers || {} });
    const route = routes[path] ?? routes[`${options.method || "GET"} ${path}`];
    if (typeof route === "function") return route(path, options);
    if (route === undefined) throw new Error(`unstubbed ${path}`);
    return route;
  };
  return calls;
}

/** Resolve when `type` fires on target (capture:true catches across shadow boundaries). */
export function onceEvent(target, type) {
  return new Promise((resolve) => target.addEventListener(type, resolve, { once: true, capture: true }));
}

export function memoryStorage(initial = {}) {
  const map = new Map(Object.entries(initial));
  return {
    getItem: (k) => (map.has(k) ? map.get(k) : null),
    setItem: (k, v) => map.set(k, String(v)),
    removeItem: (k) => map.delete(k),
  };
}
