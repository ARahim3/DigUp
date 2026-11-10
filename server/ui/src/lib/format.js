// format.js — the vanilla app.js's formatters, carried over verbatim. Every number the
// UI shows is the engine's (counts, seconds, scores); these only format them.
export const seconds = (s) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, "0")}`;
export const clock = (s) => (s >= 3600 ? `${Math.floor(s / 3600)}:${String(Math.floor(s / 60 % 60)).padStart(2, "0")}`
                                + `:${String(Math.floor(s % 60)).padStart(2, "0")}` : seconds(s));
export const baseName = (path) => path.split("/").pop();
export const folderOf = (path) => path.slice(0, path.lastIndexOf("/")) || "/";
export const extension = (path) => (path.split(".").pop() || "").toLowerCase();
export const bytes = (n) => (n >= 1e6 ? `${(n / 1e6).toFixed(1)} MB` : `${Math.round(n / 1e3)} KB`);
export const duration = (s) => (s >= 3600 ? `${Math.round(s / 3600)} h ${Math.round(s / 60 % 60)} min`
                               : s >= 60 ? `${Math.round(s / 60)} min ${Math.round(s % 60)} s` : `${Math.round(s)} s`);
export const date = (epoch) => new Date(epoch * 1000).toLocaleDateString(undefined, {year: "numeric", month: "short", day: "numeric"});

// The formats browsers stream themselves (H.264/AAC mp4-mov, VP8/VP9 webm, plain audio).
// Everything else keeps the desktop's honest fallback: the picture and the words here,
// the file itself through "Open", which plays it in the user's own player.
export const STREAMABLE_VIDEO = new Set(["mp4", "m4v", "mov", "webm"]);
export const STREAMABLE_AUDIO = new Set(["mp3", "wav", "ogg", "oga", "flac", "m4a", "aac"]);

export const KIND_TITLE = {screenshot: "Screenshots", image: "Images", pdf: "PDFs", doc: "Documents",
                           video: "Video", audio: "Audio", code: "Code"};

// The selectable row that folds the weaker matches (the sentinel id the arrow keys walk
// onto; the vanilla app.js's string, kept verbatim — tests pin it).
export const WEAKER = "\u0000weaker";

export function reasonOf(hit) {
  if (hit.keyword_rank !== undefined && hit.keyword_rank !== null && hit.z === undefined)
    return `keyword search: the words matched (#${hit.keyword_rank} of the keyword matches)`;
  if (hit.keyword_rank !== undefined && hit.keyword_rank !== null)
    return `meaning ${hit.z.toFixed(2)}σ · the words matched too (keyword #${hit.keyword_rank})`;
  if (hit.z !== undefined) return `meaning match: ${(hit.z).toFixed(2)}σ past the best-mix baseline`;
  return "keyword search: the words matched in it";
}

// The engine's own sentence for an empty answer, verbatim. One string, both places that
// publish it: the counter line (results) and the centered panel (none).
export const emptyAnswer = (reply) => (reply.meaning
  ? "the engine found no good matches for this and refused to guess — that is its answer"
  : "no keyword hits (meaning search is warming up)");
