// store.js — the ONE store's rules (AGENTS.md §State): shallow patch, one
// notification per patch, unsubscribing, and the storeController's slice equality
// (a tuple selector must NOT repaint on unrelated writes — typing does not touch
// the settings panel).
import { describe, expect, it, vi } from "vitest";
import { createStore, storeController } from "./store.js";

describe("createStore", () => {
  it("shallow-patches and notifies subscribers; unsub stops the taps", () => {
    const store = createStore({ a: 1, nested: { x: 1 } });
    const seen = [];
    const off = store.subscribe((s) => seen.push(s));
    store.set({ a: 2 });
    expect(store.get().a).toBe(2);
    expect(store.get().nested).toBe(seen[0].nested);   // untouched slice keeps identity
    off();
    store.set({ a: 3 });
    expect(seen.length).toBe(1);
  });

  it("a patch is ONE notification (components render through selectors)", () => {
    const store = createStore({});
    const fn = vi.fn();
    store.subscribe(fn);
    store.set({ a: 1, b: 2 });
    expect(fn).toHaveBeenCalledTimes(1);
  });
});

describe("storeController", () => {
  it("re-renders on reference change of a tuple selector — and only then", () => {
    const store = createStore({ keys: { admin: "a" }, typing: "", other: 1 });
    const host = { requestUpdate: vi.fn(), addController: vi.fn() };
    storeController(host, store, (s) => [s.keys, s.other]);
    expect(host.requestUpdate).not.toHaveBeenCalled();
    store.set({ typing: "hello" });                    // unrelated write
    expect(host.requestUpdate).not.toHaveBeenCalled();
    store.set({ other: 2 });                           // a member changed
    expect(host.requestUpdate).toHaveBeenCalledTimes(1);
    store.set({ keys: store.get().keys });             // same reference
    expect(host.requestUpdate).toHaveBeenCalledTimes(1);
  });
});
