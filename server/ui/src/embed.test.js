// src/embed.js — the widget's boot as an iframe host lands it: ?token= moves to
// sessionStorage and OUT of the URL line (history.replaceState — the secret never
// lands in bookmarks, history, or the host app's logs), limit/q hand off to the
// widget, and the bearer token rides every call.
import { describe, expect, it, afterEach, vi } from "vitest";
import { installFetch, mockReply } from "./lib/test-util.js";

describe("embed.js entry", () => {
  afterEach(() => {
    document.querySelector("digup-embed")?.remove();
    vi.useRealTimers();
  });

  it("adopts ?token=, rewrites the URL line, runs ?q= with the bearer header", async () => {
    vi.useFakeTimers();
    sessionStorage.clear();
    history.pushState(null, "", "/embed.html?token=secret123&q=dog&limit=20");
    const calls = installFetch({
      "/api/v1/health": mockReply(200, { live: { searchable: 7 } }),
      "POST /api/v1/search": mockReply(200, { hits: [], strong: 0, meaning: true, ms: {} }),
      "POST /api/v1/embed_ahead": mockReply(200, {}),
    });
    document.body.append(document.createElement("digup-embed"));   // embed.html declares it
    await import("./embed.js");
    expect(sessionStorage.getItem("digupEmbedToken")).toBe("secret123");
    expect(location.search).toBe("?q=dog&limit=20");           // the secret is GONE from the URL
    expect(location.search).not.toContain("secret123");
    const widget = document.querySelector("digup-embed");
    expect(document.querySelectorAll("digup-embed").length).toBe(1);   // ONE widget, the wired one
    expect(widget).not.toBeNull();
    await widget.updateComplete;
    await vi.advanceTimersByTimeAsync(0);
    const searchCall = calls.find((c) => c.path === "/api/v1/search");
    expect(JSON.parse(searchCall.options.body)).toMatchObject({ q: "dog", limit: 20, meaning: false });
    expect(searchCall.headers.authorization).toBe("Bearer secret123");
  });
});
