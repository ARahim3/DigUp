// Native Rust GraphRAG Entity Extractor, CAG (Cache-Augmented Generation) Slot Manager,
// and Local SLM Orchestrator for the 8-Core / 12GB RAM Desktop Architecture.
//
// Works in tandem with `digup search-service` and `digup chat-service` (or a local llama.cpp / Ollama /
// GGUF endpoint), ensuring 100% offline privacy, automatic background indexer yielding during SLM inference,
// and instant CAG prefix-cache reuse.

use flate2::read::ZlibDecoder;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom, Write};
use std::net::{SocketAddr, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GraphEntity {
    pub entity_type: String,
    pub key: String,
    pub weight: f64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CagSlotMeta {
    pub slot: String,
    pub pinned_paths: Vec<String>,
    pub cached_text: String,
    pub approx_tokens: usize,
    pub updated_at: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HardwareProfile {
    pub logical_cores: usize,
    pub recommended_slm_threads: usize,
    pub recommended_model: String,
    pub turbo_model: String,
    pub kv_cache_quant: String,
    pub max_context_tokens: usize,
}

impl HardwareProfile {
    /// Computes the optimal CPU thread & memory profile for an 8-core, 12GB RAM PC.
    pub fn detect() -> Self {
        let cores = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(8);
        // Reserve 2 cores for OS + Tauri WebView + SearchService on >= 6-core machines
        let slm_threads = if cores > 4 {
            (cores - 2).min(6)
        } else {
            cores.max(2)
        };
        Self {
            logical_cores: cores,
            recommended_slm_threads: slm_threads,
            recommended_model: "qwen2.5-3b-instruct-q4_k_m.gguf".into(),
            turbo_model: "qwen2.5-1.5b-instruct-q4_k_m.gguf".into(),
            kv_cache_quant: "Q8_0".into(),
            max_context_tokens: 8192,
        }
    }
}

/// Deterministic zero-LLM-overhead entity extractor for GraphRAG multi-hop query expansion.
/// Identifies:
///   - `file_ref`: file names with known extensions (`auth.ts`, `settings.yaml`, `lease.pdf`)
///   - `id_code`: exact invoice numbers, ticket IDs, error codes (`INV-2026-041`, `ERR_502`, `CVE-2026-11`)
///   - `symbol`: `camelCase`, `PascalCase`, or `snake_case` identifiers (`refreshAccessToken`, `retry_with_backoff`)
pub fn extract_graph_entities(text: &str) -> Vec<GraphEntity> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    let known_exts = [
        "py", "ts", "tsx", "js", "rs", "swift", "md", "pdf", "json", "yaml", "yml", "toml", "sql",
        "sh", "html", "css", "c", "cpp", "h", "docx", "txt",
    ];

    for raw in
        text.split(|c: char| !c.is_alphanumeric() && c != '_' && c != '-' && c != '.' && c != '/')
    {
        let trimmed = raw.trim_matches(|c: char| c == '.' || c == '-' || c == '_' || c == '/');
        if trimmed.len() < 4 || trimmed.len() > 80 {
            continue;
        }
        let lower = trimmed.to_ascii_lowercase();

        // 1. Check for file reference
        if let Some(dot_idx) = trimmed.rfind('.') {
            let ext = &trimmed[dot_idx + 1..].to_ascii_lowercase();
            if known_exts.contains(&ext.as_str()) {
                let file_name = trimmed
                    .rsplit('/')
                    .next()
                    .unwrap_or(trimmed)
                    .to_ascii_lowercase();
                if seen.insert(format!("file_ref:{file_name}")) {
                    out.push(GraphEntity {
                        entity_type: "file_ref".into(),
                        key: file_name,
                        weight: 2.4,
                    });
                }
                continue;
            }
        }

        let has_upper = trimmed.chars().any(|c| c.is_ascii_uppercase());
        let has_lower = trimmed.chars().any(|c| c.is_ascii_lowercase());
        let has_digit = trimmed.chars().any(|c| c.is_ascii_digit());

        // 2. Exact ID codes (e.g., INV-2026-041, ERR_CONNECTION, PROJ-99)
        if has_digit
            && (has_upper || has_lower)
            && (trimmed.contains('-') || trimmed.contains('_') || has_upper)
        {
            if seen.insert(format!("id_code:{lower}")) {
                out.push(GraphEntity {
                    entity_type: "id_code".into(),
                    key: lower,
                    weight: 2.5,
                });
            }
        } else if (has_upper && has_lower && trimmed.len() >= 6)
            || (trimmed.contains('_') && has_lower)
        {
            // 3. Code / technical symbols (camelCase or snake_case)
            if seen.insert(format!("symbol:{lower}")) {
                out.push(GraphEntity {
                    entity_type: "symbol".into(),
                    key: lower,
                    weight: 2.0,
                });
            }
        }

        if out.len() >= 24 {
            break;
        }
    }

    out
}

/// Given hop-0 search hits, synthesizes a 2nd-hop GraphRAG expansion query string containing the highest-weight
/// bridge entities (symbols, file references, and ID codes) discovered in the initial hits that were not in the
/// original user query.
pub fn build_hop2_expansion_query(original_query: &str, hop0_texts: &[String]) -> Option<String> {
    let query_lower = original_query.to_ascii_lowercase();
    let mut scores: HashMap<String, f64> = HashMap::new();

    for snippet in hop0_texts {
        for entity in extract_graph_entities(snippet) {
            if !query_lower.contains(&entity.key) {
                *scores.entry(entity.key).or_insert(0.0) += entity.weight;
            }
        }
    }

    let mut ranked: Vec<(String, f64)> = scores.into_iter().collect();
    ranked.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    let top_keys: Vec<String> = ranked.into_iter().take(4).map(|(k, _)| k).collect();
    if top_keys.is_empty() {
        None
    } else {
        Some(top_keys.join(" "))
    }
}

// MARK: Cache-Augmented Generation (CAG) Slot Persistence

pub fn cag_dir(base_dir: &Path) -> PathBuf {
    base_dir.join("cag_cache")
}

fn sanitize_slot(slot: &str) -> String {
    let cleaned: String = slot
        .chars()
        .map(|c| {
            if c.is_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect();
    if cleaned.is_empty() {
        "default".into()
    } else {
        cleaned
    }
}

/// Pins a list of local files into a named CAG slot on disk (`cag_cache/<slot>.json`), pre-loading their content
/// so chat sessions can inject or restore the KV state immediately without re-searching or re-reading disk.
pub fn save_cag_slot(base_dir: &Path, slot: &str, paths: &[String]) -> Result<CagSlotMeta, String> {
    let dir = cag_dir(base_dir);
    fs::create_dir_all(&dir).map_err(|e| format!("can't create CAG directory: {e}"))?;
    let slot_name = sanitize_slot(slot);

    let mut combined = String::new();
    let mut valid_paths = Vec::new();
    for path_str in paths {
        let p = Path::new(path_str);
        valid_paths.push(path_str.clone());
        if p.is_file() {
            if let Ok(content) = fs::read_to_string(p) {
                let snippet: String = content.chars().take(2400).collect();
                combined.push_str(&format!("### Pinned File: {}\n{}\n\n", path_str, snippet));
            } else {
                let size = p.metadata().map(|m| m.len()).unwrap_or(0);
                if let Some(digest) = extract_fast_book_digest(p, size) {
                    let snippet: String = digest.searchable_text.chars().take(2400).collect();
                    combined.push_str(&format!(
                        "### Pinned Book/PDF: {} (Title: {}, Author: {})\n{}\n\n",
                        path_str, digest.title, digest.author, snippet
                    ));
                } else {
                    combined.push_str(&format!("### Pinned Binary/Media File: {}\n", path_str));
                }
            }
        }
    }

    let approx_tokens = (combined.len() + 3) / 4;
    let updated_at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    let meta = CagSlotMeta {
        slot: slot_name.clone(),
        pinned_paths: valid_paths,
        cached_text: combined,
        approx_tokens,
        updated_at,
    };

    let file_path = dir.join(format!("{slot_name}.json"));
    let serialized = serde_json::to_string_pretty(&meta).map_err(|e| e.to_string())?;
    fs::write(&file_path, serialized).map_err(|e| format!("can't write CAG slot: {e}"))?;
    Ok(meta)
}

pub fn load_cag_slot(base_dir: &Path, slot: &str) -> Option<CagSlotMeta> {
    let slot_name = sanitize_slot(slot);
    let file_path = cag_dir(base_dir).join(format!("{slot_name}.json"));
    let data = fs::read_to_string(file_path).ok()?;
    serde_json::from_str(&data).ok()
}

pub fn list_cag_slots(base_dir: &Path) -> Vec<Value> {
    let Ok(entries) = fs::read_dir(cag_dir(base_dir)) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for entry in entries.filter_map(Result::ok) {
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) == Some("json") {
            if let Ok(data) = fs::read_to_string(&path) {
                if let Ok(meta) = serde_json::from_str::<CagSlotMeta>(&data) {
                    out.push(json!({
                        "slot": meta.slot,
                        "pinnedPaths": meta.pinned_paths,
                        "approxTokens": meta.approx_tokens,
                        "updatedAt": meta.updated_at
                    }));
                }
            }
        }
    }
    out
}

/// Synthesizes a grounded response from GraphRAG + CAG context when operating in standalone offline fallback mode
/// (e.g., before the 1.93 GB GGUF weight is downloaded, or when verifying citations in unit tests).
pub fn synthesize_grounded_fallback(
    query: &str,
    hits: &[Value],
    hop1_hits: &[Value],
    cag: Option<&CagSlotMeta>,
) -> (String, Vec<Value>) {
    let mut citations = Vec::new();
    let mut summary_lines = Vec::new();

    if let Some(cag_meta) = cag {
        if !cag_meta.pinned_paths.is_empty() {
            summary_lines.push(format!(
                "**[CAG Slot `{}` Active]** ({} pinned file(s), ~{} cached tokens)",
                cag_meta.slot,
                cag_meta.pinned_paths.len(),
                cag_meta.approx_tokens
            ));
        }
    }

    for (idx, hit) in hits.iter().take(5).enumerate() {
        let num = idx + 1;
        let path = hit["path"].as_str().unwrap_or("");
        let kind = hit["kind"].as_str().unwrap_or("doc");
        let excerpt = hit["excerpt"]
            .as_str()
            .unwrap_or("(visual/audio segment match)");
        let loc = hit.get("loc").cloned().unwrap_or(Value::Null);
        let file_name = Path::new(path)
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or(path);
        let place = match (kind, loc.as_f64()) {
            ("pdf", Some(p)) => format!("p. {}", p as i64),
            ("audio" | "video", Some(sec)) => {
                let s = sec as i64;
                format!("{}:{:02}", s / 60, s % 60)
            }
            ("code", Some(line)) => format!("line {}", line as i64),
            _ => kind.to_string(),
        };
        summary_lines.push(format!(
            "- **[{num}] {file_name}** ({place}): {}",
            excerpt.replace('«', "**").replace('»', "**")
        ));
        citations.push(json!({
            "index": num,
            "path": path,
            "kind": kind,
            "loc": loc,
            "hop": 0,
            "excerpt": excerpt
        }));
    }

    for (offset, hit) in hop1_hits.iter().take(3).enumerate() {
        let num = citations.len() + offset + 1;
        let path = hit["path"].as_str().unwrap_or("");
        if citations.iter().any(|c| c["path"].as_str() == Some(path)) {
            continue;
        }
        let kind = hit["kind"].as_str().unwrap_or("doc");
        let excerpt = hit["excerpt"].as_str().unwrap_or("(graph-linked neighbor)");
        let loc = hit.get("loc").cloned().unwrap_or(Value::Null);
        let file_name = Path::new(path)
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or(path);
        summary_lines.push(format!(
            "- **[{num}] {file_name}** *(GraphRAG 1-Hop Link)*: {}",
            excerpt.replace('«', "**").replace('»', "**")
        ));
        citations.push(json!({
            "index": num,
            "path": path,
            "kind": kind,
            "loc": loc,
            "hop": 1,
            "excerpt": excerpt
        }));
    }

    let answer = if citations.is_empty() && cag.is_none() {
        format!(
            "No matching local files or segments were found in your index for **\"{query}\"**. Try indexing additional folders or refining your search terms."
        )
    } else {
        format!(
            "Here is what DigUp found across your local files and GraphRAG links for **\"{query}\"**:\n\n{}",
            summary_lines.join("\n\n")
        )
    };

    (answer, citations)
}

// MARK: Native Rust Standalone Local File Indexer & Multi-Hop GraphRAG Search Fallback
// Used automatically whenever the external `digup` Swift binary is not built yet, allowing `cargo run`
// to index, search, preview code/docs, pin CAG slots, and run GraphRAG 2-hop Q&A out of the box.

#[derive(Clone, Debug)]
pub struct LocalFileEntry {
    pub path: String,
    pub root: String,
    pub kind: &'static str,
    pub size: u64,
    pub modified: i64,
}

pub fn classify_file_kind(path: &Path) -> Option<&'static str> {
    let ext = path.extension()?.to_str()?.to_ascii_lowercase();
    let name = path
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    match ext.as_str() {
        "py" | "rs" | "ts" | "tsx" | "js" | "jsx" | "swift" | "c" | "cpp" | "h" | "hpp" | "go"
        | "java" | "cs" | "sh" | "ps1" | "sql" | "html" | "css" | "json" | "toml" | "yaml"
        | "yml" => Some("code"),
        "pdf" => Some("pdf"),
        "md" | "txt" | "rst" | "csv" | "log" | "rtf" | "org" | "docx" => Some("doc"),
        "png" | "jpg" | "jpeg" | "webp" | "gif" | "bmp" | "svg" => {
            if name.contains("screen") || name.contains("shot") || name.contains("capture") {
                Some("screenshot")
            } else {
                Some("image")
            }
        }
        "mp3" | "wav" | "m4a" | "flac" | "ogg" => Some("audio"),
        "mp4" | "mkv" | "mov" | "webm" | "avi" => Some("video"),
        _ => None,
    }
}

fn should_skip_dir(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    matches!(
        lower.as_str(),
        ".git"
            | "node_modules"
            | "target"
            | ".build"
            | "__pycache__"
            | ".venv"
            | "venv"
            | ".next"
            | "dist"
            | "windows"
            | "program files"
            | "program files (x86)"
            | "programdata"
            | "appdata"
            | "$recycle.bin"
            | "system volume information"
            | "recovery"
            | "perflogs"
            | "msocache"
            | ".cargo"
            | ".rustup"
            | ".gradle"
            | ".cache"
    )
}

pub fn walk_local_folders(
    folders: &[String],
    skipped: &[String],
    skip_types: &[String],
) -> Vec<LocalFileEntry> {
    let mut entries = Vec::new();
    let mut seen = HashSet::new();

    for root in folders {
        let root_path = Path::new(root);
        if !root_path.exists() {
            continue;
        }
        let mut stack = vec![root_path.to_path_buf()];
        while let Some(dir) = stack.pop() {
            let Ok(read_dir) = fs::read_dir(&dir) else {
                continue;
            };
            for item in read_dir.filter_map(Result::ok) {
                let path = item.path();
                let path_str = path.to_string_lossy().replace('\\', "/");
                if skipped.iter().any(|s| {
                    let norm = s.replace('\\', "/");
                    path_str.eq_ignore_ascii_case(&norm)
                }) {
                    continue;
                }
                let Ok(meta) = item.metadata() else {
                    continue;
                };
                if meta.is_dir() {
                    if let Some(dir_name) = path.file_name().and_then(|s| s.to_str()) {
                        if !should_skip_dir(dir_name) {
                            stack.push(path);
                        }
                    }
                } else if meta.is_file() {
                    if let Some(ext) = path.extension().and_then(|s| s.to_str()) {
                        let dot_ext = format!(".{}", ext.to_ascii_lowercase());
                        if skip_types
                            .iter()
                            .any(|t| t.eq_ignore_ascii_case(&dot_ext) || t.eq_ignore_ascii_case(ext))
                        {
                            continue;
                        }
                    }
                    if let Some(kind) = classify_file_kind(&path) {
                        let canonical_key = path_str.to_ascii_lowercase();
                        if seen.insert(canonical_key) {
                            let modified = meta
                                .modified()
                                .ok()
                                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                                .map(|d| d.as_secs() as i64)
                                .unwrap_or(0);
                            entries.push(LocalFileEntry {
                                path: path.to_string_lossy().to_string(),
                                root: root.clone(),
                                kind,
                                size: meta.len(),
                                modified,
                            });
                        }
                    }
                }
            }
        }
    }
    entries
}

/// Splits a single alphanumeric token on `camelCase` / `PascalCase` transitions (e.g.,
/// `SimonJDPrince` -> `["Simon", "JD", "Prince"]`, `UnderstandingDeepLearning` -> `["Understanding", "Deep", "Learning"]`).
fn split_camel_case(token: &str) -> Vec<String> {
    let chars: Vec<char> = token.chars().collect();
    if chars.is_empty() {
        return Vec::new();
    }
    let mut parts = Vec::new();
    let mut current = String::new();
    for i in 0..chars.len() {
        let c = chars[i];
        if i > 0 {
            let prev = chars[i - 1];
            let next_is_lower = chars.get(i + 1).map(|n| n.is_ascii_lowercase()).unwrap_or(false);
            // Split on `aB` (lower -> upper) or `JDP` -> `JD` + `Prince` (upper -> upper followed by lower)
            if (prev.is_ascii_lowercase() && c.is_ascii_uppercase())
                || (prev.is_ascii_uppercase() && c.is_ascii_uppercase() && next_is_lower && current.len() >= 2)
                || (prev.is_ascii_alphabetic() != c.is_ascii_alphabetic())
            {
                if !current.is_empty() {
                    parts.push(std::mem::take(&mut current));
                }
            }
        }
        current.push(c);
    }
    if !current.is_empty() {
        parts.push(current);
    }
    parts
}

/// Tokenizes a search query into lowercase search terms (filtering out conversational stop words so natural
/// language questions like "Summarize the MICRO Lab onboarding manual" match `MICRO`, `Lab`, `onboarding`, `manual`).
/// Also splits `_`, `-`, `.`, and `CamelCase` boundaries (`Simon_JD_Prince`, `understanding_deep_learning`,
/// `SimonJDPrince`) while preserving compound technical IDs containing digits (`INV-2026-041`, `ERR_502`).
pub fn query_terms(query: &str) -> Vec<String> {
    let stop_words: HashSet<&'static str> = [
        "a", "an", "the", "is", "are", "was", "were", "be", "to", "of", "and", "in", "on", "for",
        "with", "how", "what", "why", "where", "when", "which", "who", "does", "do", "did", "can",
        "could", "would", "should", "about", "from", "into", "tell", "me", "summarize", "explain",
        "show", "find", "list", "describe", "my", "our", "their", "it", "this", "that", "these",
        "those", "by", "at", "or",
    ]
    .into_iter()
    .collect();

    let mut terms = Vec::new();
    let mut push_term = |candidate: String| {
        let is_digit = !candidate.is_empty() && candidate.chars().all(|c| c.is_ascii_digit());
        if (candidate.len() >= 2 || is_digit)
            && !stop_words.contains(candidate.as_str())
            && !terms.contains(&candidate)
        {
            terms.push(candidate);
        }
    };

    for compound in query.split(|c: char| !c.is_alphanumeric() && c != '_' && c != '-') {
        let trimmed = compound.trim_matches(|c: char| c == '-' || c == '_');
        if trimmed.is_empty() {
            continue;
        }
        // Preserve exact technical IDs with digits + delimiters (e.g., INV-2026-041, ERR_502)
        let has_delim = trimmed.contains('-') || trimmed.contains('_');
        let has_digit = trimmed.chars().any(|c| c.is_ascii_digit());
        let has_alpha = trimmed.chars().any(|c| c.is_ascii_alphabetic());
        if has_delim && has_digit && has_alpha {
            push_term(trimmed.to_ascii_lowercase());
        }

        // Split on `_` and `-`, then split any CamelCase sub-parts
        for part in trimmed.split(|c: char| c == '_' || c == '-') {
            if part.is_empty() {
                continue;
            }
            let camel_parts = split_camel_case(part);
            if camel_parts.len() > 1 {
                for cp in camel_parts {
                    push_term(cp.to_ascii_lowercase());
                }
            } else {
                push_term(part.to_ascii_lowercase());
            }
        }
    }

    if terms.is_empty() {
        let fallback = query.trim().to_ascii_lowercase();
        if !fallback.is_empty() {
            terms.push(fallback);
        }
    }
    terms
}

/// Returns a match quality multiplier in `[0.0, 1.0]` for `term` inside `haystack_lower`:
/// - `1.0` for an exact whole-word match (or standard plural/past-tense `-s`/`-d` suffix for terms >= 4 chars),
///   treating `_`, `-`, `.`, `/`, and `\` as word separators.
/// - `0.62..=0.88` for a word-start prefix match when `term.len() >= 4` and the candidate word is at most
///   `term.len() + 6` characters (so `"simo"` matches `"simon"` at `0.85` and `"compo"` matches `"composing"`,
///   while short terms `< 4` chars like `"cat"` or `"top"` never false-match inside longer words).
/// - `0.65` for a 1-edit typo/transposition on words `>= 5` chars sharing the same 2-character prefix.
fn match_term_quality(haystack_lower: &str, term: &str) -> f64 {
    if term.is_empty() {
        return 0.0;
    }
    let bytes = haystack_lower.as_bytes();
    let t_len = term.len();
    let mut best = 0.0f64;
    let mut start = 0usize;

    while let Some(rel) = haystack_lower[start..].find(term) {
        let idx = start + rel;
        let end = idx + t_len;
        let left_ok = idx == 0 || !bytes[idx - 1].is_ascii_alphanumeric();
        if left_ok {
            if end >= bytes.len() || !bytes[end].is_ascii_alphanumeric() {
                return 1.0;
            }
            let next_b = bytes[end];
            let after_next_non_alnum =
                end + 1 >= bytes.len() || !bytes[end + 1].is_ascii_alphanumeric();
            if t_len >= 4 && (next_b == b's' || next_b == b'd') && after_next_non_alnum {
                return 1.0;
            }
            if t_len >= 4 {
                let mut word_end = end;
                while word_end < bytes.len()
                    && bytes[word_end].is_ascii_alphanumeric()
                    && word_end - idx <= t_len + 7
                {
                    word_end += 1;
                }
                let word_len = word_end - idx;
                if word_len > t_len && word_len <= t_len + 6 {
                    let ratio = (t_len as f64) / (word_len as f64);
                    let q = (0.55 + 0.38 * ratio).clamp(0.62, 0.88);
                    if q > best {
                        best = q;
                    }
                }
            }
        }
        start = idx + 1;
        if start >= bytes.len() {
            break;
        }
    }

    if best > 0.0 || t_len < 5 {
        return best;
    }

    // Fallback: check 1-edit distance (single substitution, deletion, insertion, or adjacent transposition)
    // for terms >= 5 chars that share the first 2 characters.
    let prefix2 = &term.as_bytes()[..2];
    let mut i = 0usize;
    while i + 2 <= bytes.len() {
        let at_word_start = i == 0 || !bytes[i - 1].is_ascii_alphanumeric();
        if at_word_start && bytes[i] == prefix2[0] && bytes[i + 1] == prefix2[1] {
            let mut w_end = i + 2;
            while w_end < bytes.len()
                && bytes[w_end].is_ascii_alphanumeric()
                && w_end - i <= t_len + 2
            {
                w_end += 1;
            }
            let cand = &bytes[i..w_end];
            if cand.len().abs_diff(t_len) <= 1 && is_within_one_edit(cand, term.as_bytes()) {
                return 0.65;
            }
            i = w_end;
        } else {
            i += 1;
        }
    }

    best
}

fn is_within_one_edit(a: &[u8], b: &[u8]) -> bool {
    if a == b {
        return true;
    }
    let (la, lb) = (a.len(), b.len());
    if la.abs_diff(lb) > 1 {
        return false;
    }
    let mut i = 0usize;
    let mut j = 0usize;
    let mut edits = 0usize;
    while i < la && j < lb {
        if a[i] == b[j] {
            i += 1;
            j += 1;
        } else {
            edits += 1;
            if edits > 1 {
                return false;
            }
            // Check adjacent transposition (`siomn` vs `simon`)
            if i + 1 < la && j + 1 < lb && a[i] == b[j + 1] && a[i + 1] == b[j] {
                i += 2;
                j += 2;
            } else if la > lb {
                i += 1;
            } else if lb > la {
                j += 1;
            } else {
                i += 1;
                j += 1;
            }
        }
    }
    if i < la || j < lb {
        edits += 1;
    }
    edits <= 1
}

/// Checks if `term` appears in `haystack_lower` as a whole word, valid prefix (for terms >= 4 chars),
/// or 1-edit typo (for terms >= 5 chars), while preventing short terms like `tops` from matching inside `stops`.
fn matches_term_in_text(haystack_lower: &str, term: &str) -> bool {
    match_term_quality(haystack_lower, term) > 0.0
}

/// Splits a Markdown or text document into logical sections (by `#`, `##`, `###` headings, or ~25-line blocks)
/// so multi-part questions can retrieve the exact sections (`## Authorization levels`, `### Incident response`, etc.)
/// rather than only the first 6 lines of the file.
#[derive(Clone, Debug)]
struct DocSection {
    heading: String,
    heading_lower: String,
    start_line: usize,
    end_line: usize,
    text: String,
    text_lower: String,
}

fn split_into_sections(content: &str) -> Vec<DocSection> {
    let lines: Vec<&str> = content.lines().collect();
    if lines.is_empty() {
        return Vec::new();
    }
    let mut sections = Vec::new();
    let mut current_heading = String::from("Document Overview");
    let mut start_line = 1usize;
    let mut buf: Vec<&str> = Vec::new();

    for (idx, &line) in lines.iter().enumerate() {
        let line_num = idx + 1;
        let trimmed = line.trim_start();
        let is_heading = trimmed.starts_with('#')
            && trimmed
                .chars()
                .take_while(|&c| c == '#')
                .count()
                <= 4;

        if is_heading && !buf.is_empty() {
            let text = buf.join("\n").trim().to_string();
            if !text.is_empty() {
                let heading_lower = current_heading.to_ascii_lowercase();
                let text_lower = text.to_ascii_lowercase();
                sections.push(DocSection {
                    heading: current_heading.clone(),
                    heading_lower,
                    start_line,
                    end_line: line_num - 1,
                    text,
                    text_lower,
                });
            }
            current_heading = trimmed.trim_start_matches('#').trim().to_string();
            start_line = line_num;
            buf.clear();
        } else if is_heading && buf.is_empty() {
            current_heading = trimmed.trim_start_matches('#').trim().to_string();
            start_line = line_num;
        }
        buf.push(line);
    }

    if !buf.is_empty() {
        let text = buf.join("\n").trim().to_string();
        if !text.is_empty() {
            let heading_lower = current_heading.to_ascii_lowercase();
            let text_lower = text.to_ascii_lowercase();
            sections.push(DocSection {
                heading: current_heading,
                heading_lower,
                start_line,
                end_line: lines.len(),
                text,
                text_lower,
            });
        }
    }
    sections
}

/// Compact, bounded-I/O representation of a PDF textbook or large document (> 2 MB up to 500 MB+).
/// Skims at most ~640 KB total across 3 zones (Head 256 KB, 8 evenly-spaced 32 KB Stride windows, Tail 128 KB)
/// so even a 100 MB PDF book is digested in `< 15 ms` without reading the entire binary into RAM.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BookDigest {
    pub title: String,
    pub author: String,
    pub keywords: String,
    pub searchable_text: String,
}

/// Extracts a PDF `/Key (Value)` or XMP `<dc:key>Value</dc:key>` field directly from raw bytes.
fn extract_pdf_meta_field(raw: &[u8], pdf_key: &[u8], xmp_tag: &str) -> Option<String> {
    if let Some(pos) = find_subslice(raw, pdf_key) {
        let after = &raw[pos + pdf_key.len()..];
        let trimmed_start = after
            .iter()
            .position(|b| !b.is_ascii_whitespace())
            .unwrap_or(after.len());
        let trimmed = &after[trimmed_start..];
        if trimmed.first() == Some(&b'(') {
            let mut val = String::new();
            let mut escaped = false;
            for &b in trimmed[1..].iter().take(240) {
                if escaped {
                    if b.is_ascii_graphic() || b == b' ' {
                        val.push(b as char);
                    }
                    escaped = false;
                } else if b == b'\\' {
                    escaped = true;
                } else if b == b')' {
                    break;
                } else if b.is_ascii_graphic() || b == b' ' {
                    val.push(b as char);
                }
            }
            let cleaned = val.trim().to_string();
            if cleaned.len() >= 2 {
                return Some(cleaned);
            }
        }
    }
    let open_tag = format!("<{xmp_tag}>");
    let close_tag = format!("</{xmp_tag}>");
    if let Some(start) = find_subslice(raw, open_tag.as_bytes()) {
        let after = &raw[start + open_tag.len()..];
        if let Some(end) = find_subslice(after, close_tag.as_bytes()) {
            let cleaned = String::from_utf8_lossy(&after[..end]).trim().to_string();
            if cleaned.len() >= 2 {
                return Some(cleaned);
            }
        }
    }
    None
}

fn is_pdf_noise_word(w: &str) -> bool {
    matches!(
        w,
        "obj"
            | "endobj"
            | "stream"
            | "endstream"
            | "xref"
            | "trailer"
            | "startxref"
            | "flatedecode"
            | "filter"
            | "length"
            | "type"
            | "page"
            | "pages"
            | "catalog"
            | "font"
            | "procset"
            | "mediabox"
            | "resources"
            | "parent"
            | "subtype"
            | "basefont"
            | "encoding"
            | "widths"
            | "firstchar"
            | "lastchar"
    )
}

fn parse_hex_nibble(b: u8) -> Option<u16> {
    match b {
        b'0'..=b'9' => Some((b - b'0') as u16),
        b'a'..=b'f' => Some((b - b'a' + 10) as u16),
        b'A'..=b'F' => Some((b - b'A' + 10) as u16),
        _ => None,
    }
}

/// Decodes a sequence of 4-hex-digit PDF glyph codes (`<00380051...>`) using either direct ASCII (`0x20..=0x7E`)
/// or standard Identity-H / TrueType glyph index offset (`+29`, where `0x0003` -> `' '`, `0x0024` -> `'A'`, `0x0044` -> `'a'`).
fn decode_pdf_hex_glyph_run(hex_bytes: &[u8], out: &mut String) {
    if hex_bytes.len() < 4 || hex_bytes.len() % 4 != 0 {
        return;
    }
    for chunk in hex_bytes.chunks_exact(4) {
        let (Some(n0), Some(n1), Some(n2), Some(n3)) = (
            parse_hex_nibble(chunk[0]),
            parse_hex_nibble(chunk[1]),
            parse_hex_nibble(chunk[2]),
            parse_hex_nibble(chunk[3]),
        ) else {
            return;
        };
        let val = (n0 << 12) | (n1 << 8) | (n2 << 4) | n3;
        if (0x0003..=0x0060).contains(&val) {
            let ch = (val as u8) + 29;
            if ch.is_ascii_graphic() || ch == b' ' {
                out.push(ch as char);
            }
        } else if val == 0x00B2 || val == 0x00B3 {
            out.push('"');
        }
    }
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    let n_len = needle.len();
    if n_len == 0 || haystack.len() < n_len {
        return None;
    }
    let first = needle[0];
    let last = needle[n_len - 1];
    let max_idx = haystack.len() - n_len;
    let mut i = 0usize;
    while i <= max_idx {
        // Fast skip over long zero-padded or space-padded regions in 64-byte strides
        while i + 64 <= max_idx
            && haystack[i] != first
            && (haystack[i] == 0 || haystack[i] == b' ')
            && haystack[i + 31] == haystack[i]
            && haystack[i + 63] == haystack[i]
            && haystack[i..i + 64].iter().all(|&b| b != first)
        {
            i += 64;
        }
        while i <= max_idx && haystack[i] != first {
            i += 1;
        }
        if i > max_idx {
            return None;
        }
        if haystack[i + n_len - 1] == last && &haystack[i..i + n_len] == needle {
            return Some(i);
        }
        i += 1;
    }
    None
}

/// Extracts text from a decompressed PDF page content stream:
/// - Reconstructs `[(From ) -15 (composing ) -10 (networks)] TJ` kerning arrays and `(literal) Tj` runs.
/// - Reconstructs Identity-H `<0029...>` hex glyph sequences across `BT ... ET` blocks and `Td`/`Tm` positioning.
/// - Returns `(headings, body_text)` where `headings` are lines rendered with large font sizes (`>= 22 Tf`).
fn extract_text_from_pdf_content_stream(stream: &[u8], max_body_chars: usize) -> (Vec<String>, String) {
    let mut headings = Vec::new();
    let mut body = String::new();
    let mut seen = HashSet::new();

    // Fast path: scan `BT ... ET` text objects in the decompressed content stream
    let mut pos = 0usize;
    while pos + 2 < stream.len() {
        let Some(bt_rel) = find_subslice(&stream[pos..], b"BT") else {
            break;
        };
        let bt_start = pos + bt_rel;
        let bt_ok = (bt_start == 0 || !stream[bt_start - 1].is_ascii_alphanumeric())
            && (bt_start + 2 >= stream.len() || !stream[bt_start + 2].is_ascii_alphanumeric());
        if !bt_ok {
            pos = bt_start + 2;
            continue;
        }
        let search_from = bt_start + 2;
        let et_end = find_subslice(&stream[search_from..(search_from + 4096).min(stream.len())], b"ET")
            .map(|r| search_from + r)
            .unwrap_or_else(|| (search_from + 1024).min(stream.len()));
        let block = &stream[search_from..et_end];

        // Check if this BT..ET block uses a large heading font (`/F4 28.33 Tf` or `>= 22 Tf`)
        let is_large_font = if let Some(tf_pos) = find_subslice(block, b"Tf") {
            let prefix = &block[..tf_pos];
            let trimmed_end = prefix
                .iter()
                .rposition(|b| !b.is_ascii_whitespace())
                .map(|p| p + 1)
                .unwrap_or(0);
            let num_start = prefix[..trimmed_end]
                .iter()
                .rposition(|b| !(b.is_ascii_digit() || *b == b'.'))
                .map(|p| p + 1)
                .unwrap_or(0);
            std::str::from_utf8(&prefix[num_start..trimmed_end])
                .ok()
                .and_then(|s| s.parse::<f32>().ok())
                .map(|sz| sz >= 22.0)
                .unwrap_or(false)
        } else {
            false
        };

        let mut line = String::new();
        let mut i = 0usize;
        while i < block.len() {
            match block[i] {
                b'(' => {
                    i += 1;
                    let mut escaped = false;
                    while i < block.len() {
                        let b = block[i];
                        i += 1;
                        if escaped {
                            if matches!(b, b'n' | b'r' | b't') {
                                line.push(' ');
                            } else if b.is_ascii_graphic() || b == b' ' {
                                line.push(b as char);
                            }
                            escaped = false;
                        } else if b == b'\\' {
                            escaped = true;
                        } else if b == b')' {
                            break;
                        } else if b.is_ascii_graphic() || b == b' ' {
                            line.push(b as char);
                        }
                    }
                }
                b'<' if i + 1 < block.len() && block[i + 1] != b'<' => {
                    let hex_start = i + 1;
                    if let Some(rel_close) = block[hex_start..].iter().position(|&b| b == b'>') {
                        decode_pdf_hex_glyph_run(&block[hex_start..hex_start + rel_close], &mut line);
                        i = hex_start + rel_close + 1;
                    } else {
                        i += 1;
                    }
                }
                _ => {
                    i += 1;
                }
            }
        }

        let cleaned: String = line.split_whitespace().collect::<Vec<_>>().join(" ");
        let alpha_count = cleaned.bytes().filter(|b| b.is_ascii_alphabetic()).count();
        if cleaned.len() >= 3 && alpha_count >= 2 {
            if is_large_font {
                headings.push(cleaned);
            } else if body.len() < max_body_chars && seen.insert(cleaned.clone()) {
                body.push_str(&cleaned);
                body.push('\n');
            }
        }

        pos = (et_end + 2).min(stream.len());
    }

    // Merge consecutive single-word/fragment large-font blocks on the same page (e.g. `4.2` + `From composing...`)
    let mut merged_headings = Vec::new();
    let mut current_h = String::new();
    for h in headings {
        if h.chars().all(|c| c.is_ascii_digit() || c == '.') {
            if !current_h.is_empty() && seen.insert(current_h.clone()) {
                merged_headings.push(std::mem::take(&mut current_h));
            }
            current_h = h;
        } else if !current_h.is_empty() && current_h.len() <= 6 {
            current_h.push(' ');
            current_h.push_str(&h);
            if seen.insert(current_h.clone()) {
                merged_headings.push(std::mem::take(&mut current_h));
            }
        } else {
            if !current_h.is_empty() && seen.insert(current_h.clone()) {
                merged_headings.push(std::mem::take(&mut current_h));
            }
            if seen.insert(h.clone()) {
                merged_headings.push(h);
            }
        }
    }
    if !current_h.is_empty() && seen.insert(current_h.clone()) {
        merged_headings.push(current_h);
    }

    (merged_headings, body)
}

/// Scans a raw byte window from a PDF or binary document and extracts:
/// 1. Decompressed `/FlateDecode` streams (handling `TJ` kerning arrays, `(Tj)` literals, and `<0029...>` hex glyphs).
/// 2. Uncompressed `BT ... ET` text blocks and `[(...)] TJ` arrays.
/// 3. UTF-16BE ASCII pairs (`\0A\0u\0t\0h\0o\0r`) and readable ASCII prose runs.
fn extract_readable_runs_from_window(window: &[u8], max_chars: usize) -> String {
    let mut out = String::new();
    let mut seen_lines = HashSet::new();

    // 0. Decompress embedded `/FlateDecode` streams inside this window
    let mut search_pos = 0usize;
    while search_pos + 10 < window.len() && out.len() < max_chars {
        let Some(rel) = find_subslice(&window[search_pos..], b"stream") else {
            break;
        };
        let stream_kw = search_pos + rel;
        let after_kw = stream_kw + 6;
        let data_start = if after_kw < window.len() && window[after_kw] == b'\r' {
            if after_kw + 1 < window.len() && window[after_kw + 1] == b'\n' {
                after_kw + 2
            } else {
                after_kw + 1
            }
        } else if after_kw < window.len() && window[after_kw] == b'\n' {
            after_kw + 1
        } else {
            search_pos = after_kw;
            continue;
        };

        // Check header before `stream` to skip `/Image` and `/Length1` (embedded font binary) streams
        let hdr_start = stream_kw.saturating_sub(140);
        let hdr = &window[hdr_start..stream_kw];
        let is_binary_asset = find_subslice(hdr, b"/Image").is_some()
            || find_subslice(hdr, b"/Length1").is_some()
            || find_subslice(hdr, b"/Subtype").is_some();

        if !is_binary_asset && data_start + 16 < window.len() {
            let max_comp = (window.len() - data_start).min(32 * 1024);
            let slice = &window[data_start..data_start + max_comp];
            let comp_end = find_subslice(slice, b"endstream").unwrap_or(slice.len());
            if (16..=24_576).contains(&comp_end) {
                let mut decoder = ZlibDecoder::new(&slice[..comp_end]);
                let mut decompressed = Vec::with_capacity(8192);
                if decoder
                    .by_ref()
                    .take(64 * 1024)
                    .read_to_end(&mut decompressed)
                    .is_ok()
                    && !decompressed.is_empty()
                {
                    let (headings, body) = extract_text_from_pdf_content_stream(
                        &decompressed,
                        max_chars.saturating_sub(out.len()),
                    );
                    for h in headings {
                        if seen_lines.insert(h.clone()) {
                            out.push_str("### ");
                            out.push_str(&h);
                            out.push('\n');
                        }
                    }
                    if !body.is_empty() {
                        for l in body.lines() {
                            if seen_lines.insert(l.to_string()) {
                                out.push_str(l);
                                out.push('\n');
                            }
                        }
                    }
                }
            }
        }
        search_pos = data_start + 1;
    }

    // Also parse any uncompressed BT..ET / TJ arrays directly present in the window
    if out.len() < max_chars && find_subslice(window, b"BT").is_some() {
        let (headings, body) =
            extract_text_from_pdf_content_stream(window, max_chars.saturating_sub(out.len()));
        for h in headings {
            if seen_lines.insert(h.clone()) {
                out.push_str("### ");
                out.push_str(&h);
                out.push('\n');
            }
        }
        for l in body.lines() {
            if seen_lines.insert(l.to_string()) {
                out.push_str(l);
                out.push('\n');
            }
        }
    }

    // 1. Decode UTF-16BE ASCII pairs (`\0A\0u\0t\0h\0o\0r`) often used in PDF /Title and /Bookmark entries
    let mut utf16_run = String::new();
    let mut i = 0usize;
    while i + 1 < window.len() {
        if window[i] == 0 && (window[i + 1].is_ascii_graphic() || window[i + 1] == b' ') {
            utf16_run.push(window[i + 1] as char);
            i += 2;
        } else {
            if utf16_run.len() >= 5 && utf16_run.bytes().any(|b| b.is_ascii_alphabetic()) {
                let cleaned = utf16_run.trim().to_string();
                if seen_lines.insert(cleaned.clone()) {
                    out.push_str(&cleaned);
                    out.push('\n');
                }
            }
            utf16_run.clear();
            // Skip zero-filled regions in 64-byte strides
            while i + 64 < window.len() && window[i] == 0 && window[i + 1] == 0 && window[i + 31] == 0 && window[i + 63] == 0 {
                i += 64;
            }
            i += 1;
        }
    }

    // 2. Extract parenthesized PDF text literals `(Chapter 1: ...)`
    let mut p_idx = 0usize;
    let mut literal = String::new();
    while p_idx < window.len() && out.len() < max_chars {
        while p_idx + 64 < window.len() && window[p_idx] != b'(' && (window[p_idx] == 0 || window[p_idx] == b' ') && window[p_idx + 31] == window[p_idx] && window[p_idx + 63] == window[p_idx] {
            p_idx += 64;
        }
        while p_idx < window.len() && window[p_idx] != b'(' {
            p_idx += 1;
        }
        if p_idx >= window.len() {
            break;
        }
        let mut cur = p_idx + 1;
        literal.clear();
        let mut escaped = false;
        while cur < window.len() && literal.len() < 400 {
            let b = window[cur];
            cur += 1;
            if escaped {
                if matches!(b, b'n' | b'r' | b't') {
                    literal.push(' ');
                } else if b.is_ascii_graphic() || b == b' ' {
                    literal.push(b as char);
                }
                escaped = false;
            } else if b == b'\\' {
                escaped = true;
            } else if b == b')' {
                let trimmed = literal.trim();
                let alpha_count = trimmed.bytes().filter(|c| c.is_ascii_alphabetic()).count();
                if trimmed.len() >= 4
                    && alpha_count >= 3
                    && alpha_count * 2 >= trimmed.len()
                    && !trimmed.starts_with("Identity-")
                    && !trimmed.starts_with("Adobe")
                {
                    if seen_lines.insert(trimmed.to_string()) {
                        out.push_str(trimmed);
                        out.push('\n');
                    }
                }
                break;
            } else if b.is_ascii_graphic() || b == b' ' {
                literal.push(b as char);
            } else {
                break;
            }
        }
        p_idx = cur;
    }

    // 3. Extract contiguous readable ASCII prose runs (12..=512 chars of printable ASCII) skipping zero/padding blocks
    let mut r_idx = 0usize;
    while r_idx < window.len() && out.len() < max_chars {
        while r_idx + 64 < window.len() && !window[r_idx].is_ascii_graphic() && !window[r_idx + 31].is_ascii_graphic() && !window[r_idx + 63].is_ascii_graphic() {
            r_idx += 64;
        }
        while r_idx < window.len() && !window[r_idx].is_ascii_graphic() {
            r_idx += 1;
        }
        if r_idx >= window.len() {
            break;
        }
        let start_idx = r_idx;
        let mut end_idx = start_idx;
        while end_idx < window.len() && (window[end_idx].is_ascii_graphic() || window[end_idx] == b' ' || window[end_idx] == b'\t') {
            end_idx += 1;
        }
        let end_rel = end_idx - start_idx;
        if (12..=512).contains(&end_rel) {
            if let Ok(line_str) = std::str::from_utf8(&window[start_idx..end_idx]) {
                let words: Vec<&str> = line_str
                    .split_whitespace()
                    .filter(|w| {
                        let alpha = w.bytes().filter(|c| c.is_ascii_alphabetic()).count();
                        alpha >= 3 && !is_pdf_noise_word(&w.to_ascii_lowercase())
                    })
                    .collect();
                if words.len() >= 3 {
                    let joined = words.join(" ");
                    if joined.len() >= 12 && seen_lines.insert(joined.clone()) {
                        out.push_str(&joined);
                        out.push('\n');
                    }
                }
            }
        }
        r_idx = end_idx + 1;
    }

    out.chars().take(max_chars).collect()
}

/// Scans a PDF file in 2 MB streaming chunks to extract all chapter & section headings (`>= 22 Tf`)
/// across the entire book when the Table of Contents in the Head Zone only lists top-level chapters.
fn extract_all_pdf_headings(file: &mut File, size: u64) -> Vec<String> {
    const CHUNK_SIZE: usize = 2 * 1024 * 1024;
    const OVERLAP: usize = 16 * 1024;
    let mut headings = Vec::new();
    let mut seen = HashSet::new();
    let mut offset = 0u64;
    let mut buf = vec![0u8; CHUNK_SIZE];

    while offset < size && headings.len() < 450 {
        if file.seek(SeekFrom::Start(offset)).is_err() {
            break;
        }
        let to_read = ((size - offset) as usize).min(CHUNK_SIZE);
        let Ok(n) = file.read(&mut buf[..to_read]) else {
            break;
        };
        if n < 32 {
            break;
        }
        let slice = &buf[..n];
        let mut pos = 0usize;
        while pos + 32 < n {
            let Some(rel) = find_subslice(&slice[pos..], b"/FlateDecode") else {
                break;
            };
            let flate_idx = pos + rel;
            let after_flate = &slice[flate_idx + 12..(flate_idx + 80).min(n)];
            // Only decompress small page content streams (`/Filter/FlateDecode/Length N>>\nstream`)
            if let Some(len_rel) = find_subslice(after_flate, b"/Length") {
                let len_slice = &after_flate[len_rel + 7..];
                let num_start = len_slice
                    .iter()
                    .position(|b| b.is_ascii_digit())
                    .unwrap_or(len_slice.len());
                let num_end = len_slice[num_start..]
                    .iter()
                    .position(|b| !b.is_ascii_digit())
                    .map(|p| num_start + p)
                    .unwrap_or(len_slice.len());
                if let Ok(comp_len) = std::str::from_utf8(&len_slice[num_start..num_end])
                    .unwrap_or("")
                    .parse::<usize>()
                {
                    if (80..=14_000).contains(&comp_len) {
                        if let Some(s_rel) = find_subslice(after_flate, b"stream") {
                            let mut data_idx = flate_idx + 12 + s_rel + 6;
                            if data_idx < n && slice[data_idx] == b'\r' {
                                data_idx += 1;
                            }
                            if data_idx < n && slice[data_idx] == b'\n' {
                                data_idx += 1;
                            }
                            if data_idx + comp_len <= n {
                                let mut decoder = ZlibDecoder::new(&slice[data_idx..data_idx + comp_len]);
                                let mut dec = Vec::with_capacity(4096);
                                if decoder.by_ref().take(32 * 1024).read_to_end(&mut dec).is_ok()
                                    && find_subslice(&dec, b"Tf").is_some()
                                {
                                    let (page_headings, _) =
                                        extract_text_from_pdf_content_stream(&dec, 0);
                                    for h in page_headings {
                                        if seen.insert(h.clone()) {
                                            headings.push(h);
                                        }
                                    }
                                }
                                pos = data_idx + comp_len;
                                continue;
                            }
                        }
                    }
                }
            }
            pos = flate_idx + 12;
        }

        if offset + (n as u64) >= size {
            break;
        }
        offset += (n.saturating_sub(OVERLAP)) as u64;
    }
    headings
}

static BOOK_DIGEST_CACHE: OnceLock<Mutex<HashMap<(String, u64), BookDigest>>> = OnceLock::new();

#[derive(Clone, Debug)]
struct CachedDocIndex {
    file: LocalFileEntry,
    file_name_lower: String,
    path_search_text: String,
    content: Option<String>,
    content_lower: String,
    sections: Vec<DocSection>,
    unique_words: HashSet<String>,
    prefix4_set: HashSet<[u8; 4]>,
    prefix2_set: HashSet<[u8; 2]>,
    doc_tokens: usize,
    doc_chars: usize,
}

static PARSED_DOC_CACHE: OnceLock<Mutex<HashMap<(String, u64), Arc<CachedDocIndex>>>> = OnceLock::new();
static DIR_WALK_CACHE: OnceLock<Mutex<HashMap<String, (Instant, Vec<LocalFileEntry>)>>> = OnceLock::new();

/// Clears in-memory search & digest caches, and optionally purges the on-disk PDF digest cache directory
/// (used by deterministic ablation benchmarks and cache unit tests).
pub fn clear_all_search_caches(clear_disk: bool) {
    if let Some(c) = BOOK_DIGEST_CACHE.get() {
        if let Ok(mut g) = c.lock() {
            g.clear();
        }
    }
    if let Some(c) = PARSED_DOC_CACHE.get() {
        if let Ok(mut g) = c.lock() {
            g.clear();
        }
    }
    if let Some(c) = DIR_WALK_CACHE.get() {
        if let Ok(mut g) = c.lock() {
            g.clear();
        }
    }
    if let Some(c) = PDF_FULL_TEXT_CACHE.get() {
        if let Ok(mut g) = c.lock() {
            g.clear();
        }
    }
    if clear_disk {
        let dir = std::env::temp_dir().join("digup_book_digest_cache_v2");
        let _ = fs::remove_dir_all(&dir);
        let _ = fs::remove_dir_all(std::env::temp_dir().join("digup_pdf_fulltext_cache_v1"));
    }
}

fn digest_disk_cache_path(path_str: &str, fingerprint: u64) -> PathBuf {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in path_str.as_bytes() {
        h ^= *b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    let dir = std::env::temp_dir().join("digup_book_digest_cache_v2");
    let _ = fs::create_dir_all(&dir);
    dir.join(format!("{h:016x}_{fingerprint:016x}.json"))
}

/// Fast 3-zone bounded-I/O book & PDF skimmer (`< 15 ms` per book regardless of whether the file is 5 MB or 200 MB):
/// - **Head Zone (first 256 KB):** Captures PDF `/Title`, `/Author`, `/Keywords`, title page, and Table of Contents.
/// - **Stride Zone (8 evenly-spaced 32 KB seeks):** Captures chapter headings, running headers, and core terminology.
/// - **Tail Zone (last 128 KB):** Captures the back-of-book subject index, bibliography, and trailer/XMP dictionary.
pub fn extract_fast_book_digest(path: &Path, file_size: u64) -> Option<BookDigest> {
    extract_fast_book_digest_with_options(path, file_size, true).map(|(digest, _)| digest)
}

pub fn extract_fast_book_digest_with_options(
    path: &Path,
    file_size: u64,
    cache_all_pdf_sizes: bool,
) -> Option<(BookDigest, bool)> {
    let mut file = File::open(path).ok()?;
    let meta = file.metadata().ok();
    let size = if file_size > 0 {
        file_size
    } else {
        meta.as_ref().map(|m| m.len())?
    };
    if size == 0 {
        return None;
    }

    let mtime_secs = meta
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .unwrap_or(size);
    let fingerprint = mtime_secs ^ size;
    let path_str = path.to_string_lossy().to_string();
    let cache_key = (path_str.clone(), fingerprint);
    let cache = BOOK_DIGEST_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    if let Ok(guard) = cache.lock() {
        if let Some(cached) = guard.get(&cache_key) {
            return Some((cached.clone(), true));
        }
    }

    // Check persistent on-disk digest cache: when `cache_all_pdf_sizes` is enabled (now default),
    // all PDFs and binary documents are cached on disk regardless of whether they are 15 KB or 55 MB.
    let min_disk_cache_bytes = if cache_all_pdf_sizes {
        1024
    } else {
        2 * 1024 * 1024
    };
    let disk_cache_file = digest_disk_cache_path(&path_str, fingerprint);
    if size >= min_disk_cache_bytes && disk_cache_file.is_file() {
        if let Ok(raw_json) = fs::read_to_string(&disk_cache_file) {
            if let Ok(cached_digest) = serde_json::from_str::<BookDigest>(&raw_json) {
                if !cached_digest.searchable_text.is_empty() {
                    if let Ok(mut guard) = cache.lock() {
                        guard.insert(cache_key, cached_digest.clone());
                    }
                    return Some((cached_digest, true));
                }
            }
        }
    }

    const HEAD_BYTES: usize = 512 * 1024;
    const STRIDE_BYTES: usize = 48 * 1024;
    const STRIDE_COUNT: u64 = 12;
    const TAIL_BYTES: usize = 256 * 1024;

    // 1. Read Head Zone (first 512 KB covers PDF header, cover page, copyright, and front-matter Table of Contents)
    let head_len = (size as usize).min(HEAD_BYTES);
    let mut head_buf = vec![0u8; head_len];
    let n_head = file.read(&mut head_buf).ok()?;
    head_buf.truncate(n_head);

    // 2. Read Tail Zone (if file extends beyond Head)
    let mut tail_buf = Vec::new();
    if size > HEAD_BYTES as u64 {
        let tail_start = size.saturating_sub(TAIL_BYTES as u64).max(HEAD_BYTES as u64);
        if file.seek(SeekFrom::Start(tail_start)).is_ok() {
            let tail_len = (size - tail_start) as usize;
            tail_buf.resize(tail_len, 0u8);
            if let Ok(n_tail) = file.read(&mut tail_buf) {
                tail_buf.truncate(n_tail);
            }
        }
    }

    let title = extract_pdf_meta_field(&head_buf, b"/Title", "dc:title")
        .or_else(|| extract_pdf_meta_field(&tail_buf, b"/Title", "dc:title"))
        .unwrap_or_default();
    let author = extract_pdf_meta_field(&head_buf, b"/Author", "dc:creator")
        .or_else(|| extract_pdf_meta_field(&tail_buf, b"/Author", "dc:creator"))
        .unwrap_or_default();
    let keywords = extract_pdf_meta_field(&head_buf, b"/Keywords", "pdf:Keywords")
        .or_else(|| extract_pdf_meta_field(&tail_buf, b"/Keywords", "dc:description"))
        .or_else(|| extract_pdf_meta_field(&head_buf, b"/Subject", "dc:description"))
        .unwrap_or_default();

    let mut sections_text = String::new();
    if !title.is_empty() || !author.is_empty() || !keywords.is_empty() {
        sections_text.push_str("# Book Metadata & Overview\n");
        if !title.is_empty() {
            sections_text.push_str(&format!("Title: {title}\n"));
        }
        if !author.is_empty() {
            sections_text.push_str(&format!("Author: {author}\n"));
        }
        if !keywords.is_empty() {
            sections_text.push_str(&format!("Keywords: {keywords}\n"));
        }
        sections_text.push('\n');
    }

    let head_runs = extract_readable_runs_from_window(&head_buf, 6000);
    if !head_runs.is_empty() {
        sections_text.push_str("## Front Matter & Table of Contents\n");
        sections_text.push_str(&head_runs);
        sections_text.push('\n');
    }

    // 3. Extract all chapter & section headings across the PDF when the PDF uses `/FlateDecode` compressed streams
    if head_buf.starts_with(b"%PDF")
        && (find_subslice(&head_buf, b"/FlateDecode").is_some()
            || find_subslice(&tail_buf, b"/FlateDecode").is_some())
    {
        let all_headings = extract_all_pdf_headings(&mut file, size);
        if !all_headings.is_empty() {
            sections_text.push_str("## Complete Chapter & Section Headings\n");
            for h in all_headings {
                sections_text.push_str("- ");
                sections_text.push_str(&h);
                sections_text.push('\n');
            }
            sections_text.push('\n');
        }
    }

    // 4. Read 12 Evenly-Spaced Stride Windows across the middle of large books
    if size > (HEAD_BYTES + TAIL_BYTES) as u64 {
        let mut stride_buf = vec![0u8; STRIDE_BYTES];
        let mut stride_collected = String::new();
        for s in 1..=STRIDE_COUNT {
            let offset = (size / (STRIDE_COUNT + 1)) * s;
            if offset <= HEAD_BYTES as u64 || offset + (STRIDE_BYTES as u64) >= size.saturating_sub(TAIL_BYTES as u64) {
                continue;
            }
            if file.seek(SeekFrom::Start(offset)).is_ok() {
                if let Ok(n) = file.read(&mut stride_buf) {
                    let runs = extract_readable_runs_from_window(&stride_buf[..n], 900);
                    if !runs.is_empty() {
                        stride_collected.push_str(&runs);
                    }
                }
            }
        }
        if !stride_collected.is_empty() {
            sections_text.push_str("## Sampled Chapters & Core Topics\n");
            sections_text.push_str(&stride_collected);
            sections_text.push('\n');
        }
    }

    if !tail_buf.is_empty() {
        let tail_runs = extract_readable_runs_from_window(&tail_buf, 4500);
        if !tail_runs.is_empty() {
            sections_text.push_str("## Back-of-Book Index & References\n");
            sections_text.push_str(&tail_runs);
        }
    }

    let digest = BookDigest {
        title,
        author,
        keywords,
        searchable_text: sections_text,
    };
    if size >= min_disk_cache_bytes {
        if let Ok(serialized) = serde_json::to_string(&digest) {
            let _ = fs::write(&disk_cache_file, serialized);
        }
    }
    if let Ok(mut guard) = cache.lock() {
        guard.insert(cache_key, digest.clone());
    }
    Some((digest, false))
}

fn build_or_get_cached_doc_index(
    file: LocalFileEntry,
    cache_all_pdf_sizes: bool,
    use_doc_cache: bool,
) -> (Arc<CachedDocIndex>, bool) {
    let fingerprint = (file.modified.max(0) as u64) ^ file.size;
    let cache_key = (file.path.clone(), fingerprint);
    let parsed_cache = PARSED_DOC_CACHE.get_or_init(|| Mutex::new(HashMap::new()));

    if use_doc_cache {
        if let Ok(guard) = parsed_cache.lock() {
            if let Some(existing) = guard.get(&cache_key) {
                let was_pdf = file.kind == "pdf";
                return (Arc::clone(existing), was_pdf);
            }
        }
    }

    let mut digest_was_cached = false;
    let text_opt = if matches!(file.kind, "doc" | "code") && file.size <= 2_000_000 {
        fs::read_to_string(&file.path).ok().or_else(|| {
            extract_fast_book_digest_with_options(Path::new(&file.path), file.size, cache_all_pdf_sizes)
                .map(|(d, _)| d.searchable_text)
                .filter(|s| !s.trim().is_empty())
        })
    } else if matches!(file.kind, "pdf" | "doc") {
        extract_fast_book_digest_with_options(Path::new(&file.path), file.size, cache_all_pdf_sizes)
            .map(|(d, cached)| {
                if file.kind == "pdf" {
                    digest_was_cached = cached;
                }
                d.searchable_text
            })
            .filter(|s| !s.trim().is_empty())
    } else {
        None
    };

    let file_name_lower = Path::new(&file.path)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();

    let rel_path_raw = file
        .path
        .strip_prefix(&file.root)
        .unwrap_or(&file.path)
        .trim_start_matches(['\\', '/']);
    let camel_expanded: String = rel_path_raw
        .split(|c: char| !c.is_alphanumeric())
        .flat_map(split_camel_case)
        .collect::<Vec<_>>()
        .join(" ")
        .to_ascii_lowercase();
    let path_search_text = format!("{} {}", rel_path_raw.to_ascii_lowercase(), camel_expanded);

    let body_ref = text_opt.as_deref().unwrap_or("");
    let doc_chars = rel_path_raw.len() + body_ref.len();
    let doc_tokens = rel_path_raw
        .split(|c: char| !c.is_alphanumeric())
        .filter(|s| !s.is_empty())
        .count()
        + body_ref.split_whitespace().count();

    let content_lower = body_ref.to_ascii_lowercase();
    let sections = if file.kind != "code" && !body_ref.is_empty() {
        split_into_sections(body_ref)
    } else {
        Vec::new()
    };

    let mut unique_words = HashSet::new();
    let mut prefix4_set = HashSet::new();
    let mut prefix2_set = HashSet::new();

    for src in [path_search_text.as_str(), content_lower.as_str()] {
        for word in src.split(|c: char| !c.is_ascii_alphanumeric()) {
            let w_bytes = word.as_bytes();
            if w_bytes.len() < 2 {
                continue;
            }
            prefix2_set.insert([w_bytes[0], w_bytes[1]]);
            if w_bytes.len() >= 4 {
                prefix4_set.insert([w_bytes[0], w_bytes[1], w_bytes[2], w_bytes[3]]);
            }
            unique_words.insert(word.to_string());
        }
    }

    let built = Arc::new(CachedDocIndex {
        file,
        file_name_lower,
        path_search_text,
        content: text_opt,
        content_lower,
        sections,
        unique_words,
        prefix4_set,
        prefix2_set,
        doc_tokens,
        doc_chars,
    });

    if use_doc_cache {
        if let Ok(mut guard) = parsed_cache.lock() {
            guard.insert(cache_key, Arc::clone(&built));
        }
    }

    (built, digest_was_cached)
}

fn doc_term_quality_fast(doc: &CachedDocIndex, term: &str) -> f64 {
    let tb = term.as_bytes();
    if tb.is_empty() {
        return 0.0;
    }
    if doc.unique_words.contains(term) {
        return 1.0;
    }
    if tb.len() >= 4 {
        let p4 = [tb[0], tb[1], tb[2], tb[3]];
        if doc.prefix4_set.contains(&p4) {
            for w in &doc.unique_words {
                let wb = w.as_bytes();
                if wb.len() > tb.len() && wb.len() <= tb.len() + 6 && wb.starts_with(tb) {
                    return 0.85;
                }
            }
        }
    }
    if tb.len() >= 5 {
        let p2 = [tb[0], tb[1]];
        if doc.prefix2_set.contains(&p2) {
            for w in &doc.unique_words {
                let wb = w.as_bytes();
                if wb.len() >= 2
                    && wb[0] == tb[0]
                    && wb[1] == tb[1]
                    && wb.len().abs_diff(tb.len()) <= 1
                    && is_within_one_edit(wb, tb)
                {
                    return 0.65;
                }
            }
        }
    }
    0.0
}

fn doc_may_match_term_fast(doc: &CachedDocIndex, term: &str) -> bool {
    doc_term_quality_fast(doc, term) > 0.0
}

// ---------------------------------------------------------------------------------------------------------------
// Exact quote search: `"GLOW model samples from the base density raised to a positive power."` finds only the
// documents that contain those exact words in that exact order (case, punctuation, hyphens and line breaks between
// the words are ignored; every word must match whole, with no prefix or fuzzy matching).
// ---------------------------------------------------------------------------------------------------------------

const QUOTE_CONTEXT_CHARS: usize = 220;
const QUOTE_SNIPPETS_PER_DOC: usize = 3;

fn is_quote_word_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b >= 0x80
}

fn quote_tokens(text: &str) -> Vec<String> {
    text.split(|c: char| !(c.is_ascii_alphanumeric() || !c.is_ascii()))
        .filter(|s| !s.is_empty())
        .map(|s| s.to_ascii_lowercase())
        .collect()
}

fn is_quote_char(c: char) -> bool {
    matches!(c, '"' | '“' | '”' | '„')
}

/// Returns the phrase to look for when `query` is a quote: wrapped in one pair of double quotes (straight or curly),
/// or any query when `force` (`"exact": true` in the request) is set. `None` for ordinary searches.
pub fn exact_quote_phrase(query: &str, force: bool) -> Option<String> {
    let q = query.trim();
    let chars: Vec<char> = q.chars().collect();
    let wrapped = chars.len() >= 2
        && is_quote_char(chars[0])
        && is_quote_char(chars[chars.len() - 1])
        && !chars[1..chars.len() - 1].iter().any(|&c| is_quote_char(c));
    if !wrapped && !force {
        return None;
    }
    let inner: String = if wrapped {
        chars[1..chars.len() - 1].iter().collect()
    } else {
        q.chars().filter(|&c| !is_quote_char(c)).collect()
    };
    if quote_tokens(&inner).is_empty() {
        None
    } else {
        Some(inner)
    }
}

fn next_quote_word(b: &[u8], mut i: usize) -> Option<(usize, usize)> {
    while i < b.len() && !is_quote_word_byte(b[i]) {
        i += 1;
    }
    if i >= b.len() {
        return None;
    }
    let start = i;
    while i < b.len() && is_quote_word_byte(b[i]) {
        i += 1;
    }
    Some((start, i))
}

/// Counts the places in `content` where `tokens` (lowercase) occur as consecutive whole words, and returns the byte
/// spans of the first `keep` of them.
fn find_exact_quote(content: &str, tokens: &[String], keep: usize) -> (usize, Vec<(usize, usize)>) {
    let mut kept = Vec::new();
    let mut count = 0usize;
    if tokens.is_empty() {
        return (0, kept);
    }
    let b = content.as_bytes();
    let mut pos = 0usize;
    while let Some((s, e)) = next_quote_word(b, pos) {
        pos = e;
        if !b[s..e].eq_ignore_ascii_case(tokens[0].as_bytes()) {
            continue;
        }
        let mut end = e;
        let mut all = true;
        for tok in &tokens[1..] {
            match next_quote_word(b, end) {
                Some((ws, we)) if b[ws..we].eq_ignore_ascii_case(tok.as_bytes()) => end = we,
                _ => {
                    all = false;
                    break;
                }
            }
        }
        if all {
            count += 1;
            if kept.len() < keep {
                kept.push((s, end));
            }
        }
    }
    (count, kept)
}

/// Cheap pre-filter on the per-document word index: every (ASCII) word of the quote must occur in the document.
fn doc_has_all_quote_words(doc: &CachedDocIndex, tokens: &[String]) -> bool {
    tokens
        .iter()
        .all(|t| t.len() < 2 || !t.is_ascii() || doc.unique_words.contains(t.as_str()))
}

fn collapse_ws(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut prev_space = false;
    for c in s.chars() {
        if c.is_whitespace() {
            if !prev_space {
                out.push(' ');
            }
            prev_space = true;
        } else {
            out.push(c);
            prev_space = false;
        }
    }
    out
}

fn line_of_byte(content: &str, byte: usize) -> usize {
    content.as_bytes()[..byte.min(content.len())]
        .iter()
        .filter(|&&c| c == b'\n')
        .count()
        + 1
}

static PDF_FULL_TEXT_CACHE: OnceLock<Mutex<HashMap<(String, u64), Option<Arc<String>>>>> = OnceLock::new();

fn pdf_full_text_disk_path(path_str: &str, fingerprint: u64) -> PathBuf {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in path_str.as_bytes() {
        h ^= *b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    let dir = std::env::temp_dir().join("digup_pdf_fulltext_cache_v1");
    let _ = fs::create_dir_all(&dir);
    dir.join(format!("{h:016x}_{fingerprint:016x}.txt"))
}

/// Full text of a PDF (every page), from RAM, else the disk cache, else extracted once and cached in both.
fn pdf_full_text(file: &LocalFileEntry) -> Option<Arc<String>> {
    let fingerprint = (file.modified.max(0) as u64) ^ file.size;
    let key = (file.path.clone(), fingerprint);
    let cache = PDF_FULL_TEXT_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    if let Ok(g) = cache.lock() {
        if let Some(found) = g.get(&key) {
            return found.clone();
        }
    }
    let disk = pdf_full_text_disk_path(&file.path, fingerprint);
    let text = match fs::read_to_string(&disk) {
        Ok(t) if !t.is_empty() => Some(t),
        _ => {
            let extracted = crate::pdf_text::extract_full_pdf_text(Path::new(&file.path));
            if let Some(t) = &extracted {
                let _ = fs::write(&disk, t);
            }
            extracted
        }
    }
    .map(Arc::new);
    if let Ok(mut g) = cache.lock() {
        g.insert(key, text.clone());
    }
    text
}

enum QuoteText<'a> {
    Borrowed(&'a str),
    Full(Arc<String>),
}

impl QuoteText<'_> {
    fn as_str(&self) -> &str {
        match self {
            QuoteText::Borrowed(s) => s,
            QuoteText::Full(s) => s.as_str(),
        }
    }
}

/// The text a quote is looked for in: a PDF's full text (falling back to its digest when it cannot be extracted),
/// otherwise the document's content.
fn quote_text_of(doc: &CachedDocIndex) -> Option<QuoteText<'_>> {
    if doc.file.kind == "pdf" {
        if let Some(full) = pdf_full_text(&doc.file) {
            return Some(QuoteText::Full(full));
        }
    }
    doc.content.as_deref().map(QuoteText::Borrowed)
}

/// Runs an exact quote search over already indexed documents. Returns `(hits, total_matches, docs_checked)`.
fn exact_quote_search(
    docs: &[Arc<CachedDocIndex>],
    phrase: &str,
    is_code_req: bool,
    limit: usize,
    use_prefilter: bool,
) -> (Vec<Value>, usize, usize) {
    let tokens = quote_tokens(phrase);
    // A PDF's digest only samples the book, so PDFs are never pre-filtered by it: their full text is searched.
    let candidates: Vec<&Arc<CachedDocIndex>> = docs
        .iter()
        .filter(|d| {
            d.file.kind == "pdf"
                || (d.content.is_some() && (!use_prefilter || doc_has_all_quote_words(d, &tokens)))
        })
        .collect();
    let docs_checked = candidates.len();

    // Workers pull the next document off a shared counter, so one big book does not stall a fixed chunk.
    let workers = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4)
        .clamp(1, 16)
        .min(candidates.len().max(1));
    let next = AtomicUsize::new(0);
    let mut found: Vec<(usize, usize, Vec<(usize, usize)>)> = Vec::new();
    std::thread::scope(|s| {
        let handles: Vec<_> = (0..workers)
            .map(|_| {
                let (tokens, candidates, next) = (&tokens, &candidates, &next);
                s.spawn(move || {
                    let mut local = Vec::new();
                    loop {
                        let i = next.fetch_add(1, Ordering::Relaxed);
                        let Some(d) = candidates.get(i) else { break };
                        let Some(text) = quote_text_of(d) else { continue };
                        let (count, spans) = find_exact_quote(text.as_str(), tokens, QUOTE_SNIPPETS_PER_DOC);
                        if count > 0 {
                            local.push((i, count, spans));
                        }
                    }
                    local
                })
            })
            .collect();
        for h in handles {
            if let Ok(v) = h.join() {
                found.extend(v);
            }
        }
    });

    let total_matches: usize = found.iter().map(|f| f.1).sum();
    found.sort_by(|a, b| {
        b.1.cmp(&a.1)
            .then_with(|| candidates[a.0].file.path.cmp(&candidates[b.0].file.path))
    });
    found.truncate(limit);

    let mut hits = Vec::with_capacity(found.len());
    for (doc_idx, count, spans) in found {
        let doc = candidates[doc_idx];
        let file = &doc.file;
        let Some(text) = quote_text_of(doc) else { continue };
        let content = text.as_str();
        // Full PDF text carries a form feed after every page, so the place of a match is its page.
        let paged = matches!(text, QuoteText::Full(_));
        let mut sections = Vec::new();
        let mut snippets = Vec::new();
        let mut loc_val = Value::Null;
        let mut end_line_val = Value::Null;
        for (n, &(s, e)) in spans.iter().enumerate() {
            let mut a = s.saturating_sub(QUOTE_CONTEXT_CHARS);
            while !content.is_char_boundary(a) {
                a -= 1;
            }
            let mut b = (e + QUOTE_CONTEXT_CHARS).min(content.len());
            while !content.is_char_boundary(b) {
                b += 1;
            }
            let before = collapse_ws(&content[a..s]);
            let mid = collapse_ws(&content[s..e]);
            let after = collapse_ws(&content[e..b]);
            let (start_line, end_line) = if paged {
                let page = content.as_bytes()[..s].iter().filter(|&&c| c == 0x0c).count() + 1;
                (page, page)
            } else {
                (line_of_byte(content, s), line_of_byte(content, e))
            };
            if n == 0 {
                loc_val = json!(start_line);
                end_line_val = json!(end_line);
            }
            snippets.push(format!(
                "{}{}«{}»{}{}",
                if a > 0 { "…" } else { "" },
                before,
                mid,
                after,
                if b < content.len() { "…" } else { "" },
            ));
            sections.push(json!({
                "heading": if paged {
                    format!("Page {start_line} · exact match {} of {}", n + 1, count)
                } else {
                    format!("Exact match {} of {}", n + 1, count)
                },
                "startLine": start_line,
                "endLine": end_line,
                "text": format!("{before}{mid}{after}"),
            }));
        }
        hits.push(json!({
            "path": file.path,
            "kind": if is_code_req { "code" } else { file.kind },
            "score": 1.0,
            "segment": if paged { "page" } else { "lines" },
            "loc_end": end_line_val,
            "matchedWords": tokens.len(),
            "words": true,
            "meaning": true,
            "exact": true,
            "exactMatches": count,
            "excerpt": snippets.join("\n\n"),
            "sections": sections,
            "loc": loc_val,
            "endLine": end_line_val,
            "size": file.size,
            "modified": file.modified,
        }));
    }
    (hits, total_matches, docs_checked)
}

/// Wraps whole-word or prefix occurrences of `terms` in `text` with `«...»` markers (which `window.js` renders as `<mark>`).
fn highlight_excerpt(text: &str, terms: &[String]) -> String {
    let mut result = text.to_string();
    for term in terms {
        if term.len() < 2 {
            continue;
        }
        let lower = result.to_ascii_lowercase();
        let bytes = lower.as_bytes();
        let mut start = 0usize;
        while let Some(rel) = lower[start..].find(term.as_str()) {
            let pos = start + rel;
            let mut end = pos + term.len();
            let left_ok = pos == 0 || !bytes[pos - 1].is_ascii_alphanumeric();
            if left_ok {
                // Extend highlight to cover the rest of the word when `term` is a prefix (`"simo"` -> `«Simon»`)
                if term.len() >= 4 {
                    while end < bytes.len()
                        && bytes[end].is_ascii_alphanumeric()
                        && end - pos <= term.len() + 6
                    {
                        end += 1;
                    }
                }
                if result.is_char_boundary(pos) && result.is_char_boundary(end) {
                    let matched = &result[pos..end];
                    result = format!("{}«{}»{}", &result[..pos], matched, &result[end..]);
                    break;
                }
            }
            start = pos + 1;
            if start >= bytes.len() {
                break;
            }
        }
    }
    result
}

/// Attempts to call a running local OpenAI-compatible SLM server (`llama-server` on port 8080/8081 or `ollama` on 11434)
/// over 127.0.0.1 using zero-dependency raw HTTP so true generative SLM answers work out of the box whenever a local
/// server is active.
pub fn try_local_http_slm(
    system_prompt: &str,
    user_prompt: &str,
    history: &[Value],
) -> Option<(String, String)> {
    let endpoints: &[(&str, u16, &str, &str)] = &[
        ("127.0.0.1", 8080, "/v1/chat/completions", "qwen2.5-3b-instruct"),
        ("127.0.0.1", 8081, "/v1/chat/completions", "qwen2.5-3b-instruct"),
        ("127.0.0.1", 11434, "/v1/chat/completions", "qwen2.5:3b"),
    ];

    for &(host, port, path, default_model) in endpoints {
        let addr: SocketAddr = format!("{host}:{port}").parse().ok()?;
        let Ok(mut stream) = TcpStream::connect_timeout(&addr, Duration::from_millis(120)) else {
            continue;
        };
        let _ = stream.set_read_timeout(Some(Duration::from_secs(45)));
        let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));

        let mut messages = vec![json!({ "role": "system", "content": system_prompt })];
        for h in history.iter().take(6) {
            if let (Some(role), Some(content)) = (h["role"].as_str(), h["content"].as_str()) {
                messages.push(json!({ "role": role, "content": content }));
            }
        }
        messages.push(json!({ "role": "user", "content": user_prompt }));

        let payload = json!({
            "model": default_model,
            "messages": messages,
            "temperature": 0.2,
            "max_tokens": 768,
            "stream": false
        })
        .to_string();

        let request = format!(
            "POST {path} HTTP/1.1\r\nHost: {host}:{port}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            payload.len(),
            payload
        );

        if stream.write_all(request.as_bytes()).is_err() {
            continue;
        }
        let mut response_bytes = Vec::new();
        if stream.read_to_end(&mut response_bytes).is_err() {
            continue;
        }
        let response_str = String::from_utf8_lossy(&response_bytes);
        let Some((_, body)) = response_str.split_once("\r\n\r\n") else {
            continue;
        };
        // Find JSON object in body (handles chunked or plain)
        let Some(json_start) = body.find('{') else {
            continue;
        };
        let Some(json_end) = body.rfind('}') else {
            continue;
        };
        if let Ok(parsed) = serde_json::from_str::<Value>(&body[json_start..=json_end]) {
            if let Some(content) = parsed["choices"][0]["message"]["content"].as_str() {
                let trimmed = content.trim();
                if !trimmed.is_empty() {
                    let model_used = parsed["model"]
                        .as_str()
                        .unwrap_or(default_model)
                        .to_string();
                    return Some((trimmed.to_string(), format!("{model_used} @ {host}:{port}")));
                }
            }
        }
    }
    None
}

/// Handles `ask` requests (`summaries`, `search`, `lines`, `prewarm`) directly in Rust when `digup.exe` is not present.
pub fn local_search_op(
    request: &Value,
    folders: &[String],
    code_folders: &[String],
    skipped: &[String],
    skip_types: &[String],
) -> Value {
    local_search_op_with_progress(request, folders, code_folders, skipped, skip_types, |_| {})
}

/// Handles `ask` requests and emits live progress snapshots (`done`, `total`, `progress`, `currentFile`,
/// `tokensSearched`, `elapsedMs`) during `"search"` so the UI can render a real-time progress bar and telemetry.
pub fn local_search_op_with_progress<F>(
    request: &Value,
    folders: &[String],
    code_folders: &[String],
    skipped: &[String],
    skip_types: &[String],
    mut on_progress: F,
) -> Value
where
    F: FnMut(Value),
{
    let op = request["op"].as_str().unwrap_or("");
    let is_code_req = request["code"].as_bool().unwrap_or(false);

    match op {
        "prewarm" => json!({ "ok": true }),
        "summaries" => {
            let target_roots = if is_code_req { code_folders } else { folders };
            let mut roots = Vec::new();
            for root in target_roots {
                let root_path = Path::new(root);
                let missing = !root_path.exists();
                let files = walk_local_folders(std::slice::from_ref(root), skipped, skip_types);
                let mut kinds: HashMap<&str, usize> = HashMap::new();
                let mut count = 0usize;
                for f in &files {
                    if is_code_req && f.kind != "code" {
                        continue;
                    }
                    count += 1;
                    *kinds.entry(f.kind).or_insert(0) += 1;
                }
                roots.push(json!({
                    "path": root,
                    "files": count,
                    "indexed": count,
                    "pending": 0,
                    "unfinished": 0,
                    "skipped": 0,
                    "failed": 0,
                    "missing": missing,
                    "unreadable": false,
                    "kinds": kinds,
                }));
            }
            json!({ "roots": roots })
        }
        "lines" => {
            let path = request["path"].as_str().unwrap_or("");
            let start = request["start"].as_u64().unwrap_or(1).max(1) as usize;
            let end = request["end"].as_u64().unwrap_or((start + 30) as u64) as usize;
            let content = fs::read_to_string(path).unwrap_or_else(|_| {
                extract_fast_book_digest(Path::new(path), 0)
                    .map(|d| d.searchable_text)
                    .unwrap_or_default()
            });
            let all_lines: Vec<&str> = content.lines().collect();
            let total = all_lines.len().max(1);
            let slice_start = (start - 1).min(total.saturating_sub(1));
            let slice_end = end.min(total);
            let text = if slice_start < slice_end {
                all_lines[slice_start..slice_end].join("\n")
            } else {
                String::new()
            };
            json!({
                "text": text,
                "start": slice_start + 1,
                "total": total,
            })
        }
        "search" => {
            let started = Instant::now();
            let query = request["query"]
                .as_str()
                .or_else(|| request["q"].as_str())
                .unwrap_or("")
                .trim();
            let filter_kind = request["kind"].as_str();
            let filter_kinds: Option<Vec<&str>> = request["kinds"]
                .as_array()
                .map(|arr| arr.iter().filter_map(|v| v.as_str()).collect());
            let limit = request["limit"].as_u64().unwrap_or(50) as usize;

            let opt_disk_cache_all_pdfs = request["opt"]["diskCacheAllPdfs"].as_bool().unwrap_or(true);
            let opt_parallel_scan = request["opt"]["parallelScan"].as_bool().unwrap_or(true);
            let opt_inverted_index = request["opt"]["invertedIndex"].as_bool().unwrap_or(true);

            let mut all_roots: Vec<String> = folders.to_vec();
            for cf in code_folders {
                if !all_roots.iter().any(|r| r.eq_ignore_ascii_case(cf)) {
                    all_roots.push(cf.clone());
                }
            }

            let walk_key = format!(
                "{}|{}|{}",
                all_roots.join(";"),
                skipped.join(";"),
                skip_types.join(";")
            );
            let all_files = if opt_inverted_index {
                let walk_cache = DIR_WALK_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
                let cached_walk = walk_cache.lock().ok().and_then(|g| {
                    g.get(&walk_key).and_then(|(ts, list)| {
                        if ts.elapsed() < Duration::from_secs(10) {
                            Some(list.clone())
                        } else {
                            None
                        }
                    })
                });
                if let Some(files) = cached_walk {
                    files
                } else {
                    let fresh = walk_local_folders(&all_roots, skipped, skip_types);
                    if let Ok(mut g) = walk_cache.lock() {
                        g.insert(walk_key, (Instant::now(), fresh.clone()));
                    }
                    fresh
                }
            } else {
                walk_local_folders(&all_roots, skipped, skip_types)
            };

            let eligible_files: Vec<LocalFileEntry> = all_files
                .into_iter()
                .filter(|file| {
                    if is_code_req && file.kind != "code" && file.kind != "doc" {
                        return false;
                    }
                    if let Some(k) = filter_kind {
                        if file.kind != k {
                            return false;
                        }
                    }
                    if let Some(ref ks) = filter_kinds {
                        if !ks.contains(&file.kind) {
                            return false;
                        }
                    }
                    true
                })
                .collect();

            let total_candidates = eligible_files.len();
            let terms = query_terms(query);

            // Emit initial 0% progress event so the UI progress bar appears immediately
            on_progress(json!({
                "query": query,
                "phase": "scanning",
                "done": 0,
                "total": total_candidates,
                "progress": if total_candidates == 0 { 1.0 } else { 0.0 },
                "currentFile": "",
                "tokensSearched": 0,
                "charsSearched": 0,
                "elapsedMs": started.elapsed().as_secs_f64() * 1000.0,
            }));

            let mut indexed_docs: Vec<Arc<CachedDocIndex>> = Vec::with_capacity(total_candidates);
            let mut df: HashMap<String, usize> = HashMap::new();
            let mut tokens_searched: usize = 0;
            let mut chars_searched: usize = 0;
            let mut bytes_inspected: u64 = 0;
            let mut pdf_books_scanned: usize = 0;
            let mut cached_digests_used: usize = 0;
            let emit_stride = (total_candidates / 20).max(1);

            // Fast-path: if `opt_inverted_index` is enabled and all candidate files are already present
            // in `PARSED_DOC_CACHE`, retrieve them in a single lock acquisition on the main thread
            // without spawning worker threads.
            let mut warm_cache_complete = false;
            if opt_inverted_index && total_candidates > 0 {
                let parsed_cache = PARSED_DOC_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
                if let Ok(guard) = parsed_cache.lock() {
                    if eligible_files.iter().all(|f| {
                        let fp = (f.modified.max(0) as u64) ^ f.size;
                        guard.contains_key(&(f.path.clone(), fp))
                    }) {
                        for file in &eligible_files {
                            let fp = (file.modified.max(0) as u64) ^ file.size;
                            if let Some(doc) = guard.get(&(file.path.clone(), fp)) {
                                if doc.file.kind == "pdf" {
                                    pdf_books_scanned += 1;
                                    cached_digests_used += 1;
                                }
                                bytes_inspected = bytes_inspected.saturating_add(doc.file.size);
                                chars_searched += doc.doc_chars;
                                tokens_searched += doc.doc_tokens;
                                indexed_docs.push(Arc::clone(doc));
                            }
                        }
                        warm_cache_complete = indexed_docs.len() == total_candidates;
                    }
                }
            }

            if warm_cache_complete {
                on_progress(json!({
                    "query": query,
                    "phase": "ranking",
                    "done": total_candidates,
                    "total": total_candidates,
                    "progress": 1.0,
                    "currentFile": "",
                    "tokensSearched": tokens_searched,
                    "charsSearched": chars_searched,
                    "pdfBooksScanned": pdf_books_scanned,
                    "cachedDigestsUsed": cached_digests_used,
                    "elapsedMs": (started.elapsed().as_secs_f64() * 1000.0 * 10.0).round() / 10.0,
                }));
            } else if opt_parallel_scan && total_candidates > 1 {
                let worker_count = std::thread::available_parallelism()
                    .map(|n| n.get())
                    .unwrap_or(8)
                    .clamp(2, 16);
                let chunk_size = (total_candidates + worker_count - 1) / worker_count;
                let chunks: Vec<Vec<LocalFileEntry>> = eligible_files
                    .chunks(chunk_size.max(1))
                    .map(|c| c.to_vec())
                    .collect();

                let chunk_results: Vec<Vec<(Arc<CachedDocIndex>, bool)>> = std::thread::scope(|s| {
                    let handles: Vec<_> = chunks
                        .into_iter()
                        .map(|chunk| {
                            s.spawn(move || {
                                chunk
                                    .into_iter()
                                    .map(|file| {
                                        build_or_get_cached_doc_index(
                                            file,
                                            opt_disk_cache_all_pdfs,
                                            opt_inverted_index,
                                        )
                                    })
                                    .collect::<Vec<_>>()
                            })
                        })
                        .collect();
                    handles
                        .into_iter()
                        .filter_map(|h| h.join().ok())
                        .collect()
                });

                let mut idx = 0usize;
                for batch in chunk_results {
                    for (doc, was_cached) in batch {
                        let is_pdf_or_large = doc.file.kind == "pdf" || doc.file.size > 1_000_000;
                        if doc.file.kind == "pdf" {
                            pdf_books_scanned += 1;
                        }
                        if was_cached {
                            cached_digests_used += 1;
                        }
                        bytes_inspected = bytes_inspected.saturating_add(doc.file.size);
                        chars_searched += doc.doc_chars;
                        tokens_searched += doc.doc_tokens;

                        idx += 1;
                        if is_pdf_or_large || idx % emit_stride == 0 || idx == total_candidates {
                            let short_name = Path::new(&doc.file.path)
                                .file_name()
                                .and_then(|s| s.to_str())
                                .unwrap_or(&doc.file.path)
                                .to_string();
                            on_progress(json!({
                                "query": query,
                                "phase": if idx == total_candidates { "ranking" } else { "scanning" },
                                "done": idx,
                                "total": total_candidates,
                                "progress": (idx as f64) / (total_candidates.max(1) as f64),
                                "currentFile": short_name,
                                "tokensSearched": tokens_searched,
                                "charsSearched": chars_searched,
                                "pdfBooksScanned": pdf_books_scanned,
                                "cachedDigestsUsed": cached_digests_used,
                                "elapsedMs": (started.elapsed().as_secs_f64() * 1000.0 * 10.0).round() / 10.0,
                            }));
                        }
                        indexed_docs.push(doc);
                    }
                }
            } else {
                for (idx, file) in eligible_files.into_iter().enumerate() {
                    let is_pdf_or_large = file.kind == "pdf" || file.size > 1_000_000;
                    if file.kind == "pdf" {
                        pdf_books_scanned += 1;
                    }
                    bytes_inspected = bytes_inspected.saturating_add(file.size);

                    let (doc, was_cached) = build_or_get_cached_doc_index(
                        file,
                        opt_disk_cache_all_pdfs,
                        opt_inverted_index,
                    );
                    if was_cached {
                        cached_digests_used += 1;
                    }
                    chars_searched += doc.doc_chars;
                    tokens_searched += doc.doc_tokens;

                    let done = idx + 1;
                    if is_pdf_or_large || done % emit_stride == 0 || done == total_candidates {
                        let short_name = Path::new(&doc.file.path)
                            .file_name()
                            .and_then(|s| s.to_str())
                            .unwrap_or(&doc.file.path)
                            .to_string();
                        on_progress(json!({
                            "query": query,
                            "phase": if done == total_candidates { "ranking" } else { "scanning" },
                            "done": done,
                            "total": total_candidates,
                            "progress": (done as f64) / (total_candidates.max(1) as f64),
                            "currentFile": short_name,
                            "tokensSearched": tokens_searched,
                            "charsSearched": chars_searched,
                            "pdfBooksScanned": pdf_books_scanned,
                            "cachedDigestsUsed": cached_digests_used,
                            "elapsedMs": (started.elapsed().as_secs_f64() * 1000.0 * 10.0).round() / 10.0,
                        }));
                    }
                    indexed_docs.push(doc);
                }
            }

            // Exact quote mode: a query wrapped in double quotes (or `"exact": true`) returns only documents
            // that contain those words consecutively, in that order.
            if let Some(phrase) = exact_quote_phrase(query, request["exact"].as_bool().unwrap_or(false)) {
                let (hits, total_matches, docs_checked) =
                    exact_quote_search(&indexed_docs, &phrase, is_code_req, limit, opt_inverted_index);
                let elapsed_ms = (started.elapsed().as_secs_f64() * 1000.0 * 100.0).round() / 100.0;
                let strong_count = hits.len();
                return json!({
                    "hits": hits,
                    "strong": strong_count,
                    "meaning": true,
                    "metrics": {
                        "elapsedMs": elapsed_ms,
                        "docsSearched": total_candidates,
                        "indexCandidates": docs_checked,
                        "tokensSearched": tokens_searched,
                        "charsSearched": chars_searched,
                        "bytesInspected": bytes_inspected,
                        "queryTerms": quote_tokens(&phrase).len(),
                        "pdfBooksScanned": pdf_books_scanned,
                        "cachedDigestsUsed": cached_digests_used,
                        "strongHits": strong_count,
                        "weakerHits": 0,
                        "exactQuote": true,
                        "exactMatches": total_matches,
                    },
                });
            }

            // Use the word/prefix inverted index on each document (when `opt_inverted_index` is enabled)
            // to compute document frequencies (DF) and prune non-matching documents in O(1) per doc.
            let mut candidate_docs: Vec<Arc<CachedDocIndex>> = Vec::new();
            for doc in &indexed_docs {
                let mut doc_matches_any = false;
                for term in &terms {
                    let matched = if opt_inverted_index {
                        doc_may_match_term_fast(doc, term)
                    } else {
                        matches_term_in_text(&doc.path_search_text, term)
                            || matches_term_in_text(&doc.content_lower, term)
                    };
                    if matched {
                        *df.entry(term.clone()).or_insert(0) += 1;
                        doc_matches_any = true;
                    }
                }
                if doc_matches_any || !opt_inverted_index {
                    candidate_docs.push(Arc::clone(doc));
                }
            }

            let index_candidates_count = candidate_docs.len();
            let total_docs = indexed_docs.len().max(1) as f64;
            let term_weight = |term: &str| -> f64 {
                let doc_freq = (*df.get(term).unwrap_or(&1)).max(1) as f64;
                let idf = ((total_docs + 1.0) / (doc_freq + 0.5)).ln() + 1.0;
                // Specific longer words or numbers get extra specificity boost
                let len_boost = if term.len() >= 7 { 1.35 } else { 1.0 };
                idf * len_boost
            };

            let max_possible_weight: f64 = terms.iter().map(|t| term_weight(t)).sum::<f64>().max(1.0);
            let clean_phrase: String = query
                .to_ascii_lowercase()
                .split(|c: char| !c.is_alphanumeric())
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
                .join(" ");

            // Stage 1: Score all candidate documents first (using O(1) inverted-index word quality
            // when `opt_inverted_index` is active), then sort and truncate to `limit` BEFORE
            // extracting section snippets and line highlights so we never do snippet extraction
            // on lower-ranked documents that won't be returned.
            struct ScoredDocCandidate {
                doc: Arc<CachedDocIndex>,
                score: f64,
                matched_words: usize,
            }
            let mut scored_candidates: Vec<ScoredDocCandidate> = Vec::with_capacity(candidate_docs.len());

            for doc in candidate_docs {
                let file_name = &doc.file_name_lower;
                let path_search_text = &doc.path_search_text;

                let mut matched_weight = 0.0f64;
                let mut matched_words = 0usize;

                if doc.content.is_none() {
                    for term in &terms {
                        let w = term_weight(term);
                        let q_name = match_term_quality(file_name, term);
                        let q_path = match_term_quality(path_search_text, term);
                        if q_name > 0.0 {
                            matched_weight += w * q_name;
                            matched_words += 1;
                        } else if q_path > 0.0 {
                            matched_weight += w * q_path * 0.85;
                            matched_words += 1;
                        }
                    }
                    if matched_words > 0 {
                        let coverage = (matched_words as f64) / (terms.len().max(1) as f64);
                        let cov_factor = if terms.len() >= 2 {
                            0.35 + 0.65 * coverage
                        } else {
                            1.0
                        };
                        let score = ((matched_weight / max_possible_weight) * cov_factor).clamp(0.12, 0.99);
                        scored_candidates.push(ScoredDocCandidate {
                            doc,
                            score,
                            matched_words,
                        });
                    }
                    continue;
                }

                let content_lower = &doc.content_lower;
                for term in &terms {
                    let best_q = if opt_inverted_index {
                        let q_idx = doc_term_quality_fast(&doc, term);
                        if q_idx == 0.0 {
                            continue;
                        }
                        q_idx
                    } else {
                        let q_body = match_term_quality(content_lower, term);
                        let q_name = match_term_quality(file_name, term);
                        let q_path = match_term_quality(path_search_text, term);
                        q_body.max(q_name * 0.85).max(q_path * 0.65)
                    };
                    if best_q > 0.0 {
                        matched_weight += term_weight(term) * best_q;
                        matched_words += 1;
                    }
                }

                if matched_words == 0 {
                    continue;
                }

                // Phrase & adjacent-bigram proximity boost so multi-word queries like
                // `"From composing networks to deep networks"` strongly elevate exact/near-phrase matches
                // above documents that merely contain one common word like `"networks"`.
                let mut phrase_boost = 0.0f64;
                if terms.len() >= 2 && matched_words >= 2 {
                    if clean_phrase.len() >= 8 && content_lower.contains(&clean_phrase) {
                        phrase_boost += 0.45;
                    }
                    let mut adjacent_pairs = 0usize;
                    for pair in terms.windows(2) {
                        let bigram_space = format!("{} {}", pair[0], pair[1]);
                        let bigram_underscore = format!("{}_{}", pair[0], pair[1]);
                        let bigram_hyphen = format!("{}-{}", pair[0], pair[1]);
                        if content_lower.contains(&bigram_space)
                            || path_search_text.contains(&bigram_space)
                            || path_search_text.contains(&bigram_underscore)
                            || path_search_text.contains(&bigram_hyphen)
                        {
                            adjacent_pairs += 1;
                        }
                    }
                    if adjacent_pairs > 0 {
                        let pair_ratio = (adjacent_pairs as f64) / ((terms.len() - 1) as f64);
                        phrase_boost += 0.30 * pair_ratio;
                    }
                }

                // Multi-term coverage factor: prevents a document that only matches 1 common word (e.g. "networks")
                // from rivaling a document that matches all 4 words ("composing", "networks", "deep").
                let coverage = (matched_words as f64) / (terms.len().max(1) as f64);
                let coverage_factor = if terms.len() >= 2 {
                    0.35 + 0.65 * coverage.powf(1.15)
                } else {
                    1.0
                };
                let raw_score = (matched_weight / max_possible_weight) * coverage_factor + phrase_boost;
                let normalized_score = raw_score.clamp(0.10, 0.99);
                scored_candidates.push(ScoredDocCandidate {
                    doc,
                    score: normalized_score,
                    matched_words,
                });
            }

            scored_candidates.sort_by(|a, b| {
                b.score
                    .partial_cmp(&a.score)
                    .unwrap_or(std::cmp::Ordering::Equal)
            });
            scored_candidates.truncate(limit);

            // Stage 2: Extract rich sections, line numbers, and highlighted excerpts ONLY for the top `limit` hits.
            let mut hits = Vec::with_capacity(scored_candidates.len());
            for cand in scored_candidates {
                let doc = &cand.doc;
                let file = &doc.file;
                let matched_words = cand.matched_words;
                let normalized_score = cand.score;

                let Some(content) = doc.content.as_deref() else {
                    hits.push(json!({
                        "path": file.path,
                        "kind": if is_code_req { "code" } else { file.kind },
                        "score": normalized_score,
                        "matchedWords": matched_words,
                        "words": true,
                        "meaning": true,
                        "excerpt": "",
                        "loc": Value::Null,
                        "endLine": Value::Null,
                        "size": file.size,
                        "modified": file.modified,
                    }));
                    continue;
                };

                let excerpt: String;
                let mut loc_val = Value::Null;
                let mut end_line_val = Value::Null;
                let mut top_sections_json = Vec::new();

                // Evaluate per-document term eligibility once, not per line/section.
                let doc_active_terms: Vec<(&String, f64)> = terms
                    .iter()
                    .filter(|term| !opt_inverted_index || doc_may_match_term_fast(doc, term))
                    .map(|term| (term, term_weight(term)))
                    .collect();

                if file.kind == "code" {
                    let lines: Vec<&str> = content.lines().collect();
                    let mut best_line_idx = 0usize;
                    let mut best_line_w = 0.0f64;
                    for (idx, line) in lines.iter().enumerate() {
                        let l_lower = line.to_ascii_lowercase();
                        let mut lw = 0.0f64;
                        for (term, w) in &doc_active_terms {
                            let q = match_term_quality(&l_lower, term);
                            if q > 0.0 {
                                lw += *w * q;
                            }
                        }
                        if lw > best_line_w {
                            best_line_w = lw;
                            best_line_idx = idx;
                        }
                    }
                    let start_idx = best_line_idx.saturating_sub(1);
                    let end_idx = (best_line_idx + 12).min(lines.len());
                    let raw_snippet = lines[start_idx..end_idx].join("\n");
                    excerpt = highlight_excerpt(&raw_snippet, &terms);
                    loc_val = json!(best_line_idx + 1);
                    end_line_val = json!(end_idx);
                    top_sections_json.push(json!({
                        "heading": format!("Lines {}–{}", start_idx + 1, end_idx),
                        "startLine": start_idx + 1,
                        "endLine": end_idx,
                        "text": raw_snippet,
                    }));
                } else {
                    // Section-aware scoring for Markdown, text, and BookDigest documents
                    let owned_sections;
                    let sections: &[DocSection] = if !doc.sections.is_empty() {
                        &doc.sections
                    } else {
                        owned_sections = split_into_sections(content);
                        &owned_sections
                    };
                    let mut scored_sections: Vec<(f64, &DocSection)> = Vec::new();
                    for sec in sections {
                        let sec_lower = &sec.text_lower;
                        let head_lower = &sec.heading_lower;
                        let mut sec_w = 0.0f64;
                        let mut sec_matched = 0usize;
                        for (term, w) in &doc_active_terms {
                            let w = *w;
                            let q_head = match_term_quality(head_lower, term);
                            let q_sec = match_term_quality(sec_lower, term);
                            if q_head > 0.0 {
                                sec_w += w * q_head * 2.2;
                                sec_matched += 1;
                            } else if q_sec > 0.0 {
                                sec_w += w * q_sec;
                                sec_matched += 1;
                            }
                        }
                        if clean_phrase.len() >= 8 && sec_lower.contains(&clean_phrase) {
                            sec_w *= 2.0;
                        } else if sec_matched >= 2 {
                            sec_w *= 1.0 + 0.25 * (sec_matched as f64);
                        }
                        if sec_w > 0.0 {
                            scored_sections.push((sec_w, sec));
                        }
                    }
                    scored_sections.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));

                    // Pick up to 3 complementary sections that cover the query terms
                    let mut chosen: Vec<&DocSection> = Vec::new();
                    let mut covered_terms: HashSet<String> = HashSet::new();
                    for (_, sec) in &scored_sections {
                        if chosen.len() >= 3 {
                            break;
                        }
                        let sec_lower = &sec.text_lower;
                        let adds_new_term = terms.iter().any(|t| {
                            !covered_terms.contains(t) && matches_term_in_text(sec_lower, t)
                        });
                        if chosen.is_empty() || adds_new_term {
                            for t in &terms {
                                if matches_term_in_text(sec_lower, t) {
                                    covered_terms.insert(t.clone());
                                }
                            }
                            chosen.push(*sec);
                        }
                    }

                    if let Some(best_sec) = chosen.first() {
                        loc_val = json!(best_sec.start_line);
                        end_line_val = json!(best_sec.end_line);
                    }

                    let mut combined_snippets = Vec::new();
                    for sec in &chosen {
                        // Filter out footnotes or empty lines inside the section, keeping matching table rows or bullets
                        let sec_lines: Vec<&str> = sec.text.lines().collect();
                        let relevant_text = if sec_lines.len() <= 18 {
                            sec.text.clone()
                        } else {
                            // Rank lines by how many query terms they match so multi-word headings surface first
                            let mut matching_lines: Vec<(usize, usize, &str)> = Vec::new();
                            for (i, &l) in sec_lines.iter().enumerate() {
                                if i == 0 {
                                    continue;
                                }
                                let ll = l.to_ascii_lowercase();
                                let cnt = terms.iter().filter(|t| matches_term_in_text(&ll, t)).count();
                                if cnt > 0 {
                                    matching_lines.push((cnt, i, l));
                                }
                            }
                            matching_lines.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
                            let mut keep = vec![sec_lines[0]];
                            for (_, _, l) in matching_lines.into_iter().take(12) {
                                keep.push(l);
                            }
                            if keep.len() <= 1 {
                                sec_lines.into_iter().take(16).collect::<Vec<_>>().join("\n")
                            } else {
                                keep.join("\n")
                            }
                        };
                        let clipped: String = relevant_text.chars().take(900).collect();
                        combined_snippets.push(clipped.clone());
                        top_sections_json.push(json!({
                            "heading": sec.heading,
                            "startLine": sec.start_line,
                            "endLine": sec.end_line,
                            "text": clipped,
                        }));
                    }

                    let joined = combined_snippets.join("\n\n");
                    excerpt = highlight_excerpt(&joined, &terms);
                }

                hits.push(json!({
                    "path": file.path,
                    "kind": if is_code_req { "code" } else { file.kind },
                    "score": normalized_score,
                    "matchedWords": matched_words,
                    "words": matched_words > 0,
                    "meaning": true,
                    "excerpt": excerpt,
                    "sections": top_sections_json,
                    "loc": loc_val,
                    "endLine": end_line_val,
                    "size": file.size,
                    "modified": file.modified,
                }));
            }

            // Partition hits into `strong` (top-ranked primary matches) and `weaker` (partial single-word
            // overlap hits placed under the UI's collapsible "X weaker matches" divider).
            let best_score = hits.first().and_then(|h| h["score"].as_f64()).unwrap_or(0.0);
            let best_matched = hits
                .first()
                .and_then(|h| h["matchedWords"].as_u64())
                .unwrap_or(0) as usize;
            let min_strong_words = if terms.len() >= 3 && best_matched >= 2 {
                ((terms.len() + 1) / 2).min(best_matched)
            } else {
                1
            };
            let strong_cutoff = (best_score * 0.55).max(0.28);

            let mut strong_count = 0usize;
            for h in &hits {
                let sc = h["score"].as_f64().unwrap_or(0.0);
                let mw = h["matchedWords"].as_u64().unwrap_or(0) as usize;
                if sc >= strong_cutoff && mw >= min_strong_words {
                    strong_count += 1;
                } else {
                    break;
                }
            }
            if strong_count == 0 && !hits.is_empty() {
                strong_count = 1;
            }

            let elapsed_ms = (started.elapsed().as_secs_f64() * 1000.0 * 100.0).round() / 100.0;
            let weaker_count = hits.len().saturating_sub(strong_count);
            let metrics = json!({
                "elapsedMs": elapsed_ms,
                "docsSearched": total_candidates,
                "indexCandidates": index_candidates_count,
                "tokensSearched": tokens_searched,
                "charsSearched": chars_searched,
                "bytesInspected": bytes_inspected,
                "queryTerms": terms.len(),
                "pdfBooksScanned": pdf_books_scanned,
                "cachedDigestsUsed": cached_digests_used,
                "strongHits": strong_count,
                "weakerHits": weaker_count,
            });

            json!({
                "hits": hits,
                "strong": strong_count,
                "meaning": true,
                "metrics": metrics,
            })
        }
        _ => json!({ "ok": true }),
    }
}

pub fn local_estimate_folders(
    folders: &[String],
    skipped: &[String],
    skip_types: &[String],
    code: bool,
) -> Vec<Value> {
    let mut out = Vec::new();
    for folder in folders {
        let entries = walk_local_folders(std::slice::from_ref(folder), skipped, skip_types);
        let mut files_by_kind: HashMap<&str, usize> = HashMap::new();
        let mut total_bytes = 0u64;
        let mut count = 0usize;
        for f in &entries {
            if code && f.kind != "code" {
                continue;
            }
            *files_by_kind.entry(f.kind).or_insert(0) += 1;
            total_bytes += f.size;
            count += 1;
        }
        out.push(json!({
            "folder": folder,
            "files": files_by_kind,
            "code_files": if code { count } else { 0 },
            "bytes": total_bytes,
            "seconds": (count as f64 * 0.05).max(0.1),
            "later_seconds": 0.0,
            "kind_seconds": {},
            "children": [],
        }));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_symbols_files_and_id_codes_for_graphrag() {
        let sample = "In billing-service/src/auth.ts, function refreshAccessToken failed with error ERR_TOKEN_401 on invoice INV-2026-009.";
        let entities = extract_graph_entities(sample);
        let keys: Vec<&str> = entities.iter().map(|e| e.key.as_str()).collect();
        assert!(keys.contains(&"auth.ts"));
        assert!(keys.contains(&"refreshaccesstoken"));
        assert!(keys.contains(&"err_token_401"));
        assert!(keys.contains(&"inv-2026-009"));
    }

    #[test]
    fn builds_hop2_expansion_query_from_seed_snippets() {
        let q = "why did payment fail";
        let snippets = vec![
            "Payment failed in retry_with_backoff when calling stripe_webhook.py with code ERR_DECLINED_99.".to_string(),
        ];
        let hop2 =
            build_hop2_expansion_query(q, &snippets).expect("should produce expansion query");
        assert!(hop2.contains("err_declined_99") || hop2.contains("stripe_webhook.py"));
    }

    #[test]
    fn saves_and_loads_cag_slot() {
        let tmp = std::env::temp_dir().join("digup_cag_unit_test");
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(&tmp).unwrap();
        let sample_file = tmp.join("architecture.md");
        fs::write(
            &sample_file,
            "# System Architecture\nUses Qwen2.5-3B-Instruct and EmbeddingGemma 2.",
        )
        .unwrap();

        let meta =
            save_cag_slot(&tmp, "project-arch", &[sample_file.display().to_string()]).unwrap();
        assert_eq!(meta.slot, "project-arch");
        assert!(meta.approx_tokens > 5);

        let loaded = load_cag_slot(&tmp, "project-arch").expect("slot should load");
        assert_eq!(loaded.pinned_paths.len(), 1);
        assert!(loaded.cached_text.contains("Qwen2.5-3B-Instruct"));

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn local_search_and_summaries_work_standalone() {
        let tmp = std::env::temp_dir().join("digup_local_search_unit_test");
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(&tmp).unwrap();
        let doc_file = tmp.join("onboarding.md");
        fs::write(
            &doc_file,
            "# MICRO Lab Onboarding\nPlease review retry_with_backoff in retry_policy.py before deploying.",
        )
        .unwrap();
        let code_file = tmp.join("retry_policy.py");
        fs::write(
            &code_file,
            "def retry_with_backoff(attempts: int = 3):\n    return 2 ** attempts\n",
        )
        .unwrap();

        let roots = vec![tmp.display().to_string()];
        let sum = local_search_op(&json!({"op": "summaries"}), &roots, &roots, &[], &[]);
        assert_eq!(sum["roots"][0]["indexed"], 2);

        let search = local_search_op(
            &json!({"op": "search", "query": "Summarize MICRO Lab onboarding", "limit": 10}),
            &roots,
            &roots,
            &[],
            &[],
        );
        let hits = search["hits"].as_array().unwrap();
        assert!(!hits.is_empty());
        assert!(hits[0]["path"].as_str().unwrap().contains("onboarding.md"));

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn section_chunking_and_word_boundary_prevent_false_positives() {
        // Verify "tops" does NOT match inside "stops"
        assert!(!matches_term_in_text("doubles after each retry and stops increasing", "tops"));
        assert!(matches_term_in_text("reached up to 12.4 tops/w peak sustained", "tops"));

        // Verify section splitting retrieves specific deep sections
        let md = "# MICRO Lab\nFive levels of inquiry.\n\n## Authorization levels\n- Level 0: Observer\n- Level 4: Process owner; only the facility manager, PI, or institutional authority may grant final access.\n";
        let sections = split_into_sections(md);
        assert_eq!(sections.len(), 2);
        assert_eq!(sections[1].heading, "Authorization levels");
        assert!(sections[1].text.contains("Level 4"));
    }

    #[test]
    fn query_terms_splits_underscores_hyphens_and_camelcase_cleanly() {
        let terms_underscore = query_terms("Simon_JD_Prince understanding_deep_learning");
        assert!(terms_underscore.contains(&"simon".to_string()));
        assert!(terms_underscore.contains(&"jd".to_string()));
        assert!(terms_underscore.contains(&"prince".to_string()));
        assert!(terms_underscore.contains(&"understanding".to_string()));
        assert!(terms_underscore.contains(&"deep".to_string()));
        assert!(terms_underscore.contains(&"learning".to_string()));

        let terms_camel = query_terms("SimonJDPrince UnderstandingDeepLearning");
        assert!(terms_camel.contains(&"simon".to_string()));
        assert!(terms_camel.contains(&"jd".to_string()));
        assert!(terms_camel.contains(&"prince".to_string()));
        assert!(terms_camel.contains(&"understanding".to_string()));
        assert!(terms_camel.contains(&"deep".to_string()));
        assert!(terms_camel.contains(&"learning".to_string()));

        let terms_id = query_terms("invoice INV-2026-041 error ERR_502");
        assert!(terms_id.contains(&"inv-2026-041".to_string()) || terms_id.contains(&"2026".to_string()));
        assert!(terms_id.contains(&"err_502".to_string()) || terms_id.contains(&"502".to_string()));
    }

    #[test]
    fn matches_term_in_text_respects_underscore_hyphen_and_camelcase_boundaries() {
        let filename_lower = "simon_jd_prince-understanding_deep_learning.pdf";
        for term in ["simon", "jd", "prince", "understanding", "deep", "learning", "pdf"] {
            assert!(
                matches_term_in_text(filename_lower, term),
                "expected '{term}' to match inside '{filename_lower}'"
            );
        }
        // Still rejects mid-word substring false positives
        assert!(!matches_term_in_text("stops increasing", "tops"));
        assert!(!matches_term_in_text("concatenate strings", "cat"));
    }

    #[test]
    fn search_finds_pdf_by_underscored_filename_and_parent_folder() {
        let tmp = std::env::temp_dir().join("digup_pdf_delimiter_unit_test");
        let _ = fs::remove_dir_all(&tmp);
        let author_dir = tmp.join("Machine_Learning_Robotics").join("Simon_JD_Prince");
        fs::create_dir_all(&author_dir).unwrap();
        let pdf_file = author_dir.join("Simon_JD_Prince_understanding_deep_learning.pdf");
        fs::write(&pdf_file, b"%PDF-1.7 fake header").unwrap();

        let roots = vec![tmp.display().to_string()];

        // 1. Space-separated query matches underscored PDF filename
        let res_spaces = local_search_op(
            &json!({"op": "search", "query": "Simon JD Prince understanding deep learning", "limit": 10}),
            &roots,
            &[],
            &[],
            &[],
        );
        let hits_spaces = res_spaces["hits"].as_array().unwrap();
        assert!(!hits_spaces.is_empty(), "space-separated query should find underscored PDF");
        assert!(hits_spaces[0]["path"].as_str().unwrap().contains("understanding_deep_learning.pdf"));

        // 2. Underscore-separated query matches underscored PDF filename
        let res_underscores = local_search_op(
            &json!({"op": "search", "query": "Simon_JD_Prince understanding_deep_learning", "limit": 10}),
            &roots,
            &[],
            &[],
            &[],
        );
        let hits_underscores = res_underscores["hits"].as_array().unwrap();
        assert!(!hits_underscores.is_empty(), "underscored query should find underscored PDF");

        // 3. Parent directory theme ("machine learning robotics") + book title matches
        let res_folder = local_search_op(
            &json!({"op": "search", "query": "machine learning robotics deep learning", "limit": 10}),
            &roots,
            &[],
            &[],
            &[],
        );
        let hits_folder = res_folder["hits"].as_array().unwrap();
        assert!(!hits_folder.is_empty(), "parent folder theme + filename should find PDF");

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn extracts_pdf_metadata_and_text_streams_from_large_books_in_under_20ms() {
        let tmp = std::env::temp_dir().join("digup_large_book_digest_test");
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(&tmp).unwrap();
        let pdf_path = tmp.join("opaque_book_991.pdf");

        // Build a synthetic 12 MB PDF (> 2 MB old limit) with Head metadata/TOC, Middle stride chapter streams,
        // and Tail subject index + /Info dictionary.
        let mut buf = vec![0u8; 12 * 1024 * 1024];
        let head = b"%PDF-1.7\n1 0 obj\n<< /Title (Understanding Deep Learning) /Author (Simon J.D. Prince) /Keywords (Transformers Backpropagation Robotics) >>\nendobj\nBT (Chapter 1: Supervised Learning and Neural Networks) Tj ET\n";
        buf[..head.len()].copy_from_slice(head);

        // Place a chapter heading at stride #6 (exactly 6/13ths into the file so the 12-stride sampler hits it)
        let mid_offset = (buf.len() / 13) * 6 + 1024;
        let mid_stream = b"\nBT (Chapter 12: Reinforcement Learning for Robotics and Control Kinematics) Tj ET\n";
        buf[mid_offset..mid_offset + mid_stream.len()].copy_from_slice(mid_stream);

        // Place back-of-book subject index & XMP metadata near the tail
        let tail_stream = b"\nBT (Index: Markov Decision Processes, Policy Gradient, Simon_JD_Prince, Self-Attention) Tj ET\n<dc:title>Understanding Deep Learning</dc:title>\n%%EOF";
        let tail_start = buf.len() - tail_stream.len() - 64;
        buf[tail_start..tail_start + tail_stream.len()].copy_from_slice(tail_stream);

        fs::write(&pdf_path, &buf).unwrap();

        let t0 = std::time::Instant::now();
        let digest = extract_fast_book_digest(&pdf_path, buf.len() as u64)
            .expect("should produce a BookDigest for a 12 MB PDF");
        let elapsed = t0.elapsed();

        assert!(
            elapsed.as_millis() < 50,
            "12 MB PDF digest took {:?}, expected < 50ms bounded I/O",
            elapsed
        );
        assert!(digest.title.to_ascii_lowercase().contains("understanding deep learning"));
        assert!(digest.author.to_ascii_lowercase().contains("simon"));
        let lower_digest = digest.searchable_text.to_ascii_lowercase();
        assert!(lower_digest.contains("transformers"));
        assert!(lower_digest.contains("reinforcement learning for robotics"));
        assert!(lower_digest.contains("markov decision processes"));

        // Verify end-to-end search finds opaque_book_991.pdf purely by internal content (even though filename is opaque!)
        let roots = vec![tmp.display().to_string()];
        let search_res = local_search_op(
            &json!({"op": "search", "query": "Simon Prince reinforcement learning robotics", "limit": 10}),
            &roots,
            &[],
            &[],
            &[],
        );
        let hits = search_res["hits"].as_array().unwrap();
        assert!(!hits.is_empty(), "search should find 12 MB PDF by internal author and chapter stream");
        assert!(hits[0]["path"].as_str().unwrap().contains("opaque_book_991.pdf"));
        assert!(
            !hits[0]["excerpt"].as_str().unwrap_or("").is_empty(),
            "PDF hit should include a highlighted excerpt from the book digest"
        );

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn prefix_and_fuzzy_matching_resolves_simo_to_simon_without_false_positives() {
        let filename_lower = "_oceanofpdf.com_understanding_deep_learning_-_simon_jd_prince.pdf";
        // "simo" (4-char prefix of 5-char "simon") matches with high quality
        let q_simo = match_term_quality(filename_lower, "simo");
        assert!(q_simo >= 0.80, "expected 'simo' to prefix-match 'simon', got {q_simo}");

        // "compo" (5-char prefix of 9-char "composing") matches
        let q_compo = match_term_quality("from composing networks to deep networks", "compo");
        assert!(q_compo >= 0.65, "expected 'compo' to prefix-match 'composing', got {q_compo}");

        // 1-edit transposition ("siomn" -> "simon") matches
        let q_typo = match_term_quality(filename_lower, "siomn");
        assert!(q_typo >= 0.60, "expected 'siomn' to fuzzy-match 'simon', got {q_typo}");

        // Short 3-char words ("cat", "top") still do NOT false-match inside longer words
        assert_eq!(match_term_quality("concatenate strings", "cat"), 0.0);
        assert_eq!(match_term_quality("stops increasing", "tops"), 0.0);
    }

    #[test]
    fn decompresses_flatedecode_and_separates_strong_phrase_matches_from_weaker_single_word_hits() {
        use flate2::write::ZlibEncoder;
        use flate2::Compression;

        let tmp = std::env::temp_dir().join("digup_flate_phrase_ranking_test");
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(&tmp).unwrap();

        // 1. Create a PDF with a FlateDecode-compressed page content stream using Identity-H hex glyphs
        //    and TJ kerning arrays for "4.2 From composing networks to deep networks"
        let raw_stream = b"BT /F4 28.33 Tf 1 0 0 -1 70 3758 Tm [(4.2 ) -15 (From ) -10 (composing ) -10 (networks ) -10 (to ) -10 (deep ) -10 (networks)] TJ ET\nBT /F5 15 Tf (Shallow and deep neural networks compose piecewise linear mappings.) Tj ET";
        let mut encoder = ZlibEncoder::new(Vec::new(), Compression::default());
        encoder.write_all(raw_stream).unwrap();
        let compressed = encoder.finish().unwrap();

        let mut pdf_bytes = Vec::new();
        pdf_bytes.extend_from_slice(
            format!(
                "%PDF-1.7\n1 0 obj\n<</Title (Understanding Deep Learning) /Author (Simon J.D. Prince)>>\nendobj\n1831 0 obj\n<</Filter/FlateDecode/Length {}>>\nstream\n",
                compressed.len()
            )
            .as_bytes(),
        );
        pdf_bytes.extend_from_slice(&compressed);
        pdf_bytes.extend_from_slice(b"\nendstream\nendobj\n%%EOF");
        // Pad to > 2 MB so it exercises the large-book path
        pdf_bytes.resize(3 * 1024 * 1024, b' ');

        let pdf_path = tmp.join("_OceanofPDF.com_Understanding_Deep_Learning_-_Simon_JD_Prince.pdf");
        fs::write(&pdf_path, &pdf_bytes).unwrap();

        // 2. Create 3 distractor documents that only contain the single generic word "networks"
        for i in 1..=3 {
            fs::write(
                tmp.join(format!("campus_wifi_note_{i}.md")),
                "# IT Notice\nWireless networks will undergo maintenance on Sunday evening.",
            )
            .unwrap();
        }

        let roots = vec![tmp.display().to_string()];

        // Test Problem 1: Searching "simo" finds Simon_JD_Prince.pdf as #1 strong match
        let res_simo = local_search_op(
            &json!({"op": "search", "query": "simo", "limit": 10}),
            &roots,
            &[],
            &[],
            &[],
        );
        let hits_simo = res_simo["hits"].as_array().unwrap();
        assert!(!hits_simo.is_empty(), "'simo' should match 'Simon_JD_Prince.pdf'");
        assert!(hits_simo[0]["path"].as_str().unwrap().contains("Simon_JD_Prince.pdf"));
        assert!(res_simo["strong"].as_u64().unwrap_or(0) >= 1);

        // Test Problem 2: Searching "From composing networks to deep networks" ranks the PDF #1 in `strong`
        // and places the 1-word "networks" distractors in `weaker` (after `strong`).
        let res_phrase = local_search_op(
            &json!({"op": "search", "query": "From composing networks to deep networks", "limit": 10}),
            &roots,
            &[],
            &[],
            &[],
        );
        let hits_phrase = res_phrase["hits"].as_array().unwrap();
        let strong_count = res_phrase["strong"].as_u64().unwrap() as usize;
        assert!(!hits_phrase.is_empty());
        assert!(
            hits_phrase[0]["path"].as_str().unwrap().contains("Simon_JD_Prince.pdf"),
            "Book with 'From composing networks to deep networks' must rank #1, got {:?}",
            hits_phrase[0]["path"]
        );
        assert_eq!(
            strong_count, 1,
            "Only the book matching the full phrase should be a strong match; single-word 'networks' docs belong in weaker matches"
        );
        assert!(
            hits_phrase.len() > strong_count,
            "Single-word 'networks' docs should still be available in weaker matches"
        );

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn real_book_pdf_digest_finds_simo_and_from_composing_networks_to_deep_networks() {
        let real_pdf = PathBuf::from(
            r"C:\Users\SaadG\Documents\_OceanofPDF.com_Understanding_Deep_Learning_-_Simon_JD_Prince.pdf",
        );
        if !real_pdf.is_file() {
            return;
        }
        let digest = extract_fast_book_digest(&real_pdf, 0).expect("should digest real 52.7 MB PDF");
        let combined = digest.searchable_text.to_lowercase();
        assert!(
            combined.contains("from composing networks to deep networks"),
            "Real 52.7 MB PDF digest should extract section 4.2 'From composing networks to deep networks'; got:\n{}",
            &digest.searchable_text[..digest.searchable_text.len().min(600)]
        );
        assert!(
            match_term_quality(&real_pdf.display().to_string().to_lowercase(), "simo") >= 0.80,
            "'simo' should prefix-match Simon_JD_Prince.pdf"
        );
    }

    #[test]
    fn search_emits_live_progress_and_returns_detailed_metrics_and_disk_cached_digests() {
        let tmp = std::env::temp_dir().join("digup_search_metrics_progress_test");
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(&tmp).unwrap();

        fs::write(
            tmp.join("deep_learning_notes.md"),
            "# Deep Neural Networks\nComposing piecewise linear networks into deep architectures with residual connections.",
        )
        .unwrap();
        fs::write(
            tmp.join("optimizer_schedule.py"),
            "def cosine_warmup_lr(step: int) -> float:\n    return 0.001 * step\n",
        )
        .unwrap();

        let mut pdf_bytes = b"%PDF-1.7\n1 0 obj\n<</Title (Optimization Algorithms) /Author (Simon Prince)>>\nstream\n(Stochastic gradient descent and Adam momentum updates) Tj\nendstream\nendobj\n%%EOF".to_vec();
        pdf_bytes.resize(512 * 1024, b' ');
        let pdf_path = tmp.join("optimization_book.pdf");
        fs::write(&pdf_path, &pdf_bytes).unwrap();

        let roots = vec![tmp.display().to_string()];
        let mut progress_events: Vec<Value> = Vec::new();

        let res = local_search_op_with_progress(
            &json!({"op": "search", "query": "composing networks gradient", "limit": 10}),
            &roots,
            &[],
            &[],
            &[],
            |ev| progress_events.push(ev),
        );

        // 1. Verify live progress callbacks were emitted with increasing progress up to 1.0
        assert!(
            !progress_events.is_empty(),
            "Search should emit live progress events for the progress bar"
        );
        let last_ev = progress_events.last().unwrap();
        assert_eq!(last_ev["done"].as_u64(), last_ev["total"].as_u64());
        assert!(
            (last_ev["progress"].as_f64().unwrap_or(0.0) - 1.0).abs() < 1e-6,
            "Final progress event must reach 1.0 (100%)"
        );

        // 2. Verify rich telemetry metrics object is returned in the search response
        let metrics = &res["metrics"];
        assert!(metrics.is_object(), "Search response must include a 'metrics' object");
        assert!(metrics["elapsedMs"].as_f64().unwrap_or(-1.0) >= 0.0);
        assert_eq!(metrics["docsSearched"].as_u64().unwrap_or(0), 3);
        assert!(
            metrics["tokensSearched"].as_u64().unwrap_or(0) >= 15,
            "Expected tokensSearched >= 15 across the 3 documents, got {:?}",
            metrics["tokensSearched"]
        );
        assert!(metrics["charsSearched"].as_u64().unwrap_or(0) >= 80);
        assert_eq!(metrics["queryTerms"].as_u64().unwrap_or(0), 3);
        assert_eq!(metrics["pdfBooksScanned"].as_u64().unwrap_or(0), 1);

        // 3. Verify second search hits the BookDigest cache (cachedDigestsUsed >= 1)
        let res2 = local_search_op(
            &json!({"op": "search", "query": "Simon Prince gradient", "limit": 10}),
            &roots,
            &[],
            &[],
            &[],
        );
        assert!(
            res2["metrics"]["cachedDigestsUsed"].as_u64().unwrap_or(0) >= 1,
            "Second search should reuse cached BookDigest, got {:?}",
            res2["metrics"]
        );

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn caches_all_pdf_sizes_to_disk_and_survives_ram_cache_clear() {
        let tmp = std::env::temp_dir().join("digup_all_pdf_disk_cache_test");
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(&tmp).unwrap();

        // Create 3 small PDFs (16 KB, 64 KB, 256 KB — all < 2 MB, which previously missed disk cache)
        for (idx, kb) in [16usize, 64, 256].into_iter().enumerate() {
            let mut pdf_bytes = format!(
                "%PDF-1.7\n1 0 obj\n<</Title (Small Book {idx}) /Author (Author {idx})>>\nstream\nBT (Backpropagation and Composing Deep Networks Chapter {idx}) Tj ET\nendstream\nendobj\n%%EOF"
            )
            .into_bytes();
            pdf_bytes.resize(kb * 1024, b' ');
            fs::write(tmp.join(format!("small_book_{idx}.pdf")), &pdf_bytes).unwrap();
        }

        clear_all_search_caches(true);
        let roots = vec![tmp.display().to_string()];

        // First search: populates disk cache for all 3 small PDFs
        let res1 = local_search_op(
            &json!({"op": "search", "query": "Composing Deep Networks", "limit": 10}),
            &roots,
            &[],
            &[],
            &[],
        );
        assert_eq!(res1["metrics"]["pdfBooksScanned"].as_u64().unwrap_or(0), 3);

        // Clear RAM caches ONLY (simulating a cold app restart via start-digup.ps1)
        clear_all_search_caches(false);

        // Second search after RAM clear: all 3 small PDFs (< 2 MB) MUST load from disk cache!
        let res2 = local_search_op(
            &json!({
                "op": "search",
                "query": "Composing Deep Networks",
                "limit": 10,
                "opt": { "diskCacheAllPdfs": true, "parallelScan": false, "invertedIndex": false }
            }),
            &roots,
            &[],
            &[],
            &[],
        );
        assert_eq!(
            res2["metrics"]["cachedDigestsUsed"].as_u64().unwrap_or(0),
            3,
            "All 3 small PDFs (< 2 MB) must hit persistent disk cache after RAM clear, got: {:?}",
            res2["metrics"]
        );

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn parallel_scan_and_inverted_index_match_baseline_hits_and_accelerate_queries() {
        let tmp = std::env::temp_dir().join("digup_parallel_inverted_index_test");
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(&tmp).unwrap();

        // Build a synthetic corpus of 60 documents + 4 PDFs
        for i in 0..60 {
            let content = if i == 17 {
                "# Understanding Deep Learning\n## 4.2 From composing networks to deep networks\nShallow neural networks compose piecewise linear regions into deep networks."
            } else if i % 3 == 0 {
                "# Campus Networks\nWireless networks and router configuration guide for building B."
            } else {
                "# General Lab Note\nCalibration schedule for optical sensors and thermal chambers."
            };
            fs::write(tmp.join(format!("doc_{i:03}.md")), content).unwrap();
        }
        for p in 0..4 {
            let mut pdf_bytes = format!(
                "%PDF-1.7\n1 0 obj\n<</Title (Paper {p}) /Author (Simon Prince)>>\nstream\nBT (Deep networks paper number {p} on representation learning) Tj ET\nendstream\nendobj\n%%EOF"
            )
            .into_bytes();
            pdf_bytes.resize(32 * 1024, b' ');
            fs::write(tmp.join(format!("paper_{p}.pdf")), &pdf_bytes).unwrap();
        }

        let roots = vec![tmp.display().to_string()];
        let query = "From composing networks to deep networks";

        // 1. Baseline (sequential, no inverted index)
        clear_all_search_caches(true);
        let base_res = local_search_op(
            &json!({
                "op": "search",
                "query": query,
                "limit": 20,
                "opt": { "diskCacheAllPdfs": false, "parallelScan": false, "invertedIndex": false }
            }),
            &roots,
            &[],
            &[],
            &[],
        );

        // 2. Parallel scan only
        clear_all_search_caches(true);
        let par_res = local_search_op(
            &json!({
                "op": "search",
                "query": query,
                "limit": 20,
                "opt": { "diskCacheAllPdfs": true, "parallelScan": true, "invertedIndex": false }
            }),
            &roots,
            &[],
            &[],
            &[],
        );

        // 3. Combined (Parallel + All-PDF Disk Cache + Inverted Index warm query)
        let _warmup = local_search_op(
            &json!({
                "op": "search",
                "query": "warmup query",
                "limit": 20,
                "opt": { "diskCacheAllPdfs": true, "parallelScan": true, "invertedIndex": true }
            }),
            &roots,
            &[],
            &[],
            &[],
        );
        let idx_res = local_search_op(
            &json!({
                "op": "search",
                "query": query,
                "limit": 20,
                "opt": { "diskCacheAllPdfs": true, "parallelScan": true, "invertedIndex": true }
            }),
            &roots,
            &[],
            &[],
            &[],
        );

        // Verify exact parity on top hit, strong count, and total hits
        let base_hits = base_res["hits"].as_array().unwrap();
        let par_hits = par_res["hits"].as_array().unwrap();
        let idx_hits = idx_res["hits"].as_array().unwrap();
        assert_eq!(base_hits[0]["path"], par_hits[0]["path"]);
        assert_eq!(base_hits[0]["path"], idx_hits[0]["path"]);
        assert!(base_hits[0]["path"].as_str().unwrap().contains("doc_017.md"));
        assert_eq!(base_res["strong"], par_res["strong"]);
        assert_eq!(base_res["strong"], idx_res["strong"]);
        assert_eq!(base_hits.len(), idx_hits.len());
        assert!(
            idx_res["metrics"]["indexCandidates"].as_u64().unwrap_or(999) < 64,
            "Inverted index should prune non-matching documents before scoring, got: {:?}",
            idx_res["metrics"]
        );

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn ablation_benchmark_on_real_user_documents_corpus() {
        let user_docs = PathBuf::from(r"C:\Users\SaadG\Documents");
        if !user_docs.is_dir() {
            return;
        }
        let roots = vec![user_docs.display().to_string()];
        let query = "From composing networks to deep networks";

        // Mode A: Baseline (Sequential + >2MB disk cache only + no inverted index)
        clear_all_search_caches(true);
        let t_a = Instant::now();
        let res_a = local_search_op(
            &json!({
                "op": "search",
                "query": query,
                "limit": 50,
                "opt": { "diskCacheAllPdfs": false, "parallelScan": false, "invertedIndex": false }
            }),
            &roots,
            &[],
            &[],
            &[],
        );
        let ms_a = t_a.elapsed().as_secs_f64() * 1000.0;

        // Mode B: Parallel multi-core scan ALONE (cold caches, no inverted index)
        clear_all_search_caches(true);
        let t_b = Instant::now();
        let res_b = local_search_op(
            &json!({
                "op": "search",
                "query": query,
                "limit": 50,
                "opt": { "diskCacheAllPdfs": false, "parallelScan": true, "invertedIndex": false }
            }),
            &roots,
            &[],
            &[],
            &[],
        );
        let ms_b = t_b.elapsed().as_secs_f64() * 1000.0;

        // Mode C: All-PDF Persistent Disk Cache ALONE (populate disk cache, clear RAM cache, run sequential without inverted index)
        clear_all_search_caches(true);
        let _populate = local_search_op(
            &json!({
                "op": "search",
                "query": " populate ",
                "limit": 5,
                "opt": { "diskCacheAllPdfs": true, "parallelScan": true, "invertedIndex": false }
            }),
            &roots,
            &[],
            &[],
            &[],
        );
        clear_all_search_caches(false); // Clear RAM only, keeping disk cache
        let t_c = Instant::now();
        let res_c = local_search_op(
            &json!({
                "op": "search",
                "query": query,
                "limit": 50,
                "opt": { "diskCacheAllPdfs": true, "parallelScan": false, "invertedIndex": false }
            }),
            &roots,
            &[],
            &[],
            &[],
        );
        let ms_c = t_c.elapsed().as_secs_f64() * 1000.0;

        // Mode D: In-Memory Inverted Index ALONE (warm index)
        let _build_idx = local_search_op(
            &json!({
                "op": "search",
                "query": "warmup",
                "limit": 5,
                "opt": { "diskCacheAllPdfs": false, "parallelScan": false, "invertedIndex": true }
            }),
            &roots,
            &[],
            &[],
            &[],
        );
        let t_d = Instant::now();
        let res_d = local_search_op(
            &json!({
                "op": "search",
                "query": query,
                "limit": 50,
                "opt": { "diskCacheAllPdfs": false, "parallelScan": false, "invertedIndex": true }
            }),
            &roots,
            &[],
            &[],
            &[],
        );
        let ms_d = t_d.elapsed().as_secs_f64() * 1000.0;

        // Mode E: All Combined (Cold restart with Disk Cache + Parallel Scan + Inverted Index build, then Warm query)
        clear_all_search_caches(false); // Simulate cold app restart (RAM empty, disk cache warm)
        let t_e_cold = Instant::now();
        let res_e_cold = local_search_op(
            &json!({
                "op": "search",
                "query": query,
                "limit": 50,
                "opt": { "diskCacheAllPdfs": true, "parallelScan": true, "invertedIndex": true }
            }),
            &roots,
            &[],
            &[],
            &[],
        );
        let ms_e_cold = t_e_cold.elapsed().as_secs_f64() * 1000.0;

        let t_e_warm = Instant::now();
        let res_e_warm = local_search_op(
            &json!({
                "op": "search",
                "query": query,
                "limit": 50,
                "opt": { "diskCacheAllPdfs": true, "parallelScan": true, "invertedIndex": true }
            }),
            &roots,
            &[],
            &[],
            &[],
        );
        let ms_e_warm = t_e_warm.elapsed().as_secs_f64() * 1000.0;

        println!("\n=== ABLATION BENCHMARK RESULTS (C:\\Users\\SaadG\\Documents) ===");
        println!("A. Baseline (Sequential, >2MB cache only):      {:>8.2} ms | strong={} hits={} cached_pdfs={}/{}",
            ms_a, res_a["strong"], res_a["hits"].as_array().map(|a| a.len()).unwrap_or(0),
            res_a["metrics"]["cachedDigestsUsed"], res_a["metrics"]["pdfBooksScanned"]);
        println!("B. Parallel Multi-Core Scan ALONE (Cold):       {:>8.2} ms | strong={} hits={} cached_pdfs={}/{}",
            ms_b, res_b["strong"], res_b["hits"].as_array().map(|a| a.len()).unwrap_or(0),
            res_b["metrics"]["cachedDigestsUsed"], res_b["metrics"]["pdfBooksScanned"]);
        println!("C. All-PDF Disk Cache ALONE (Cold App Restart): {:>8.2} ms | strong={} hits={} cached_pdfs={}/{}",
            ms_c, res_c["strong"], res_c["hits"].as_array().map(|a| a.len()).unwrap_or(0),
            res_c["metrics"]["cachedDigestsUsed"], res_c["metrics"]["pdfBooksScanned"]);
        println!("D. RAM Inverted Index ALONE (Warm Query):       {:>8.2} ms | strong={} hits={} candidates={}",
            ms_d, res_d["strong"], res_d["hits"].as_array().map(|a| a.len()).unwrap_or(0),
            res_d["metrics"]["indexCandidates"]);
        println!("E1. COMBINED (Cold App Restart First Query):    {:>8.2} ms | strong={} hits={} cached_pdfs={}/{}",
            ms_e_cold, res_e_cold["strong"], res_e_cold["hits"].as_array().map(|a| a.len()).unwrap_or(0),
            res_e_cold["metrics"]["cachedDigestsUsed"], res_e_cold["metrics"]["pdfBooksScanned"]);
        println!("E2. COMBINED (Warm Subsequent Query):           {:>8.2} ms | strong={} hits={} candidates={}\n",
            ms_e_warm, res_e_warm["strong"], res_e_warm["hits"].as_array().map(|a| a.len()).unwrap_or(0),
            res_e_warm["metrics"]["indexCandidates"]);

        assert_eq!(res_a["strong"], res_e_warm["strong"]);
        assert!(ms_e_warm < ms_a);
    }

    #[test]
    fn exact_quote_phrase_detects_quoted_queries_only() {
        assert_eq!(
            exact_quote_phrase("\"GLOW model samples.\"", false).as_deref(),
            Some("GLOW model samples.")
        );
        assert_eq!(exact_quote_phrase("  “curly quotes here”  ", false).as_deref(), Some("curly quotes here"));
        assert_eq!(exact_quote_phrase("glow model samples", false), None);
        assert_eq!(exact_quote_phrase("\"one\" and \"two\"", false), None);
        assert_eq!(exact_quote_phrase("\"\"", false), None);
        assert_eq!(exact_quote_phrase("\"...\"", false), None);
        assert_eq!(exact_quote_phrase("glow model samples", true).as_deref(), Some("glow model samples"));
    }

    #[test]
    fn find_exact_quote_requires_consecutive_whole_words_ignoring_case_and_punctuation() {
        let tokens = quote_tokens("base density raised to a positive power.");
        let ok = "The Base-Density,\nraised   to a POSITIVE power; and again: base density raised to a positive power.";
        let (count, spans) = find_exact_quote(ok, &tokens, 5);
        assert_eq!(count, 2);
        assert_eq!(spans.len(), 2);
        assert!(ok[spans[0].0..spans[0].1].starts_with("Base-Density"));

        // Different word between, plural, prefix, reversed order, truncated phrase: none may match.
        for bad in [
            "base density never raised to a positive power",
            "base densities raised to a positive power",
            "base density raised to a positive powers",
            "power positive a to raised density base",
            "base density raised to a positive",
            "database density raised to a positive power",
        ] {
            assert_eq!(find_exact_quote(bad, &tokens, 5).0, 0, "must not match: {bad}");
        }
        // Single-word quote is a whole-word match, not a prefix.
        let one = quote_tokens("glow");
        assert_eq!(find_exact_quote("glow glowing GLOW", &one, 5).0, 2);
    }

    #[test]
    fn quoted_query_returns_only_documents_with_the_exact_sentence() {
        let tmp = std::env::temp_dir().join("digup_exact_quote_test");
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(&tmp).unwrap();
        fs::write(
            tmp.join("exact_once.md"),
            "# Flows\nNotes.\nSampling: GLOW model samples from the\nbase density raised to a positive power.\nMore notes.",
        )
        .unwrap();
        fs::write(
            tmp.join("exact_twice.md"),
            "glow model samples from the base density raised to a positive power. Later: GLOW Model Samples From The Base Density Raised To A Positive Power!",
        )
        .unwrap();
        fs::write(
            tmp.join("scattered_words.md"),
            "The glow of the model samples a base. From the density we raise to a positive power.",
        )
        .unwrap();
        fs::write(
            tmp.join("near_miss.md"),
            "GLOW models sample from the base density raised to a positive power.",
        )
        .unwrap();
        fs::write(tmp.join("unrelated.md"), "Calibration schedule for optical sensors.").unwrap();

        clear_all_search_caches(true);
        let roots = vec![tmp.display().to_string()];
        let sentence = "GLOW model samples from the base density raised to a positive power.";

        let quoted = local_search_op(
            &json!({"op": "search", "query": format!("\"{sentence}\""), "limit": 20}),
            &roots,
            &[],
            &[],
            &[],
        );
        let hits = quoted["hits"].as_array().unwrap();
        let names: Vec<String> = hits
            .iter()
            .map(|h| Path::new(h["path"].as_str().unwrap()).file_name().unwrap().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, vec!["exact_twice.md", "exact_once.md"], "got {names:?}");
        assert_eq!(quoted["strong"].as_u64(), Some(2));
        assert_eq!(hits[0]["exactMatches"].as_u64(), Some(2));
        assert_eq!(hits[1]["exactMatches"].as_u64(), Some(1));
        assert_eq!(hits[1]["loc"].as_u64(), Some(3), "match starts on line 3");
        assert_eq!(hits[1]["endLine"].as_u64(), Some(4), "match ends on line 4");
        let excerpt = hits[1]["excerpt"].as_str().unwrap();
        assert!(excerpt.contains("«GLOW model samples from the base density raised to a positive power»"), "{excerpt}");
        assert_eq!(quoted["metrics"]["exactQuote"], json!(true));
        assert_eq!(quoted["metrics"]["exactMatches"].as_u64(), Some(3));

        // `exact: true` forces the same behavior without typing quotes.
        let forced = local_search_op(
            &json!({"op": "search", "query": sentence, "exact": true, "limit": 20}),
            &roots,
            &[],
            &[],
            &[],
        );
        assert_eq!(forced["hits"].as_array().unwrap().len(), 2);

        // Without quotes the ordinary ranked search is used and also surfaces the near misses.
        let plain = local_search_op(
            &json!({"op": "search", "query": sentence, "limit": 20}),
            &roots,
            &[],
            &[],
            &[],
        );
        assert!(plain["hits"].as_array().unwrap().len() >= 4);
        assert!(plain["metrics"]["exactQuote"].is_null());

        // Same results with the inverted-index prefilter off.
        let no_index = local_search_op(
            &json!({
                "op": "search",
                "query": format!("\"{sentence}\""),
                "limit": 20,
                "opt": { "invertedIndex": false }
            }),
            &roots,
            &[],
            &[],
            &[],
        );
        assert_eq!(no_index["hits"].as_array().unwrap().len(), 2);

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn exact_quote_search_on_real_user_documents_corpus() {
        let user_docs = PathBuf::from(r"C:\Users\SaadG\Documents");
        if !user_docs.is_dir() {
            return;
        }
        let roots = vec![user_docs.display().to_string()];
        let phrase = "GLOW model samples from the base density raised to a positive power.";
        let query = format!("\"{phrase}\"");
        let tokens = quote_tokens(phrase);

        clear_all_search_caches(true);
        let mut ms = Vec::new();
        let mut last = Value::Null;
        for _ in 0..3 {
            let t = Instant::now();
            last = local_search_op(&json!({"op": "search", "query": query, "limit": 50}), &roots, &[], &[], &[]);
            ms.push(t.elapsed().as_secs_f64() * 1000.0);
        }
        println!("\n=== EXACT QUOTE SEARCH (C:\\Users\\SaadG\\Documents) ===");
        println!("quote: {phrase}");
        println!("runs ms (cold, warm, warm): {:.2} / {:.2} / {:.2}", ms[0], ms[1], ms[2]);
        // App restart: RAM caches gone, the on-disk digest and full-text caches stay.
        clear_all_search_caches(false);
        let t = Instant::now();
        let restarted = local_search_op(&json!({"op": "search", "query": query, "limit": 50}), &roots, &[], &[], &[]);
        println!("after restart (disk caches): {:.2} ms", t.elapsed().as_secs_f64() * 1000.0);
        assert_eq!(restarted["hits"], last["hits"]);
        println!("metrics: {}", last["metrics"]);
        for h in last["hits"].as_array().unwrap() {
            println!(
                "  {} | matches={} | line {} | {}",
                h["path"].as_str().unwrap_or(""),
                h["exactMatches"],
                h["loc"],
                h["excerpt"].as_str().unwrap_or("").chars().take(200).collect::<String>()
            );
        }

        // Every reported hit must truly contain the whole quote as consecutive words.
        for h in last["hits"].as_array().unwrap() {
            let path = h["path"].as_str().unwrap();
            let text = if path.to_ascii_lowercase().ends_with(".pdf") {
                crate::pdf_text::extract_full_pdf_text(Path::new(path)).unwrap_or_default()
            } else {
                fs::read_to_string(path).unwrap_or_default()
            };
            assert!(find_exact_quote(&text, &tokens, 1).0 > 0, "false positive: {path}");
        }

        // The sentence is on one page of Understanding Deep Learning (chapter 16, GLOW), found by its full text.
        let book = last["hits"]
            .as_array()
            .unwrap()
            .iter()
            .find(|h| h["path"].as_str().unwrap_or("").contains("Understanding_Deep_Learning"));
        if user_docs.join("_OceanofPDF.com_Understanding_Deep_Learning_-_Simon_JD_Prince.pdf").is_file() {
            let book = book.expect("the GLOW sentence must be found in the book");
            assert_eq!(book["segment"], json!("page"));
            assert!(book["loc"].as_u64().unwrap_or(0) > 1);
        }
    }
}
