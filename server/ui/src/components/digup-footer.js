// digup-footer — the summary line: the engine's counts and states, assembled exactly
// as the vanilla renderFooter assembled them (the keys hint rides beside it in the
// shell's static footer markup). "The server's helper: <error>" for a failed search;
// the indexing counts while a job runs.
import { LitElement, html, css } from "lit";

class DigupFooter extends LitElement {
  static properties = { results: {}, indexing: {}, error: {} };

  static styles = css`
    :host { display: inline; }
    .error { color: var(--warn); }
  `;

  render() {
    const r = this.results || { strong: [], weaker: [] };
    let summary;
    if (this.error) summary = `The server's helper: ${this.error}`;
    else if (r.phase === "words") summary = "Matching words…";
    else if (r.phase === "wordsOnly") summary = "Words only: meaning search isn't available";
    else if (r.phase === "codeHint") summary = "Searching your code";
    else if (r.phase === "empty") summary = "";
    else summary = `${r.strong.length} ${r.strong.length === 1 ? "result" : "results"}`
                 + (r.weaker.length ? ` · ${r.weaker.length} weaker` : "");
    if (this.indexing) {
      const j = this.indexing;
      summary = (summary ? summary + " · " : "")
        + `indexing ${j.state}${j.files_done ? ` ${j.files_done}` : ""}${j.files ? `/${j.files}` : ""}`
        + (j.searchable !== undefined && j.searchable !== null ? ` · searchable ${j.searchable}` : "");
    }
    return html`<span class=${this.error ? "error" : ""}>${summary}</span>`;
  }
}
if (!customElements.get("digup-footer")) customElements.define("digup-footer", DigupFooter);
