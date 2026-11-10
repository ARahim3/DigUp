// estimate-controller.js — Estimate: the engine's own forecast for the server's
// folders (POST /estimate). The controller keeps its on/off gate (the browser key
// `digupEstimateOn`, a generation token, a click-again cancel); the panel's shape is
// the round-6 brief: NO switch, NO forecast rows — the gear's Estimate button rides
// the Index now row (the shell forces `on` on every click, so a browser that stored
// "off" is never left with a dead button), and the INDEXING heading carries the
// spinning circle + the brief summary while it runs and when it lands. The main page
// shows no estimate popup at all.
// Generation token (like searches have): a second click during a slow crawl must not
// let the FIRST crawl's late reply write rows into a panel closed and reopened in between.
export function createEstimateController({ api, store, storage = localStorage,
                                           key = "digupEstimateOn" }) {
  const seq = { token: 0 };

  function estimateOn() {
    const stored = storage.getItem(key);
    return stored === null ? true : stored === "1";
  }

  function setToggle(on) {
    storage.setItem(key, on ? "1" : "0");
    if (!on) {                            // switching off stops a run in flight
      seq.token++;
      store.set({ estimate: { on: false, spinning: false, rows: null, error: null } });
    } else {
      store.set({ estimate: { ...store.get().estimate, on: true } });
    }
  }

  async function runEstimate() {
    const e = store.get().estimate || {};
    if (!estimateOn()) {                  // the toggle gates the control (round 7)
      store.set({ estimate: { ...e, on: true, spinning: false, rows: null, error: null } });
      return;
    }
    if (e.spinning || (e.rows && !e.error)) {   // click again = cancel + clear
      seq.token++;
      store.set({ estimate: { on: true, spinning: false, rows: null, error: null } });
      return;
    }
    const token = ++seq.token;
    store.set({ estimate: { ...e, on: true, spinning: true } });
    try {
      const {folders} = await api("/api/v1/estimate", {method: "POST", body: JSON.stringify({})});
      if (token !== seq.token) return;              // a newer click owns the rows now
      store.set({ estimate: { on: true, spinning: false, rows: folders, error: null } });
    } catch (error) {
      if (token === seq.token) {
        store.set({ estimate: { on: true, spinning: false, rows: null,
                                error: `estimate failed: ${error.message}` } });
      }
    }
  }

  function cancel() {                     // the Esc chain closes the forecast (vanilla parity)
    seq.token++;
    store.set({ estimate: { ...store.get().estimate, spinning: false, rows: null, error: null } });
  }

  store.set({ estimate: { on: estimateOn(), spinning: false, rows: null, error: null } });

  return { estimateOn, setToggle, runEstimate, cancel };
}
