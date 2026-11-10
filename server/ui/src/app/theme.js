// theme.js — appearance: system / light / dark, kept in this browser (the desktop
// follows the OS; a server has no OS to follow, so the choice is the user's, per
// browser). The vanilla app.js rule, verbatim: html[data-theme] + localStorage.
export function createTheme({ storage = localStorage, key = "digup-theme" } = {}) {
  function apply(choice) {
    document.documentElement.dataset.theme = choice;
    storage.setItem(key, choice);
  }
  const current = () => storage.getItem(key) || "system";
  apply(current());                       // apply at boot: the theme must not flash
  return { apply, current };
}
