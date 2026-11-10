// main.js — the full UI's entry (server/ui/AGENTS.md §State): composition only. One
// store, the theme applied before the first paint (no flash), the api client wired
// once, the four controllers taking the seams they own, and <digup-app> composes them.
// The vanilla startup lines this mirrors (app.js's tail): `render(); refreshStatus();
// setInterval(refreshStatus, 15000); $("q").focus()` — the shell's firstUpdated runs
// exactly those (the first paint is a state too, the 15 s status poll, the focus).
import "./styles/tokens.css";
import "./styles/global.css";
import { createStore } from "./app/store.js";
import { createTheme } from "./app/theme.js";
import { createApiClient } from "./services/api.js";
import { createSearchController } from "./app/search-controller.js";
import { createJobController } from "./app/job-controller.js";
import { createEstimateController } from "./app/estimate-controller.js";
import { createKeysController } from "./app/keys-controller.js";
import { setPassageApi } from "./lib/media.js";
import "./components/digup-app.js";

const store = createStore({
  // The initial slice is the idle page: phase "empty" → data-page "idle", the centered
  // welcome, no list, no preview. (The vanilla state's shape, carried over.)
  results: { phase: "empty", strong: [], weaker: [], groups: [], hitsById: new Map(),
             showWeaker: false, selection: null, lastReply: null },
  filters: { kinds: [], limit: 40 },
  isCode: false,
  text: "",
  navigated: false,
  error: null,
  job: null,
  indexing: null,
  encoder: null,
  status: null,
  roots: [],
  targets: [],
  keys: null,
});

const theme = createTheme();                 // apply at boot: the theme must not flash
// The shell element is DECLARED by index.html; the entry wires THAT element. Creating a
// second one mounts a second app — the unwired twin renders its bare template above the
// working page (measured 2026-11-08: a double DigUp header). The createElement path is
// only the fallback (a host that injects the bundle without the shell markup).
let app = document.querySelector("digup-app");
if (!app) { app = document.createElement("digup-app"); document.body.append(app); }
const client = createApiClient({ onNoToken: () => app.noteMissingKey() });
app.store = store;
app.api = client.api;
app.theme = theme;

const search = createSearchController({ api: client.api, store });
const keys = createKeysController({ store, api: client.api, storage: localStorage });
const jobs = createJobController({ api: client.api, store,
  refreshStatus: () => app.refreshStatus(), loadAccess: () => keys.loadAccess() });
const estimate = createEstimateController({ api: client.api, store, storage: localStorage });
app.controllers = { search, jobs, estimate, keys };

// Transcripts ride the api client too: the bearer header belongs to services/api.js
// (the vanilla passage fetch had none — with a guarded deployment's key it works now).
setPassageApi(client.api);

// The declared element is already in the document: wiring the properties above is the
// boot (Lit schedules the first render on the microtask — the shell paints itself idle,
// focused, and starts the 15 s status poll in its firstUpdated).
