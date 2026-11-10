// digup-settings — the gear panel: the four sections (Appearance · Indexing · Index
// status · API access), the store slice it reads (keys/status/job/estimate), the status
// card (the two count tiles + wrapping badges), the key rows (the key in a field, ⧉ copy
// and ↻ regenerate as icon buttons at its right), the collapse of an empty section, and
// the control events. The roots line left the card (round-5 brief); the target rows left
// in round 3 — the counts ride the tiles from /api/v1/status.
import { describe, expect, it, beforeEach, afterEach, vi } from "vitest";
import "./digup-settings.js";
import { createStore } from "../app/store.js";
import { onceEvent } from "../lib/test-util.js";

const state = {
  keys: { admin: "adm1n-key", apps: [{ name: "nextcloud", token: "app-key-1" }],
          envFlagged: false, minted: true },
  targets: [{ name: "media", main: true, files: 10, searchable: 9, roots: ["/media/photos"] }],
  status: { files: 10, searchable: 9, vectors: 20, encoder: "gemma-2",
            kinds: [{ kind: "image", files: 5 }], index_size: "12 MB", build_tag: "b11461" },
  roots: ["/media/photos"],
  job: { state: "running", text: "searchable 3/10" },
  estimate: { on: true, spinning: true, rows: null, error: null },
};

async function mount(over = {}) {
  const store = createStore({ ...state, ...over });
  const el = document.createElement("digup-settings");
  el.store = store;
  el.theme = "system";
  document.body.append(el);
  await el.updateComplete;
  return el;
}

describe("digup-settings", () => {
  let el;
  afterEach(() => el?.remove());

  it("renders the minted key rows: key in a field, ⧉ Copy, ↻ Regenerate at the admin row", async () => {
    el = await mount();
    const rows = el.shadowRoot.querySelectorAll("#appkeys .appkey-line");
    expect(rows.length).toBe(2);
    expect(rows[0].querySelector(".appkey-field").value).toBe("adm1n-key");   // the key is in the box
    const buttons = [...rows[0].querySelectorAll("button")].map((b) => b.textContent.trim());
    expect(buttons).toEqual(["⧉", "↻"]);                            // icon-only, 2rem squares
    expect([...rows[0].querySelectorAll("button")].map((b) => b.getAttribute("aria-label")))
      .toEqual(["Copy this API key to the clipboard",
                "Regenerate: new keys now, the old ones stop working"]);
    expect(rows[1].querySelector(".appkey-name").textContent).toContain("nextcloud");
    expect(rows[1].querySelector(".appkey-field").value).toBe("app-key-1");
  });

  it("an env-keyed deployment shows its honest line; a tokenless one collapses the section", async () => {
    el = await mount({ keys: { admin: null, apps: [], envFlagged: true, minted: false } });
    expect(el.shadowRoot.getElementById("api-key-sec").hasAttribute("hidden")).toBe(false);
    expect(el.shadowRoot.getElementById("api-key-sec").textContent)
      .toContain("Set in the server's environment");
    el.remove();
    el = await mount({ keys: { admin: null, apps: [], envFlagged: false, minted: false } });
    expect(el.shadowRoot.getElementById("api-key-sec").hasAttribute("hidden")).toBe(true);
  });

  it("the panel's controls speak through events: theme, estimate toggle, Estimate, Regenerate, index", async () => {
    el = await mount();
    const theme = onceEvent(document, "digup:theme");
    const select = el.shadowRoot.getElementById("theme");
    select.value = "dark";
    select.dispatchEvent(new Event("change"));
    expect((await theme).detail.choice).toBe("dark");

    const est = onceEvent(document, "digup:estimate");
    el.shadowRoot.getElementById("estimate-btn").click();
    await est;

    const regen = onceEvent(document, "digup:regenerate");
    el.shadowRoot.getElementById("keys-regenerate").click();
    await regen;

    const idx = onceEvent(document, "digup:index");
    el.shadowRoot.getElementById("index-btn").click();
    expect((await idx).detail.prune).toBe(false);

    const close = onceEvent(document, "digup:close");
    el.shadowRoot.getElementById("settings-close").click();
    await close;
  });

  it("the store slice it reads: the job line, the engine's fact badges, the roots, the spin", async () => {
    el = await mount();
    expect(el.shadowRoot.getElementById("job").textContent).toContain("searchable 3/10");
    expect(el.shadowRoot.getElementById("job").classList.contains("job-running")).toBe(true);
    const facts = el.shadowRoot.querySelector(".set-facts").textContent;
    expect(facts).toContain("20 vectors");
    expect(facts).toContain("image 5");
    expect(facts).toContain("index 12 MB");
    expect(facts).toContain("llama.cpp b11461");
    const rootsLine = el.shadowRoot.getElementById("rootsline");
    expect(rootsLine).toBeNull();                                   // round-5: the line is gone
    const stats = [...el.shadowRoot.querySelectorAll(".stat")].map((s) => s.textContent.replace(/\s+/g, " ").trim());
    expect(stats[0]).toContain("Total files 10");                   // the engine's counts, side by side
    expect(stats[1]).toContain("Searchable files 9");
    expect(el.shadowRoot.getElementById("targets")).toBeNull();    // the rows are gone
    expect(el.shadowRoot.getElementById("estimate-spin")).not.toBeNull();
  });

  it("the copy button copies: clipboard when present, execCommand fallback on http", async () => {
    el = await mount();
    const btn = el.shadowRoot.querySelectorAll("#appkeys .key-icon")[0];
    // jsdom ships no navigator.clipboard — the exact insecure-context (http LAN) shape:
    // the click must fall through to the textarea + execCommand path and answer ✓.
    const exec = vi.fn(() => true);
    el.ownerDocument.execCommand = exec;
    btn.click();
    expect(exec).toHaveBeenCalledWith("copy");
    expect(btn.textContent).toBe("✓");
  });

  it("the heading's brief update: estimate summary + checkmark, the job's running circle, the honest failure", async () => {
    el = await mount({ job: null, estimate: { on: true, spinning: false,
      rows: [{ folder: "/photos", readable: true, seconds: 12, files: { image: 3 },
               bytes: 2e6, ms: 20, subfolders: [], calibrated: true }], error: null } });
    const job = el.shadowRoot.getElementById("job");
    expect(job.textContent).toContain("estimate ≈ 12 s · 1 folder");   // the engine's seconds, brief
    expect(el.shadowRoot.querySelector(".state-done")).not.toBeNull();
    expect(el.shadowRoot.querySelector(".state-err")).toBeNull();
    el.remove();
    el = await mount({ job: null, estimate: { on: true, spinning: false, rows: null,
      error: "estimate failed: walk timed out" } });
    expect(el.shadowRoot.getElementById("job").textContent).toBe("estimate failed");
    expect(el.shadowRoot.querySelector(".state-err").getAttribute("title"))
      .toBe("estimate failed: walk timed out");
    expect(el.shadowRoot.querySelector(".state-done")).toBeNull();
  });
});
