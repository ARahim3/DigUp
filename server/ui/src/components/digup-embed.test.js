// digup-embed — the widget: keyword-first (words at once, meaning after the pause),
// the host's ?q= runs at boot, tiles with the engine's fields (kind, name, z, at),
// previews as a grace (the on-screen rule; jsdom loads them straight), client-side
// kind/strength filters on the chips, the ready postMessage.
import { describe, expect, it, beforeEach, afterEach, vi } from "vitest";
import "./digup-embed.js";
import { createEmbedApi } from "../services/api.js";
import { installFetch, mockReply, memoryStorage } from "../lib/test-util.js";

const hits = [
  { media_id: "m1", kind: "image", path: "/x/b.jpg", z: 3.4 },
  { media_id: "m2", kind: "video", path: "/x/c.mp4", z: 1.2, loc: 2 },
];

async function mount(paramsStr = "limit=20&q=dog") {
  const store = memoryStorage({ digupEmbedToken: "readTok" });
  const client = createEmbedApi({ sessionStorageRef: store, prompt: () => "" });
  const calls = installFetch({
    "/api/v1/health": mockReply(200, { live: { searchable: 5 } }),
    "POST /api/v1/search": mockReply(200, { hits, strong: 1, meaning: true, ms: { embed: 4, search: 2 } }),
    "POST /api/v1/embed_ahead": mockReply(200, {}),
    "/api/v1/media/m1/preview?pixels=256": { ok: true, status: 200, blob: async () => new Blob(["x"]) },
    "/api/v1/media/m2/preview?pixels=256": { ok: true, status: 200, blob: async () => new Blob(["y"]) },
  });
  const el = document.createElement("digup-embed");
  el.api = client;
  el.params = new URLSearchParams(paramsStr);
  document.body.append(el);
  await el.updateComplete;
  await vi.advanceTimersByTimeAsync(0);            // health → q run → keyword reply
  await el.updateComplete;
  return { el, calls, store };
}

describe("digup-embed", () => {
  let ctx;
  beforeEach(() => {
    vi.useFakeTimers();
    if (!URL.createObjectURL) { URL.createObjectURL = vi.fn(() => "blob:1"); URL.revokeObjectURL = vi.fn(); }
  });
  afterEach(() => { ctx?.el.remove(); vi.useRealTimers(); });

  it("boots: health answers, the host's ?q= runs keyword-first with the bearer token", async () => {
    ctx = await mount();
    expect(ctx.calls.map((c) => c.path)).toContain("/api/v1/health");
    const searchCall = ctx.calls.find((c) => c.path === "/api/v1/search");
    expect(JSON.parse(searchCall.options.body)).toMatchObject({ q: "dog", meaning: false, limit: 20 });
    expect(searchCall.headers.authorization).toBe("Bearer readTok");
    expect(ctx.calls.map((c) => c.path)).toContain("/api/v1/embed_ahead");
  });

  it("meaning search runs after the pause (PAUSE + settle)", async () => {
    ctx = await mount();
    await vi.advanceTimersByTimeAsync(480);
    const meaning = ctx.calls.filter((c) => c.path === "/api/v1/search")
      .map((c) => JSON.parse(c.options.body)).find((b) => b.meaning);
    expect(meaning).toMatchObject({ q: "dog" });
  });

  it("tiles carry the engine's fields; the strong ones are flagged; previews land", async () => {
    ctx = await mount();
    await vi.advanceTimersByTimeAsync(10);         // previews (no IntersectionObserver in jsdom)
    await ctx.el.updateComplete;
    const tiles = ctx.el.shadowRoot.querySelectorAll("li.tile");
    expect(tiles.length).toBe(2);
    expect(tiles[0].classList.contains("strong")).toBe(true);
    expect(tiles[0].querySelector(".name").textContent).toBe("b.jpg");
    expect(tiles[0].querySelector(".z").textContent).toBe("z 3.40");
    expect(tiles[1].querySelector(".loc").textContent).toBe("at 2s");
    expect(tiles[0].querySelector("img")).not.toBeNull();
    const says = ctx.el.shadowRoot.getElementById("statusline").textContent;
    expect(says).toContain("2 hits · 1 strong");
  });

  it("the chips filter the current hits (client-side, like the vanilla widget)", async () => {
    ctx = await mount();
    const videos = ctx.el.shadowRoot.querySelector('button.chip[data-kind="video"]');
    videos.click();
    await ctx.el.updateComplete;
    const tiles = ctx.el.shadowRoot.querySelectorAll("li.tile");
    expect(tiles.length).toBe(1);
    expect(tiles[0].querySelector(".name").textContent).toBe("c.mp4");
    const strong = ctx.el.shadowRoot.getElementById("strong");
    strong.checked = true;
    strong.dispatchEvent(new Event("change"));
    await ctx.el.updateComplete;
    expect(ctx.el.shadowRoot.querySelectorAll("li.tile").length).toBe(0);   // the only hit here is weak
    ctx.el.shadowRoot.querySelector('button.chip[data-kind=""]').click();
    await ctx.el.updateComplete;
    expect(ctx.el.shadowRoot.querySelectorAll("li.tile.strong").length).toBe(1);
  });

  it("an empty query says the honest line and asks the engine nothing", async () => {
    ctx = await mount("limit=20");                 // no ?q
    const q = ctx.el.shadowRoot.getElementById("q");
    const before = ctx.calls.filter((c) => c.path === "/api/v1/search").length;
    q.value = "   ";
    q.dispatchEvent(new Event("input"));
    await ctx.el.updateComplete;
    expect(ctx.el.shadowRoot.getElementById("statusline").textContent)
      .toContain("say what you'd see, hear, or read");
    expect(ctx.calls.filter((c) => c.path === "/api/v1/search").length).toBe(before);
  });
});
