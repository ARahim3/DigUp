// Native Rust GraphRAG Entity Extractor, CAG (Cache-Augmented Generation) Slot Manager,
// and Local SLM Orchestrator for the 8-Core / 12GB RAM Desktop Architecture.
//
// Works in tandem with `digup search-service` and `digup chat-service` (or a local llama.cpp / Ollama /
// GGUF endpoint), ensuring 100% offline privacy, automatic background indexer yielding during SLM inference,
// and instant CAG prefix-cache reuse.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

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
                combined.push_str(&format!("### Pinned Binary/Media File: {}\n", path_str));
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

/// Checks if `term` appears in `haystack_lower` as a whole word (treating `_`, `-`, `.`, `/`, and `\` as word
/// separators, or prefix of a plural/past-tense word for terms >= 4 chars), preventing short acronyms like `tops`
/// from false-matching inside `stops` while matching `simon_jd_prince-understanding_deep_learning.pdf`.
fn matches_term_in_text(haystack_lower: &str, term: &str) -> bool {
    if term.is_empty() {
        return false;
    }
    let bytes = haystack_lower.as_bytes();
    let t_len = term.len();
    let mut start = 0usize;
    while let Some(rel) = haystack_lower[start..].find(term) {
        let idx = start + rel;
        let end = idx + t_len;
        let left_ok = idx == 0 || !bytes[idx - 1].is_ascii_alphanumeric();
        let right_ok = end >= bytes.len() || {
            let b = bytes[end];
            !b.is_ascii_alphanumeric() || (t_len >= 4 && (b == b's' || b == b'd'))
        };
        if left_ok && right_ok {
            return true;
        }
        start = idx + 1;
        if start >= bytes.len() {
            break;
        }
    }
    false
}

/// Splits a Markdown or text document into logical sections (by `#`, `##`, `###` headings, or ~25-line blocks)
/// so multi-part questions can retrieve the exact sections (`## Authorization levels`, `### Incident response`, etc.)
/// rather than only the first 6 lines of the file.
#[derive(Clone, Debug)]
struct DocSection {
    heading: String,
    start_line: usize,
    end_line: usize,
    text: String,
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
                sections.push(DocSection {
                    heading: current_heading.clone(),
                    start_line,
                    end_line: line_num - 1,
                    text,
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
            sections.push(DocSection {
                heading: current_heading,
                start_line,
                end_line: lines.len(),
                text,
            });
        }
    }
    sections
}

/// Wraps whole-word occurrences of `terms` in `text` with `«...»` markers (which `window.js` renders as `<mark>`).
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
            let end = pos + term.len();
            let left_ok = pos == 0 || !bytes[pos - 1].is_ascii_alphanumeric();
            if left_ok && result.is_char_boundary(pos) && result.is_char_boundary(end) {
                let matched = &result[pos..end];
                result = format!("{}«{}»{}", &result[..pos], matched, &result[end..]);
                break;
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
            let content = fs::read_to_string(path).unwrap_or_default();
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
            let query = request["query"]
                .as_str()
                .or_else(|| request["q"].as_str())
                .unwrap_or("")
                .trim();
            let filter_kind = request["kind"].as_str();
            let limit = request["limit"].as_u64().unwrap_or(50) as usize;

            let mut all_roots: Vec<String> = folders.to_vec();
            for cf in code_folders {
                if !all_roots.iter().any(|r| r.eq_ignore_ascii_case(cf)) {
                    all_roots.push(cf.clone());
                }
            }
            let files = walk_local_folders(&all_roots, skipped, skip_types);
            let terms = query_terms(query);

            // Compute document frequency (DF) per term across the local corpus so rare, specific terms
            // (`authorization`, `nanopowders`, `hydrofluoric`, `analog-ai`, `tops`) outweigh generic terms (`micro`, `lab`).
            let mut doc_contents: Vec<(LocalFileEntry, Option<String>, String)> = Vec::with_capacity(files.len());
            let mut df: HashMap<String, usize> = HashMap::new();
            for file in files {
                if is_code_req && file.kind != "code" && file.kind != "doc" {
                    continue;
                }
                if let Some(k) = filter_kind {
                    if file.kind != k {
                        continue;
                    }
                }
                let text_opt = if matches!(file.kind, "doc" | "code") && file.size <= 2_000_000 {
                    fs::read_to_string(&file.path).ok()
                } else {
                    None
                };
                // Normalize relative path from root + split CamelCase segments so parent directory themes
                // (`Machine_Learning_Robotics/Simon_JD_Prince/understanding_deep_learning.pdf` or `SimonJDPrince`) match cleanly.
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

                let combined_lower = format!(
                    "{} {}",
                    path_search_text,
                    text_opt.as_deref().unwrap_or("").to_ascii_lowercase()
                );
                for term in &terms {
                    if matches_term_in_text(&combined_lower, term) {
                        *df.entry(term.clone()).or_insert(0) += 1;
                    }
                }
                doc_contents.push((file, text_opt, path_search_text));
            }

            let total_docs = doc_contents.len().max(1) as f64;
            let term_weight = |term: &str| -> f64 {
                let doc_freq = (*df.get(term).unwrap_or(&1)).max(1) as f64;
                let idf = ((total_docs + 1.0) / (doc_freq + 0.5)).ln() + 1.0;
                // Specific longer words or numbers get extra specificity boost
                let len_boost = if term.len() >= 7 { 1.35 } else { 1.0 };
                idf * len_boost
            };

            let max_possible_weight: f64 = terms.iter().map(|t| term_weight(t)).sum::<f64>().max(1.0);
            let mut hits = Vec::new();

            for (file, text_opt, path_search_text) in doc_contents {
                let file_name = Path::new(&file.path)
                    .file_name()
                    .and_then(|s| s.to_str())
                    .unwrap_or("")
                    .to_ascii_lowercase();

                let mut matched_weight = 0.0f64;
                let mut matched_words = 0usize;

                let Some(content) = text_opt else {
                    for term in &terms {
                        let w = term_weight(term);
                        if matches_term_in_text(&file_name, term) {
                            matched_weight += w;
                            matched_words += 1;
                        } else if matches_term_in_text(&path_search_text, term) {
                            matched_weight += w * 0.85;
                            matched_words += 1;
                        }
                    }
                    if matched_words > 0 {
                        let score = (matched_weight / max_possible_weight).clamp(0.25, 0.99);
                        hits.push(json!({
                            "path": file.path,
                            "kind": if is_code_req { "code" } else { file.kind },
                            "score": score,
                            "words": true,
                            "meaning": true,
                            "excerpt": "",
                            "loc": Value::Null,
                            "endLine": Value::Null,
                            "size": file.size,
                            "modified": file.modified,
                        }));
                    }
                    continue;
                };

                let content_lower = content.to_ascii_lowercase();
                for term in &terms {
                    let w = term_weight(term);
                    if matches_term_in_text(&content_lower, term) {
                        matched_weight += w;
                        matched_words += 1;
                    } else if matches_term_in_text(&file_name, term) {
                        // Filename-only match gets a solid weight if the term doesn't appear in body
                        matched_weight += w * 0.65;
                        matched_words += 1;
                    } else if matches_term_in_text(&path_search_text, term) {
                        matched_weight += w * 0.45;
                        matched_words += 1;
                    }
                }

                if matched_words == 0 {
                    continue;
                }

                let lines: Vec<&str> = content.lines().collect();
                let excerpt: String;
                let mut loc_val = Value::Null;
                let mut end_line_val = Value::Null;
                let mut top_sections_json = Vec::new();

                if file.kind == "code" {
                    let mut best_line_idx = 0usize;
                    let mut best_line_w = 0.0f64;
                    for (idx, line) in lines.iter().enumerate() {
                        let l_lower = line.to_ascii_lowercase();
                        let mut lw = 0.0f64;
                        for term in &terms {
                            if matches_term_in_text(&l_lower, term) {
                                lw += term_weight(term);
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
                    // Section-aware scoring for Markdown & text documents
                    let sections = split_into_sections(&content);
                    let mut scored_sections: Vec<(f64, &DocSection)> = Vec::new();
                    for sec in &sections {
                        let sec_lower = sec.text.to_ascii_lowercase();
                        let head_lower = sec.heading.to_ascii_lowercase();
                        let mut sec_w = 0.0f64;
                        for term in &terms {
                            let w = term_weight(term);
                            if matches_term_in_text(&head_lower, term) {
                                sec_w += w * 2.2; // Heading match is a strong signal
                            } else if matches_term_in_text(&sec_lower, term) {
                                sec_w += w;
                            }
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
                        let sec_lower = sec.text.to_ascii_lowercase();
                        let adds_new_term = terms.iter().any(|t| {
                            !covered_terms.contains(t) && matches_term_in_text(&sec_lower, t)
                        });
                        if chosen.is_empty() || adds_new_term {
                            for t in &terms {
                                if matches_term_in_text(&sec_lower, t) {
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
                            // Keep heading + lines that match query terms (plus neighbors)
                            let mut keep = Vec::new();
                            for (i, &l) in sec_lines.iter().enumerate() {
                                let ll = l.to_ascii_lowercase();
                                if i == 0 || terms.iter().any(|t| matches_term_in_text(&ll, t)) {
                                    keep.push(l);
                                }
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

                let normalized_score = (matched_weight / max_possible_weight).clamp(0.15, 0.99);
                hits.push(json!({
                    "path": file.path,
                    "kind": if is_code_req { "code" } else { file.kind },
                    "score": normalized_score,
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

            hits.sort_by(|a, b| {
                let sa = a["score"].as_f64().unwrap_or(0.0);
                let sb = b["score"].as_f64().unwrap_or(0.0);
                sb.partial_cmp(&sa).unwrap_or(std::cmp::Ordering::Equal)
            });

            // Filter out noisy low-overlap hits when a strong match exists (e.g. don't return release-notes.md
            // just because it matched 1 generic word when MICRO Lab matched 6 specific words).
            let best_score = hits.first().and_then(|h| h["score"].as_f64()).unwrap_or(0.0);
            if best_score >= 0.45 && terms.len() >= 3 {
                hits.retain(|h| h["score"].as_f64().unwrap_or(0.0) >= best_score * 0.35);
            }
            hits.truncate(limit);

            json!({
                "hits": hits,
                "meaning": true,
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
}
