// digup-results — grouped strong hits, the weaker fold, the listbox semantics
// (aria-selected + roving tabindex), the engine's counter line, thumbnails that fall
// back to the kind icon, and excerpt marks. File names and excerpts stay text nodes.
import { describe, expect, it, beforeEach, afterEach, vi } from "vitest";
import "./digup-results.js";
import { WEAKER } from "../lib/format.js";
import { onceEvent } from "../lib/test-util.js";

const a = { media_id: "a", kind: "image", path: "/x/a.jpg", z: 3.2, excerpt: "the «dog» ran" };
const b = { media_id: "b", kind: "image", path: "/x/b.jpg", z: 2.1 };
const c = { media_id: "c", kind: "video", path: "/x/c.mp4", z: 2.0, loc: 12 };

const fixture = (over = {}) => ({
  phase: "meaning", strong: [a], weaker: [c], groups: [{ title: "Images", rows: [a] }],
  hitsById: new Map([a, b, c].map((h) => [h.media_id, h])),
  showWeaker: false, selection: "a",
  lastReply: { hits: [a, c], strong: 1, meaning: true, ms: { embed: 100, search: 200 } },
  ...over,
});

async function mount(results = fixture()) {
  const el = document.createElement("digup-results");
  el.results = results;
  document.body.append(el);
  await el.updateComplete;
  return el;
}

describe("digup-results", () => {
  let el;
  afterEach(() => el?.remove());

  it("renders the engine's counter line, the group, the selected row, the fold", async () => {
    el = await mount();
    const says = el.shadowRoot.getElementById("engine-says").textContent;
    expect(says).toContain("2 hits · 1 strong");
    expect(says).toContain("embed 0.10 s");
    expect(says).toContain("search 0.20 s");
    expect(el.shadowRoot.querySelector(".group-title").textContent).toBe("Images");
    const row = el.shadowRoot.querySelector("li.row");
    expect(row.classList.contains("selected")).toBe(true);
    expect(row.getAttribute("aria-selected")).toBe("true");
    expect(row.getAttribute("tabindex")).toBe("0");
    const fold = el.shadowRoot.querySelector("li.weaker");
    expect(fold.textContent).toContain("1 weaker match");
    expect(fold.getAttribute("aria-expanded")).toBe("false");
    expect(fold.getAttribute("tabindex")).toBe("-1");
  });

  it("the matched words arrive as <mark>, the folder as the row's subtitle", async () => {
    el = await mount();
    const row = el.shadowRoot.querySelector("li.row");
    expect(row.querySelector("mark").textContent).toBe("dog");
    expect(row.querySelector(".name").textContent).toBe("a.jpg");
  });

  it("the fold toggles through the event; rows answer click (select) and dblclick/Enter (open)", async () => {
    el = await mount();
    const p = onceEvent(document, "digup:toggle-weaker");
    el.shadowRoot.querySelector("li.weaker").click();
    await p;

    const sel = onceEvent(document, "digup:select");
    el.shadowRoot.querySelector("li.row").click();
    expect((await sel).detail.mediaId).toBe("a");

    const open = onceEvent(document, "digup:open");
    el.shadowRoot.querySelector("li.row").dispatchEvent(
      new KeyboardEvent("keydown", { key: "Enter", bubbles: true, composed: true, cancelable: true }));
    expect((await open).detail.mediaId).toBe("a");
  });

  it("an unfolded fold renders the weaker rows with the sentinel selected", async () => {
    el = await mount(fixture({ showWeaker: true, selection: WEAKER }));
    const rows = el.shadowRoot.querySelectorAll("li.row");
    expect(rows.length).toBe(2);                        // a + c
    const fold = el.shadowRoot.querySelector("li.weaker");
    expect(fold.getAttribute("aria-expanded")).toBe("true");
    expect(fold.getAttribute("aria-selected")).toBe("true");
    expect(fold.classList.contains("selected")).toBe(true);
  });

  it("image thumbnails are the engine's small lazy renders; a broken preview becomes the kind icon", async () => {
    el = await mount();
    const img = el.shadowRoot.querySelector("li.row img.thumb");
    expect(img.getAttribute("loading")).toBe("lazy");
    expect(img.getAttribute("src")).toContain("/api/v1/media/a/preview?pixels=");
    img.dispatchEvent(new Event("error"));
    await el.updateComplete;
    expect(el.shadowRoot.querySelector("li.row img.thumb")).toBeNull();
    expect(el.shadowRoot.querySelector("li.row .kind-icon").textContent).toBe("▣");
  });

  it("an empty meaning answer carries the engine's own sentence verbatim", async () => {
    el = await mount(fixture({ phase: "none", strong: [], weaker: [], groups: [],
      selection: null, lastReply: { hits: [], strong: 0, meaning: true, ms: {} } }));
    expect(el.shadowRoot.getElementById("engine-says").textContent)
      .toContain("the engine found no good matches for this and refused to guess — that is its answer");
  });
});
