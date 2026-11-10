// search-controller.js — the keyword-first loop, verbatim from the desktop panel
// (words at once with the last word as a prefix, meaning after the 120 ms pause,
// embed_ahead warming the vector) and its generation guards. These are the rules
// the vanilla app.js had; the migration keeps them byte-for-byte in behavior.
import { describe, expect, it, beforeEach, afterEach, vi } from "vitest";
import { createStore } from "./store.js";
import { createSearchController } from "./search-controller.js";
import { installFetch, mockReply } from "../lib/test-util.js";
import { WEAKER } from "../lib/format.js";

const hit = (id, kind, z) => ({ media_id: id, kind, path: `/f/${id}.${kind === "image" ? "jpg" : "mp4"}`, z });
const filters = { kinds: [], limit: 40, code: false };

const initial = () => ({ phase: "empty", strong: [], weaker: [], groups: [],
  hitsById: new Map(), showWeaker: false, selection: null, lastReply: null });

describe("queryChanged — the keyword-first pair + embed_ahead", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it("words NOW (prefix_last), the vector warmed, meaning after the pause", async () => {
    const store = createStore({ results: initial(), filters, isCode: false, text: "", navigated: false });
    const calls = installFetch({
      "POST /api/v1/search": mockReply(200, { hits: [hit("m1", "image", 3.1)], strong: 1, meaning: true, ms: {} }),
      "POST /api/v1/embed_ahead": mockReply(200, {}),
    });
    const api = async (path, options) => {
      const r = await globalThis.fetch(path, options);
      return r.json();
    };
    const c = createSearchController({ api, store });
    c.queryChanged("dog", filters);
    // The keyword call + the warm-up fire immediately; meaning waits for the pause.
    expect(calls.map((x) => x.path)).toEqual(["/api/v1/search", "/api/v1/embed_ahead"]);
    const body = JSON.parse(calls[0].options.body);
    expect(body).toMatchObject({ q: "dog", meaning: false, prefix_last: true, limit: 40 });
    expect(body.kinds).toBeNull();                       // all kinds = null (the engine's shape)
    await vi.advanceTimersByTimeAsync(120);
    await vi.waitFor(() => store.get().results.phase === "meaning");
    const meaningCall = calls[2];
    expect(JSON.parse(meaningCall.options.body)).toMatchObject({ q: "dog", meaning: true });
    expect(!("prefix_last" in JSON.parse(meaningCall.options.body))).toBe(true);
    expect(store.get().results.phase).toBe("meaning");
    expect(store.get().results.groups).toEqual([{ title: "Images", rows: [expect.objectContaining({ media_id: "m1" })] }]);
    expect(store.get().results.selection).toBe("m1");
  });

  it("empty text asks the engine nothing; code: prefix opens code mode", async () => {
    const store = createStore({ results: initial(), filters, isCode: false, text: "", navigated: false });
    const calls = installFetch({});
    const c = createSearchController({ api: async () => ({}), store });
    c.queryChanged("   ", filters);
    expect(calls.length).toBe(0);
    expect(store.get().results.phase).toBe("empty");
    c.queryChanged("code: rope", { ...filters, code: false });
    await Promise.resolve(); await Promise.resolve();
    expect(store.get().isCode).toBe(true);
    expect(store.get().text).toBe("rope");
    expect(store.get().results.phase).not.toBe("empty");   // searching: not the idle page
  });

  it("a late reply from an OLD keystroke never lands (generation guard)", async () => {
    const store = createStore({ results: initial(), filters, isCode: false, text: "", navigated: false });
    let resolveFirst;
    const first = new Promise((r) => { resolveFirst = r; });
    let n = 0;
    const api = async (path, options) => {
      n++;
      if (n === 1) return first;                                   // the "d" keyword reply, slow
      return { hits: [hit("m2", "image", 4)], strong: 1, meaning: true, ms: {} };
    };
    const c = createSearchController({ api, store });
    c.queryChanged("d", filters);
    c.queryChanged("do", filters);                                   // typing continues
    resolveFirst({ hits: [hit("m1", "image", 2)], strong: 1, meaning: false, ms: {} });
    await first; await Promise.resolve(); await Promise.resolve();
    expect(store.get().results.strong[0].media_id).toBe("m2");       // the late m1 was dropped
  });

  it("navigation walks the rows (strong, the weaker fold sentinel, the unfolded ones)", async () => {
    const store = createStore({ results: initial(), filters, isCode: false, text: "", navigated: false });
    const api = async () => ({ hits: [hit("a", "image", 3), hit("b", "image", 2.5), hit("c", "video", 2.2)],
                               strong: 2, meaning: true, ms: {} });
    const c = createSearchController({ api, store });
    c.queryChanged("x", filters);
    await vi.waitFor(() => store.get().results.phase === "meaning");
    expect(c.rowIDs()).toEqual(["a", "b", WEAKER]);
    c.move(1);
    expect(store.get().results.selection).toBe("b");
    c.move(1);
    expect(store.get().results.selection).toBe(WEAKER);
    c.toggleWeaker();
    expect(c.rowIDs()).toEqual(["a", "b", WEAKER, "c"]);
    c.toggleWeaker();                                              // folded: the sentinel leaves
    expect(c.rowIDs()).toEqual(["a", "b", WEAKER]);
  });
});

// (the tests wait on the store directly — vi.waitFor advances fake timers)

// A promise-shaped api for the plain tests (no fake-timer sequencing).
describe("search-controller — selection bookkeeping", () => {
  it("the first row is selected for a fresh reply; a navigated selection survives", async () => {
    const store = createStore({ results: initial(), filters, isCode: false, text: "", navigated: false });
    const c = createSearchController({ api: async () => ({
      hits: [hit("a", "image", 3), hit("b", "image", 2)], strong: 1, meaning: true, ms: {} }), store });
    c.queryChanged("x", filters);
    await vi.waitFor(() => store.get().results.selection);
    expect(store.get().results.selection).toBe("a");
    c.select("b");
    expect(store.get().results.selection).toBe("b");
    expect(store.get().navigated).toBe(true);
    expect(c.selectedHit().media_id).toBe("b");
  });
});
