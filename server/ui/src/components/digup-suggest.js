// digup-suggest — the idle suggestions: a click puts the phrase in the field and
// searches it — the exact path a typed query takes (the ONE search route via
// digup:set-query → the shell → digup-search.setValue; nothing here duplicates it).
// These are examples of *how to describe* a file, not promises about a library: they
// describe scenes, which is what the engine's meaning search answers.
import { LitElement, html, css } from "lit";

class DigupSuggest extends LitElement {
  static properties = { phrases: {} };

  static styles = css`
    :host { display: flex; gap: 0.5rem; flex-wrap: wrap; justify-content: center; margin-top: 1rem; }
    button { border: 1px solid var(--edge); border-radius: var(--radius-pill);
      padding: 0.3rem 0.8rem; font: inherit; font-size: 0.85rem;
      background: var(--field); color: var(--text); cursor: pointer; }
    button:hover { border-color: var(--accent); }
  `;

  render() {
    return (this.phrases || []).map((phrase) => html`
      <button type="button" @click=${() => this.dispatchEvent(new CustomEvent("digup:set-query",
        { bubbles: true, composed: true, detail: { phrase } }))}>${phrase}</button>`);
  }
}
if (!customElements.get("digup-suggest")) customElements.define("digup-suggest", DigupSuggest);
