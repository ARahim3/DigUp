// digup-search — the ONE search route: every control change emits `digup:query-change`
// with the full filter set (the search-controller runs it; nothing here fetches).
// The in-field keys mirror the desktop panel: ↑↓ pick, ↩ open, Space preview after
// navigation, code prefix and checkbox one state.
import { describe, expect, it, beforeEach, afterEach, vi } from "vitest";
import "./digup-search.js";
import { onceEvent } from "../lib/test-util.js";

const key = (target, k) => target.dispatchEvent(
  new KeyboardEvent("keydown", { key: k, bubbles: true, composed: true, cancelable: true }));

async function mount() {
  const el = document.createElement("digup-search");
  document.body.append(el);
  await el.updateComplete;
  return el;
}

describe("digup-search", () => {
  let el;
  beforeEach(async () => { el = await mount(); });
  afterEach(() => el.remove());

  it("typing emits the full filter set with all six kinds by default", async () => {
    const p = onceEvent(document, "digup:query-change");
    const q = el.shadowRoot.getElementById("q");
    q.value = "dog";
    q.dispatchEvent(new Event("input"));
    const detail = (await p).detail;
    expect(detail.text).toBe("dog");
    expect(detail.limit).toBe(40);
    expect(detail.code).toBe(false);
    expect(detail.kinds).toEqual(["screenshot", "image", "pdf", "doc", "video", "audio"]);
  });

  it("the code checkbox and a kind un-tick ride the same event", async () => {
    const p = onceEvent(document, "digup:query-change");
    const code = el.shadowRoot.getElementById("code");
    code.checked = true;
    code.dispatchEvent(new Event("change"));
    const detail = (await p).detail;
    expect(detail.code).toBe(true);

    const p2 = onceEvent(document, "digup:query-change");
    const shot = el.shadowRoot.querySelector("#find .kind[data-kind=screenshot] input");
    shot.checked = false;
    shot.dispatchEvent(new Event("change"));
    expect((await p2).detail.kinds).toEqual(["image", "pdf", "doc", "video", "audio"]);
  });

  it("the limit select changes the asked-for count", async () => {
    const p = onceEvent(document, "digup:query-change");
    const limit = el.shadowRoot.getElementById("limit");
    limit.value = "100";
    limit.dispatchEvent(new Event("change"));
    expect((await p).detail.limit).toBe(100);
  });

  it("the all button is a toggle: all six on → click clears all → click restores all", async () => {
    const all = el.shadowRoot.getElementById("kinds-all");
    expect(all.getAttribute("aria-pressed")).toBe("true");            // the default: all on
    const p1 = onceEvent(document, "digup:query-change");
    all.click();
    expect((await p1).detail.kinds).toEqual([]);                      // all cleared
    expect(all.getAttribute("aria-pressed")).toBe("false");
    expect([...el.shadowRoot.querySelectorAll("#find .kind input")].every((i) => !i.checked)).toBe(true);
    const p2 = onceEvent(document, "digup:query-change");
    all.click();
    expect((await p2).detail.kinds).toEqual(["screenshot", "image", "pdf", "doc", "video", "audio"]);
    expect(all.getAttribute("aria-pressed")).toBe("true");
    expect([...el.shadowRoot.querySelectorAll("#find .kind input")].every((i) => i.checked)).toBe(true);
  });

  it("suggestion chips take this route: setValue writes the field and emits", async () => {
    const p = onceEvent(document, "digup:query-change");
    el.setValue("a campfire");
    const detail = (await p).detail;
    expect(detail.text).toBe("a campfire");
    expect(el.shadowRoot.getElementById("q").value).toBe("a campfire");
  });

  it("in-field keys: ↑↓ nav, ↩ activate, Space previews only after navigation", async () => {
    const nav = onceEvent(document, "digup:nav");
    key(el.shadowRoot.getElementById("q"), "ArrowDown");
    expect((await nav).detail.step).toBe(1);

    const act = onceEvent(document, "digup:activate");
    key(el.shadowRoot.getElementById("q"), "Enter");
    await act;

    // Space BEFORE navigation types a space (no preview event).
    el.navigated = false;
    el.hasSelection = true;
    await el.updateComplete;
    let previewed = false;
    document.addEventListener("digup:preview", () => { previewed = true; }, { once: true, capture: true });
    key(el.shadowRoot.getElementById("q"), " ");
    await el.updateComplete;
    expect(previewed).toBe(false);

    el.navigated = true;
    await el.updateComplete;
    const preview = onceEvent(document, "digup:preview");
    key(el.shadowRoot.getElementById("q"), " ");
    await preview;
  });
});
