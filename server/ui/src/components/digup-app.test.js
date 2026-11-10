// digup-app — the shell: composition (store/api/controllers), the ONE layout switch
// (body[data-page] + host mirror, written at the FIRST paint), the gear's open/close
// with aria-expanded true to the panel, the Esc chain, the keyboard routes, and the
// pinned Space guard (buttons/links keep Space activation — the reviewer's finding).
import { describe, expect, it, beforeEach, afterEach, vi } from "vitest";
import "./digup-app.js";
import { createStore } from "../app/store.js";
import { createSearchController } from "../app/search-controller.js";
import { createKeysController } from "../app/keys-controller.js";
import { createJobController } from "../app/job-controller.js";
import { createEstimateController } from "../app/estimate-controller.js";
import { installFetch, mockReply, memoryStorage } from "../lib/test-util.js";

const hit = { media_id: "a", kind: "image", path: "/x/a.jpg", z: 3.2 };

async function mount() {
  const store = createStore({
    results: { phase: "empty", strong: [], weaker: [], groups: [], hitsById: new Map(),
               showWeaker: false, selection: null, lastReply: null },
    filters: { kinds: [], limit: 40 }, isCode: false, text: "", navigated: false,
    error: null, job: null, indexing: null, encoder: null, status: null, roots: [],
    targets: [], keys: null,
  });
  const calls = installFetch({
    "/api/v1/status": mockReply(200, { encoder: "gemma-2", vectors: 20, kinds: [],
                                        index_size: "1 MB", build_tag: "b1", roots: ["/m"] }),
    "/api/v1/tokens": mockReply(200, { admin: "adm1n", apps: [] }),
    "/api/v1/targets": mockReply(200, { targets: [] }),
  });
  const api = async (path, options = {}) => {
    const r = await globalThis.fetch(path, options);
    if (!r.ok) throw Object.assign(new Error("no"), { status: r.status });
    return r.json();
  };
  const theme = { apply: vi.fn(), current: () => "system" };
  const controllers = {
    search: createSearchController({ api, store }),
    keys: createKeysController({ store, api, storage: memoryStorage() }),
    jobs: createJobController({ api, store, refreshStatus: () => {}, loadAccess: () => {} }),
    estimate: createEstimateController({ api, store, storage: memoryStorage() }),
  };
  const el = document.createElement("digup-app");
  el.store = store;
  el.api = api;
  el.theme = theme;
  el.controllers = controllers;
  document.body.append(el);
  await el.updateComplete;
  await vi.advanceTimersByTimeAsync(0);              // the boot status poll
  return { el, store, calls, theme };
}

const key = (target, k) => target.dispatchEvent(
  new KeyboardEvent("keydown", { key: k, bubbles: true, composed: true, cancelable: true }));

describe("digup-app", () => {
  let ctx;
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => { ctx?.el.remove(); vi.useRealTimers(); document.body.dataset.page = ""; });

  it("the FIRST paint is a state: body[data-page] and the host mirror say idle", async () => {
    ctx = await mount();
    expect(document.body.dataset.page).toBe("idle");
    expect(ctx.el.dataset.page).toBe("idle");
    expect(ctx.el.renderRoot.querySelector("digup-search")).not.toBeNull();
    expect(ctx.el.renderRoot.querySelector("h1").textContent).toBe("DigUp");
    expect(ctx.el.renderRoot.getElementById("keys").textContent)
      .toBe("↑↓ pick · ↩ open · Space preview · Esc clear · type to search");
    expect(ctx.calls.map((c) => c.path)).toContain("/api/v1/status");
  });

  it("results arrive → the layout switch moves to results (the ONE switch, both places)", async () => {
    ctx = await mount();
    ctx.store.set({ results: { phase: "meaning", strong: [hit], weaker: [],
      groups: [{ title: "Images", rows: [hit] }], hitsById: new Map([hit].map((h) => [h.media_id, h])),
      showWeaker: false, selection: "a", lastReply: { hits: [hit], strong: 1, meaning: true, ms: {} } } });
    await ctx.el.updateComplete;
    expect(document.body.dataset.page).toBe("results");
    expect(ctx.el.dataset.page).toBe("results");
    expect(ctx.el.renderRoot.querySelector("digup-results")).not.toBeNull();
  });

  it("the gear opens the panel (keys load, aria-expanded true) and Esc closes it (aria-expanded false)", async () => {
    ctx = await mount();
    const gear = ctx.el.renderRoot.getElementById("gear");
    gear.click();
    await ctx.el.updateComplete;
    const settings = ctx.el.renderRoot.querySelector("digup-settings");
    expect(settings.hasAttribute("hidden")).toBe(false);
    expect(gear.getAttribute("aria-expanded")).toBe("true");
    await vi.advanceTimersByTimeAsync(0);
    expect(ctx.calls.map((c) => c.path)).toContain("/api/v1/tokens");
    expect(ctx.calls.map((c) => c.path)).toContain("/api/v1/targets");
    key(document, "Escape");
    await ctx.el.updateComplete;
    expect(settings.hasAttribute("hidden")).toBe(true);
    expect(gear.getAttribute("aria-expanded")).toBe("false");
  });

  it("suggestion chips take the ONE search route through digup-search", async () => {
    ctx = await mount();
    const suggest = ctx.el.renderRoot.querySelector("digup-suggest");
    const search = ctx.el.renderRoot.querySelector("digup-search");
    await search.updateComplete;
    const first = suggest.renderRoot.querySelector("button");
    const text = first.textContent;
    first.click();
    await search.updateComplete;
    expect(search.shadowRoot.getElementById("q").value).toBe(text);
  });

  it("the pinned Space guard: buttons keep Space activation; bare page areas preview", async () => {
    ctx = await mount();
    const gear = ctx.el.renderRoot.getElementById("gear");
    // Space ON the gear button: native activation, no Quick-Look.
    gear.focus();
    key(gear, " ");
    await ctx.el.updateComplete;
    expect(ctx.el.bigOpen).toBe(false);
    // Space with a selection after navigation, from a bare page area: the big look.
    ctx.store.set({ navigated: true, results: { phase: "meaning", strong: [hit], weaker: [],
      groups: [{ title: "Images", rows: [hit] }], hitsById: new Map([hit].map((h) => [h.media_id, h])),
      showWeaker: false, selection: "a", lastReply: { hits: [hit], strong: 1, meaning: true, ms: {} } } });
    await ctx.el.updateComplete;
    key(document, " ");
    await ctx.el.updateComplete;
    expect(ctx.el.bigOpen).toBe(true);
    expect(ctx.el.renderRoot.querySelector("digup-big").hasAttribute("hidden")).toBe(false);
    // Esc puts it away (the chain: big first, panel second).
    key(document, "Escape");
    await ctx.el.updateComplete;
    expect(ctx.el.bigOpen).toBe(false);
    expect(ctx.el.renderRoot.querySelector("digup-big").hasAttribute("hidden")).toBe(true);
  });

  it("the 15 s status poll keeps the engine's numbers coming (and stops on disconnect)", async () => {
    ctx = await mount();
    const before = ctx.calls.filter((c) => c.path === "/api/v1/status").length;
    await vi.advanceTimersByTimeAsync(15000);
    const after = ctx.calls.filter((c) => c.path === "/api/v1/status").length;
    expect(after).toBeGreaterThan(before);
    ctx.el.remove();
    await vi.advanceTimersByTimeAsync(60000);
    expect(ctx.calls.filter((c) => c.path === "/api/v1/status").length).toBe(after);
  });

  it("a 401 with no stored key makes the gear point (the api's pointer, not a prompt)", async () => {
    ctx = await mount();
    ctx.el.noteMissingKey();
    await ctx.el.updateComplete;
    expect(ctx.el.renderRoot.getElementById("gear").className).toContain("attention");
  });
});
