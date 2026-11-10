// search-controller.js — keyword-first typing, exactly as the desktop panel types
// (the vanilla app.js logic carried over verbatim): words at once with the last word
// as a prefix, meaning after the pause, the query embedded while you type (embed_ahead),
// strong/weaker grouping, selection bookkeeping. Sequencing tokens (generation,
// finalGeneration, the pause timer) stay HERE — they are sequencing, not app state
// (AGENTS.md §State). The results slice it writes is what digup-results/preview/footer read.
import { KIND_TITLE, WEAKER } from "../lib/format.js";

const TYPING_PAUSE = 120;              // ms after the last keystroke until meaning results

export function createSearchController({ api, store, pause = TYPING_PAUSE }) {
  const seq = { generation: 0, finalGeneration: -1, timer: null };

  const results = () => store.get().results;

  function searchBody(text, meaning, prefixLast) {
    const s = store.get();
    const f = s.filters;
    const body = {q: text, code: s.isCode, meaning, limit: f.limit};
    if (prefixLast) body.prefix_last = true;
    if (!s.isCode) {
      const kinds = f.kinds;
      body.kinds = (kinds.length === 0 || kinds.length === 6) ? null : kinds;   // none ticked = all
    }
    return body;
  }

  /** The ONE search route (vanilla queryChanged): the typed text, the code prefix, the
   *  keyword-first pair of calls, the embed-ahead warm-up, the generation guards. */
  function queryChanged(typed, filters) {
    store.set({ filters });
    const trimmed = typed.trim();
    const prefixCode = /^code:/i.test(trimmed);
    const code = prefixCode || filters.code;
    const text = prefixCode ? trimmed.slice(5).trim() : typed;
    store.set({ isCode: code, text });
    const generation = ++seq.generation;
    clearTimeout(seq.timer);
    store.set({ navigated: false, error: null });
    if (!trimmed || (code && !text)) {
      show({hits: [], strong: 0}, code && !text ? "codeHint" : "empty");
      return;
    }
    // Words now. The last word is probably half-typed, so it matches as a prefix.
    api("/api/v1/search", {method: "POST", body: JSON.stringify(searchBody(text, false, true))})
      .then((reply) => { if (generation === seq.generation && seq.finalGeneration !== generation) show(reply, "words"); })
      .catch((error) => { if (generation === seq.generation) failed(error); });
    // The meaning is embedded now, so its vector is ready when typing pauses (embed_ahead).
    api("/api/v1/embed_ahead", {method: "POST", body: JSON.stringify({q: text, code})}).catch(() => {});
    seq.timer = setTimeout(() => {
      api("/api/v1/search", {method: "POST", body: JSON.stringify(searchBody(text, true, false))})
        .then((reply) => {
          if (generation !== seq.generation) return;
          seq.finalGeneration = generation;
          show(reply, reply.meaning ? "meaning" : "wordsOnly");
        })
        .catch((error) => { if (generation === seq.generation) failed(error); });
    }, pause);
  }

  function failed(error) {
    store.set({ error: String(error.message || error) });
  }

  // The hits: strong results grouped by kind, the rest folded ("N weaker matches").
  function show(reply, phase) {
    const hits = reply.hits || [];
    const strong = Math.min(reply.strong ?? hits.length, hits.length);
    const s = store.get();
    const prev = s.results;
    const strongRows = hits.slice(0, strong);
    const weakerRows = hits.slice(strong);
    const groups = new Map();
    for (const hit of strongRows) {
      const title = KIND_TITLE[hit.kind] || "Files";
      if (!groups.has(title)) groups.set(title, []);
      groups.get(title).push(hit);
    }
    const navigated = s.navigated;
    const next = {
      phase, strong: strongRows, weaker: weakerRows,
      groups: [...groups].map(([title, rows]) => ({title, rows})),
      hitsById: new Map(hits.map((hit) => [hit.media_id, hit])),
      showWeaker: navigated ? prev.showWeaker : false,
      selection: prev.selection, lastReply: reply,
    };
    const ids = rowIDs(next);
    if (!navigated || !ids.includes(next.selection)) next.selection = ids[0] ?? null;
    store.set({ results: next });
  }

  function rowIDs(r = results()) {
    return [
      ...r.groups.flatMap((group) => group.rows.map((hit) => hit.media_id)),
      ...(r.weaker.length ? [WEAKER] : []),
      ...(r.showWeaker ? r.weaker.map((hit) => hit.media_id) : []),
    ];
  }

  function move(step) {
    const ids = rowIDs();
    if (!ids.length) return;
    const s = store.get();
    const at = ids.indexOf(s.results.selection);
    const selection = ids[Math.max(0, Math.min(ids.length - 1, (at < 0 ? -1 : at) + step))];
    store.set({ navigated: true, results: { ...s.results, selection } });
  }

  function select(mediaId) {
    const s = store.get();
    store.set({ navigated: true, results: { ...s.results, selection: mediaId } });
  }

  function toggleWeaker() {
    const s = store.get();
    store.set({ results: { ...s.results, showWeaker: !s.results.showWeaker, selection: WEAKER } });
  }

  const selectedHit = () => { const s = store.get(); return s.results.hitsById.get(s.results.selection) ?? null; };

  return { queryChanged, move, select, toggleWeaker, selectedHit, rowIDs, failed };
}
