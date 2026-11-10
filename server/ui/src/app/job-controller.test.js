// job-controller.js — the index job's rules, verbatim from the vanilla app.js:
// one poll loop per live job (the 409 dedupe), an honest answer when a poll fails
// (the S1 lesson: a dead promise froze "indexing…" forever), and a finished crawl
// re-reads the status and the index list.
import { describe, expect, it, beforeEach, afterEach, vi } from "vitest";
import { createStore } from "./store.js";
import { createJobController } from "./job-controller.js";
import { mockReply } from "../lib/test-util.js";

const base = () => createStore({ results: { phase: "empty", strong: [], weaker: [], groups: [],
  hitsById: new Map(), showWeaker: false, selection: null, lastReply: null },
  filters: { kinds: [], limit: 40 }, isCode: false, text: "", navigated: false,
  job: null, indexing: null });

describe("indexNow + pollJob", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it("queues, polls the states with the engine's counts, and reloads access when done", async () => {
    const store = base();
    const refreshStatus = vi.fn(), loadAccess = vi.fn();
    let polls = 0;
    const calls = [];
    globalThis.fetch = async (path, options = {}) => {
      calls.push({ path, options });
      if (path === "/api/v1/index") return mockReply(202, { job: { id: "abc123" } });
      polls++;
      return mockReply(200, { job: polls === 1
        ? { state: "running", searchable: 3, files: 10, pending: 2, vectors: 5, files_done: 4, seconds: 12 }
        : { state: "done", searchable: 10, files: 10, vectors: 20, files_done: 10, seconds: 30 } });
    };
    const api = async (path, options) => {
      const r = await globalThis.fetch(path, options);
      return r.json();
    };
    const c = createJobController({ api, store, refreshStatus, loadAccess });
    await c.indexNow(false);
    expect(store.get().job.text).toBe("job abc123 queued");
    await vi.advanceTimersByTimeAsync(0);                     // first poll (no delay before it)
    expect(store.get().job.text).toContain("searchable 3/10");
    expect(store.get().job.text).toContain("indexed 4");
    expect(store.get().indexing.state).toBe("running");
    await vi.advanceTimersByTimeAsync(2000);                  // done at the second poll
    expect(store.get().job.state).toBe("done");
    expect(store.get().indexing).toBeNull();
    expect(refreshStatus).toHaveBeenCalledTimes(1);
    expect(loadAccess).toHaveBeenCalledTimes(1);
  });

  it("a failed poll says so and clears the indexing state (never a frozen footer)", async () => {
    const store = base();
    globalThis.fetch = async (path) => {
      if (path === "/api/v1/index") return mockReply(202, { job: { id: "abc123" } });
      return mockReply(503, { detail: "searcher is warming" });
    };
    const api = async (path, options) => {
      const r = await globalThis.fetch(path, options);
      if (!r.ok) throw Object.assign(new Error("HTTP 503"), { status: 503 });
      return r.json();
    };
    const c = createJobController({ api, store, refreshStatus: vi.fn(), loadAccess: vi.fn() });
    c.indexNow(true);
    await vi.advanceTimersByTimeAsync(0);
    expect(store.get().job.state).toBe("interrupted");
    expect(store.get().job.text).toContain("job poll failed: HTTP 503");
    expect(store.get().indexing).toBeNull();
    expect(c.jobPoll).toBeNull();
  });

  it("409 busy: poll the live job ONCE — repeated clicks do not stack loops", async () => {
    const store = base();
    let polls = 0;
    globalThis.fetch = async (path) => {
      if (path === "/api/v1/index") return mockReply(409, { detail: "job live9 is running" });
      polls++;
      return mockReply(200, { job: { state: "running", files_done: 1, files: 2, searchable: 1, vectors: 2 } });
    };
    const api = async (path, options) => {
      const r = await globalThis.fetch(path, options);
      if (!r.ok) throw Object.assign(new Error(r.detail), { status: r.status });
      return r.json();
    };
    const c = createJobController({ api, store, refreshStatus: vi.fn(), loadAccess: vi.fn() });
    await Promise.all([c.indexNow(false), c.indexNow(false), c.indexNow(false)]);   // three clicks
    expect(store.get().job.text).toBe("busy — a job is already running");
    await vi.advanceTimersByTimeAsync(6000);
    expect(polls).toBeLessThanOrEqual(4);                       // ONE loop: 1 poll per 2 s
  });
});
