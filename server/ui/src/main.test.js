// src/main.js — the full UI's boot as served: index.html DECLARES <digup-app> and the
// entry wires that element (store, theme, api, controllers); the first paint is idle
// (body[data-page]), the status poll starts. This is the shape FastAPI's static mount
// hands the browser at `/`.
import { describe, expect, it, afterEach, vi } from "vitest";
import { installFetch, mockReply } from "./lib/test-util.js";

describe("main.js entry", () => {
  afterEach(() => {
    document.querySelector("digup-app")?.remove();
    vi.useRealTimers();
  });

  it("boots the app: theme applied, idle first paint, status polling", async () => {
    vi.useFakeTimers();
    const calls = installFetch({
      "/api/v1/status": mockReply(200, { encoder: "gemma-2", vectors: 3, kinds: [],
                                          index_size: "1 MB", build_tag: "b1", roots: ["/m"] }),
    });
    localStorage.clear();
    // The served shape: index.html DECLARES <digup-app>, the entry wires THAT element.
    // The double-mount bug (measured 2026-11-08 in a browser: a DigUp header above a
    // working DigUp page) is exactly a second, unwired instance — pinned here.
    document.body.append(document.createElement("digup-app"));
    await import("./main.js");
    const app = document.querySelector("digup-app");
    expect(document.querySelectorAll("digup-app").length).toBe(1);   // ONE app, the wired one
    expect(app).not.toBeNull();
    expect(document.documentElement.dataset.theme).toBe("system");
    expect(localStorage.getItem("digup-theme")).toBe("system");
    await app.updateComplete;
    await vi.advanceTimersByTimeAsync(0);
    expect(document.body.dataset.page).toBe("idle");
    expect(app.dataset.page).toBe("idle");
    expect(calls.map((c) => c.path)).toContain("/api/v1/status");
  });
});
