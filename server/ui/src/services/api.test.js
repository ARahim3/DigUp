// services/api.js — the pinned header and 401 shapes, the 422 detail-list rendering,
// the widget's token adoption and ask-once recovery (test_media_ui / test_integrations
// pin these rules on the served bundle; these are their behavior tests).
import { describe, expect, it, beforeEach } from "vitest";
import { createApiClient, createEmbedApi } from "./api.js";
import { installFetch, mockReply, memoryStorage } from "../lib/test-util.js";

describe("createApiClient", () => {
  let storage, calls;
  beforeEach(() => {
    storage = memoryStorage();
  });

  it("sends the bearer header only when a key is stored, as `Bearer <key>`", async () => {
    storage.setItem("digupBearer", "adm1n");
    const { api } = createApiClient({ getToken: () => storage.getItem("digupBearer"), storage });
    calls = installFetch({ "POST /api/v1/index": mockReply(200, { job: { id: "a" } }) });
    await api("/api/v1/index", { method: "POST" });
    expect(calls[0].headers.authorization).toBe("Bearer adm1n");
    expect(calls[0].headers["content-type"]).toBe("application/json");
  });

  it("a 401 with no stored key: names the server's shape once and points at the gear", async () => {
    let pointed = 0;
    const { api } = createApiClient({ getToken: () => null, onNoToken: () => { pointed++; } });
    installFetch({ "/api/v1/status": mockReply(401, {}) });
    await expect(api("/api/v1/status")).rejects.toThrow(/operator set in its environment/);
    expect(pointed).toBe(1);
  });

  it("FastAPI's 422 detail LIST renders as loc+msg pairs (never [object Object])", async () => {
    const { api } = createApiClient({ getToken: () => null });
    installFetch({ "/api/v1/search": mockReply(422, { detail: [
      { loc: ["body", "limit"], msg: "limit > 100" },
      { loc: ["body", "q"], msg: "too short" },
    ] }) });
    await expect(api("/api/v1/search")).rejects.toThrow("limit limit > 100; q too short");
  });

  it("a string detail and a non-JSON body fall back honestly", async () => {
    const { api } = createApiClient({ getToken: () => null });
    installFetch({ "/a": mockReply(502, { detail: "walk timed out" }),
                   "/b": { status: 500, ok: false, json: async () => { throw new Error("no json"); },
                           statusText: "Server Error" } });
    await expect(api("/a")).rejects.toThrow("walk timed out");
    await expect(api("/b")).rejects.toThrow("Server Error");
  });
});

describe("createEmbedApi", () => {
  it("?token= adoption stores the secret in sessionStorage (the host's secret shape)", async () => {
    const store = memoryStorage();
    const client = createEmbedApi({ sessionStorageRef: store, prompt: () => "" });
    client.adoptUrlToken("readTok");
    expect(store.getItem("digupEmbedToken")).toBe("readTok");
    const calls = installFetch({ "/api/v1/search": mockReply(200, { hits: [] }) });
    await client.api("/api/v1/search");
    expect(calls[0].headers.authorization).toBe("Bearer readTok");
  });

  it("a 401 with a stored token: clears it, asks ONCE, retries with the answer", async () => {
    const store = memoryStorage({ digupEmbedToken: "stale" });
    let asks = 0;
    const client = createEmbedApi({ sessionStorageRef: store,
      prompt: () => { asks++; return "fresh"; } });
    const calls = installFetch({ "/api/v1/search": async (path, options) =>
      (options.headers.authorization === "Bearer fresh")
        ? mockReply(200, { hits: [] }) : mockReply(401, {}) });
    await client.api("/api/v1/search", { headers: {} });
    expect(asks).toBe(1);
    expect(client.token).toBe("fresh");
    expect(store.getItem("digupEmbedToken")).toBe("fresh");
  });

  it("a second 401 (the asked token refused too) says so — it never loops", async () => {
    const store = memoryStorage({ digupEmbedToken: "stale" });
    const client = createEmbedApi({ sessionStorageRef: store, prompt: () => "nope" });
    installFetch({ "/api/v1/health": mockReply(401, {}) });
    await expect(client.api("/api/v1/health")).rejects.toThrow("the bearer token was refused");
  });
});
