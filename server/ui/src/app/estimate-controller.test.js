// estimate-controller.js — the panel's forecast: the toggle gates the control and is
// kept in this browser (digupEstimateOn), the run shows the engine's folders, a slow
// crawl's LATE reply never writes into a panel that was cancelled/restarted (the
// generation token), and the Esc chain's cancel owns its path.
import { describe, expect, it, vi } from "vitest";
import { createStore } from "./store.js";
import { createEstimateController } from "./estimate-controller.js";
import { memoryStorage } from "../lib/test-util.js";

const folders = [{ folder: "/photos", readable: true, seconds: 12, files: { image: 3 },
                   bytes: 1000, ms: 20, subfolders: [], calibrated: true }];

describe("estimate controller", () => {
  it("the toggle is kept in this browser, defaulting ON, gating the run", async () => {
    const storage = memoryStorage();
    const store = createStore({});
    const api = vi.fn(async () => ({ folders }));
    const c = createEstimateController({ api, store, storage });
    expect(c.estimateOn()).toBe(true);
    c.setToggle(false);
    expect(storage.getItem("digupEstimateOn")).toBe("0");
    expect(store.get().estimate).toMatchObject({ on: false, spinning: false, rows: null });
    await c.runEstimate();                                      // gated: the engine is not asked
    expect(api).not.toHaveBeenCalled();
    c.setToggle(true);
    expect(storage.getItem("digupEstimateOn")).toBe("1");
  });

  it("runs spin → rows; click again cancels and clears (no rows on a cancelled run)", async () => {
    const storage = memoryStorage();
    const store = createStore({});
    let resolveRun;
    const api = vi.fn(() => new Promise((r) => { resolveRun = r; }));
    const c = createEstimateController({ api, store, storage });
    const run = c.runEstimate();
    expect(store.get().estimate.spinning).toBe(true);
    await c.runEstimate();                                      // second click: cancel + clear
    expect(store.get().estimate).toMatchObject({ spinning: false, rows: null });
    resolveRun({ folders });                                    // the first crawl answers LATE
    await run; await Promise.resolve();
    expect(store.get().estimate.rows).toBeNull();               // its reply was dropped
  });

  it("a late reply of the NEWEST run lands; cancel() (the Esc chain) drops everything", async () => {
    const store = createStore({});
    const storage = memoryStorage();
    let resolveRun;
    const api = vi.fn(() => new Promise((r) => { resolveRun = r; }));
    const c = createEstimateController({ api, store, storage });
    const run = c.runEstimate();
    resolveRun({ folders });
    await run; await Promise.resolve();
    expect(store.get().estimate.rows).toEqual(folders);
    c.cancel();
    expect(store.get().estimate).toMatchObject({ spinning: false, rows: null, error: null });
  });

  it("a failed estimate shows its honest line, carrying the toggle's state", async () => {
    const store = createStore({});
    const api = vi.fn(async () => { throw Object.assign(new Error("walk timed out"), { status: 502 }); });
    const c = createEstimateController({ api, store, storage: memoryStorage() });
    await c.runEstimate();
    expect(store.get().estimate.error).toContain("estimate failed: walk timed out");
    expect(store.get().estimate.spinning).toBe(false);
  });
});
