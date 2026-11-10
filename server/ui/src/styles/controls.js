// controls.js — the shared Lit `css` chunks every component imports (server/ui/AGENTS.md
// §Tokens: shared primitives live here; components import, never retype). The rules are
// the vanilla style.css carried over verbatim — same padding, borders, radii, the 2rem
// gear row system — so the built page renders pixel-identical.
import { css } from "lit";

export const controlCss = css`
  select, input[type="search"] {
    font: inherit; color: var(--text);
    border: 1px solid var(--edge); border-radius: var(--radius-md);
  }
  select { /* own arrow, evenly spaced from the edge — not glued to the button */
    appearance: none; -webkit-appearance: none;
    background: var(--field) var(--chev) right 0.6rem center / 0.85rem 0.85rem no-repeat;
    padding: 0.42rem 1.9rem 0.42rem 0.6rem;
  }
  input[type="search"] { background: var(--field); }
  input[type="checkbox"] { accent-color: var(--accent); }
  button, a.button-like {
    font: inherit; padding: 0.42rem 0.8rem; border: 1px solid var(--edge); border-radius: var(--radius-md);
    background: var(--field); color: var(--text); cursor: pointer; text-decoration: none;
    display: inline-block;
  }
  button:hover, a.button-like:hover { border-color: var(--accent); }
`;

export const badgeCss = css`
  .badge {
    display: inline-block; padding: 0.05rem 0.45rem; margin-right: 0.3rem;
    border: 1px solid var(--line); border-radius: var(--radius-pill);
    font-size: var(--text-badge); color: var(--soft); background: var(--bg);
  }
  /* The estimate's "can't read it" badge: the .warn class (defined above .badge) and .badge have
     the same specificity, so the later .badge won the cascade and the warning rendered in
     muted grey — identical to the decorative badges beside it. Two classes win on one. */
  .badge.warn { color: var(--warn); border-color: var(--warn); }
  .kind-image, .kind-screenshot { border-color: var(--kind-image); color: var(--kind-image); }
  .kind-video   { border-color: var(--kind-video); color: var(--kind-video); }
  .kind-audio   { border-color: var(--kind-audio); color: var(--kind-audio); }
  .kind-pdf, .kind-doc, .kind-code { border-color: var(--kind-doc); color: var(--kind-doc); }
  .kind-icon { min-width: 1.7rem; text-align: center; }
`;

export const activityCss = css`
  .activity { display: inline-flex; align-items: center; gap: 0.35rem; font-size: 0.8rem; color: var(--amber); }
  .activity .dot { width: 0.55rem; height: 0.55rem; border-radius: var(--radius-pill); background: var(--amber);
    animation: pulse 1.6s ease-in-out infinite; }
  @keyframes pulse { 50% { opacity: 0.35; } }
`;

export const spinCss = css`
  /* Estimate runs in the panel: a true circle — a ring with one bright quadrant,
     rotating — beside the button is the progress indicator (2026-11-08 UX brief,
     round 5: "perfectly a circle", no glyph). */
  .estimate-spin { display: inline-block; box-sizing: border-box;
    width: 1.1rem; height: 1.1rem; border-radius: 50%;
    border: 2px solid var(--edge); border-top-color: var(--accent);
    animation: spin 1.1s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
`;

export const keyRowCss = css`
  /* Gear rows are a grid: label | value | action ( | action) — every row the same height,
     the same padding, the same border; the key text clips with an ellipsis (Copy carries
     the whole value), so the panel reads as one clean stack of equal lines (2026-11-08 UX
     brief). The API key row carries Regenerate at its right edge (round-6 brief: inline,
     not a loose button under the section); label-only rows (the index rows) span full.
     Round-7 layout fix, the arithmetic: a 9rem ... auto auto grid has a hard minimum of
     ~24.6 rem (label + gaps + two padded buttons), ABOVE the ~21 rem the control column
     offers — so the row was ~120 px wider than its column and the buttons sat past the
     panel's right edge. Every column is minmax()-bounded instead: label and key shrink
     (ellipsis), the buttons keep only their word min (min-content), and min-width: 0
     lets each track collapse. The row can never exceed the column it lives in. */
  .appkey-line { display: grid; grid-template-columns: minmax(4rem, 6rem) minmax(0, 1fr)
    min-content min-content; gap: 0.4rem; align-items: center;
    min-height: var(--row-height); padding: 0.25rem 0.5rem;
    border: 1px solid var(--edge); border-radius: var(--radius-sm); background: var(--field); }
  .appkey-line > * { min-width: 0; }
  .appkey-line > .appkey-name:only-child { grid-column: 1 / -1; }
  #keys-regenerate { margin-left: auto; }
  /* Icon-only key actions (2026-11-08 UI brief, round 3): clipboard and refresh, square
     in the 2rem row system, names carried in aria-label/title (readers and tooltips). */
  .key-icon { width: var(--row-height); padding: 0; text-align: center;
    font-size: 1rem; line-height: 1; }
  .appkey-name { color: var(--soft); font-size: var(--text-xs); min-width: 0; overflow: hidden;
    text-overflow: ellipsis; white-space: nowrap; }
  /* The key lives in a real text box (2026-11-08 UI brief): selectable, copyable, and the
     clipboard + refresh buttons ride its right. A row with no label (the minted admin key
     — the section title IS its label) starts its field at the column's left edge. */
  .appkey-field { font: var(--text-xs) var(--font-mono); color: var(--text);
    background: var(--bg); border: 1px solid var(--edge); border-radius: var(--radius-sm);
    padding: 0.3rem 0.45rem; width: 100%; min-width: 0; height: var(--row-height);
    box-sizing: border-box; }
  .appkey-field:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; }
  .appkey-line > .appkey-field:first-child { grid-column: 1 / 3; }
  .appkey-token { font: var(--text-xs) var(--font-mono);
    background: var(--bg); border: 1px solid var(--edge); border-radius: var(--radius-sm);
    padding: 0.2rem 0.45rem; min-width: 0; overflow: hidden;
    text-overflow: ellipsis; white-space: nowrap; }
  .appkey-line button { white-space: nowrap; }
`;

export const jobStateCss = css`
  .job-state { padding: 0.1rem 0.5rem; border-radius: var(--radius-md); border: 1px solid var(--edge); }
  .job-queued, .job-running { color: var(--amber); }
  .job-done { color: var(--good); }
  .job-interrupted, .job-busy { color: var(--warn); }
`;

export const noteCss = css`
  .note { color: var(--soft); font-size: var(--text-sm); margin: 0.4rem 0 0; }
  .warn-text { color: var(--warn); }
`;
