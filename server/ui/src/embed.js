// embed.js — the embed widget's entry (embed.html; stage-12-integrations.md §11.4):
// the host's read token arrives via ?token=, moves to sessionStorage, and the URL line
// is rewritten (history.replaceState) so the secret never lands in bookmarks, history,
// or the host app's logs — the vanilla embed.js boot, carried over verbatim. The
// params (limit, q, theme) hand off to <digup-embed>, which owns the widget's loop.
import "./styles/tokens.css";
import "./styles/embed.css";
import { createEmbedApi } from "./services/api.js";
import "./components/digup-embed.js";

const params = new URLSearchParams(location.search);
const client = createEmbedApi();
if (params.get("token")) {
  client.adoptUrlToken(params.get("token"));
  params.delete("token");                    // strip the secret from the visible URL line
  const rest = params.toString();
  history.replaceState(null, "", location.pathname + (rest ? "?" + rest : ""));
}

// embed.html DECLARES the widget; the entry wires that element (a second createElement
// would mount an unwired twin above the working widget — the double page the full UI had
// the same way, measured 2026-11-08). The createElement path is the fallback only.
let widget = document.querySelector("digup-embed");
if (!widget) { widget = document.createElement("digup-embed"); document.body.append(widget); }
widget.api = client;
widget.params = params;
