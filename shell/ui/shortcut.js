// Recording a new shortcut for the panel where DigUp grabs it itself (Windows, X11): Change Shortcut… in Settings and
// in setup. The current one is let go meanwhile, so that pressing it reaches the page instead of opening the panel.
"use strict";

/// Records the next key pressed with Ctrl, Alt or the Windows key. `say` shows what to do; `done` gets the shortcut as
/// it's shown (null when it was kept: Esc, the window left, or the new one refused, with `problem` saying why).
function recordShortcut(say, done) {
  const call = (command, args) => window.__TAURI__.core.invoke(command, args);
  say("Press the new shortcut. Esc keeps the one you have.");
  call("hold_hotkey", { held: true }).catch(() => {});
  const finish = async (accelerator) => {
    document.removeEventListener("keydown", pressed, true);
    window.removeEventListener("blur", left);
    let shown = null, problem = null;
    if (accelerator) {
      try {
        shown = await call("set_hotkey", { hotkey: accelerator });
      } catch (error) {
        problem = String(error);
      }
    }
    call("hold_hotkey", { held: false }).catch(() => {});   // the one there was, if it's still the one
    done(shown, problem);
  };
  const pressed = (event) => {
    event.preventDefault();
    event.stopPropagation();   // the page's own keys (setup's Enter) wait
    if (event.key === "Escape") return finish(null);
    const key = shortcutKeyName(event.code);
    if (!key) return;   // a modifier alone, so far
    if (!event.ctrlKey && !event.altKey && !event.metaKey) {
      say("Add Ctrl, Alt or the Windows key, so that typing doesn't open the panel.");
      return;
    }
    finish([event.ctrlKey && "Ctrl", event.altKey && "Alt", event.shiftKey && "Shift", event.metaKey && "Super", key]
      .filter(Boolean).join("+"));
  };
  const left = () => finish(null);
  document.addEventListener("keydown", pressed, true);
  window.addEventListener("blur", left);
}

/// A key's name as shortcuts spell it ("D", "5", "Space", "F5", "Up"), from where it is on the keyboard; none for a
/// modifier.
function shortcutKeyName(code) {
  if (/^Key[A-Z]$/.test(code)) return code.slice(3);
  if (/^Digit\d$/.test(code)) return code.slice(5);
  if (/^F\d{1,2}$/.test(code)) return code;
  const names = { Space: "Space", ArrowUp: "Up", ArrowDown: "Down", ArrowLeft: "Left", ArrowRight: "Right",
                  Enter: "Enter", Tab: "Tab", Backspace: "Backspace", Delete: "Delete", Home: "Home", End: "End",
                  PageUp: "PageUp", PageDown: "PageDown", Insert: "Insert", Backquote: "Backquote", Minus: "Minus",
                  Equal: "Equal", Comma: "Comma", Period: "Period", Slash: "Slash", Semicolon: "Semicolon",
                  Quote: "Quote", BracketLeft: "BracketLeft", BracketRight: "BracketRight", Backslash: "Backslash" };
  return names[code] || null;
}
