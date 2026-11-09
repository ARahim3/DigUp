// store.js — the shared application state (server/ui/AGENTS.md §State): ONE store,
// one writer per slice, selectors for readers. No state library, no context plumbing:
// the store is created in main.js, handed to digup-app (and to the embed widget), and
// components subscribe through `storeController` — a Lit ReactiveController that
// requestUpdate()s on change. Component-local state (a text passage mid-read, a
// focus flag) stays in the component; sequencing tokens (generation, estimateToken,
// jobPoll) stay inside their controllers — they are sequencing, not app state.

export function createStore(initial = {}) {
  let state = { ...initial };
  const subs = new Set();
  return {
    get: () => state,
    /** Shallow patch — components re-render through selectors, so a patch is one
     *  notification. Never mutate `get()`'s object in place from outside a set(). */
    set(patch) {
      state = { ...state, ...patch };
      for (const fn of subs) fn(state);
    },
    subscribe(fn) {
      subs.add(fn);
      return () => subs.delete(fn);
    },
  };
}

/** Lit ReactiveController: re-render `host` when the store moves. `select` maps the
 *  store to the slice this component reads; the component reads it via `value()`.
 *  Selectors return ONE value (a reference) or a tuple as an ARRAY — arrays are
 *  compared element-wise, so `s => [s.keys, s.status]` re-renders only when a member
 *  reference actually changed (typing does not repaint the settings panel). */
export function storeController(host, store, select = (s) => s) {
  const same = (a, b) => a === b
    || (Array.isArray(a) && Array.isArray(b)
        && a.length === b.length && a.every((x, i) => x === b[i]));
  let value = select(store.get());
  const controller = {
    value: () => value,
  };
  const unsub = store.subscribe((state) => {
    const next = select(state);
    if (!same(next, value)) {              // selector identity: same slice → no re-render
      value = next;
      host.requestUpdate();
    }
  });
  host.addController({
    hostConnected() {},
    hostDisconnected() { unsub(); },
  });
  return controller;
}
