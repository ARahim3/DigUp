// Local JSONL Fine-Tuning Dataset Logger & Secret Scrubber for DigUp + SLM.
// Generates standard ChatML SFT (`sft_train.jsonl`) and DPO (`dpo_train.jsonl`) files from user chat interactions,
// enabling local domain adaptation while stripping sensitive keys/tokens before persistence.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::fs::{self, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub const SFT_FILE: &str = "sft_train.jsonl";
pub const DPO_FILE: &str = "dpo_train.jsonl";
pub const SYSTEM_PROMPT: &str = "You are DigUp Local AI, a private assistant grounded in the user's local files, code, and system architecture.";

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SftRecordInput {
    pub question: String,
    pub context: Option<String>,
    pub answer: String,
    pub edited_answer: Option<String>,
    pub citations: Vec<Value>,
    pub cag_slot: Option<String>,
    pub include_context_in_prompt: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct DatasetStats {
    pub sft_count: usize,
    pub dpo_count: usize,
    pub sft_bytes: u64,
    pub dpo_bytes: u64,
    pub dataset_dir: String,
}

/// Deterministic secret & credential scrubber so API keys, private keys, or passwords in local files
/// never leak into `.jsonl` fine-tuning datasets.
pub fn scrub_secrets(input: &str) -> String {
    let mut out = input.to_string();

    // 1. Redact PEM private key blocks
    while let Some(start) = out.find("-----BEGIN ") {
        if let Some(priv_pos) = out[start..].find("PRIVATE KEY-----") {
            let header_end = start + priv_pos + "PRIVATE KEY-----".len();
            if let Some(end_marker) = out[header_end..].find("-----END ") {
                if let Some(footer_close) = out[header_end + end_marker..].find("-----") {
                    let full_end = header_end + end_marker + footer_close + 5;
                    let after_end = out[full_end..]
                        .find("-----")
                        .map(|idx| full_end + idx + 5)
                        .unwrap_or(full_end);
                    out.replace_range(start..after_end.min(out.len()), "[REDACTED_PRIVATE_KEY]");
                    continue;
                }
            }
        }
        break;
    }

    // 2. Token-level scrubbing for common prefixes (sk-, ghp_, gho_, github_pat_, AKIA, AIza, xoxb-)
    //    and key=value assignments (password=, api_key=, secret=, token=).
    let prefixes = [
        "sk-",
        "ghp_",
        "gho_",
        "github_pat_",
        "AKIA",
        "AIza",
        "xoxb-",
        "xoxp-",
    ];
    let sensitive_keys = [
        "password=",
        "passwd=",
        "api_key=",
        "apikey=",
        "secret=",
        "access_token=",
        "auth_token=",
    ];

    let mut scrubbed_lines = Vec::new();
    for line in out.lines() {
        let mut words: Vec<String> = Vec::new();
        let mut redact_next = false;
        for token in line.split_whitespace() {
            if redact_next {
                words.push("[REDACTED_TOKEN]".to_string());
                redact_next = false;
                continue;
            }
            if token.eq_ignore_ascii_case("Bearer") {
                words.push(token.to_string());
                redact_next = true;
                continue;
            }
            let clean = token.trim_matches(|c: char| c == '"' || c == '\'' || c == ',' || c == ';');
            let lower = clean.to_ascii_lowercase();

            if prefixes
                .iter()
                .any(|p| clean.starts_with(p) && clean.len() >= p.len() + 8)
            {
                words.push("[REDACTED_SECRET]".to_string());
            } else if let Some(key) = sensitive_keys.iter().find(|k| lower.starts_with(*k)) {
                let key_part = &clean[..key.len()];
                words.push(format!("{key_part}[REDACTED]"));
            } else {
                words.push(token.to_string());
            }
        }
        if line.is_empty() {
            scrubbed_lines.push(String::new());
        } else {
            scrubbed_lines.push(words.join(" "));
        }
    }

    scrubbed_lines.join("\n")
}

pub fn dataset_dir(base_dir: &Path) -> PathBuf {
    base_dir.join("datasets")
}

fn unix_timestamp() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Logs an interaction into `sft_train.jsonl` (ChatML `messages` format) and, if the user edited/corrected
/// the model's answer, also logs a preference pair into `dpo_train.jsonl`.
pub fn log_interaction(base_dir: &Path, input: &SftRecordInput) -> Result<DatasetStats, String> {
    let dir = dataset_dir(base_dir);
    fs::create_dir_all(&dir).map_err(|e| format!("can't create dataset folder: {e}"))?;

    let clean_q = scrub_secrets(input.question.trim());
    if clean_q.is_empty() {
        return Err("question cannot be empty".into());
    }
    let clean_ctx = input
        .context
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(scrub_secrets);

    let chosen_raw = input
        .edited_answer
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| input.answer.trim());
    let clean_chosen = scrub_secrets(chosen_raw);
    if clean_chosen.is_empty() {
        return Err("answer cannot be empty".into());
    }

    let user_content = match (&clean_ctx, input.include_context_in_prompt) {
        (Some(ctx), true) => format!("Retrieved Local Context:\n{ctx}\n\nQuestion:\n{clean_q}"),
        _ => clean_q.clone(),
    };

    let system_prompt = SYSTEM_PROMPT;
    let ts = unix_timestamp();

    let sft_entry = json!({
        "messages": [
            { "role": "system", "content": system_prompt },
            { "role": "user", "content": user_content },
            { "role": "assistant", "content": clean_chosen }
        ],
        "metadata": {
            "timestamp": ts,
            "cag_slot": input.cag_slot,
            "citations": input.citations,
            "user_edited": input.edited_answer.is_some()
        }
    });

    append_jsonl_line(&dir.join(SFT_FILE), &sft_entry)?;

    // If the user corrected the model's original response, also emit a DPO preference training example.
    if let Some(edited) = input
        .edited_answer
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        let orig = input.answer.trim();
        if !orig.is_empty() && edited != orig {
            let clean_rejected = scrub_secrets(orig);
            let dpo_entry = json!({
                "prompt": [
                    { "role": "system", "content": system_prompt },
                    { "role": "user", "content": user_content }
                ],
                "chosen": [
                    { "role": "assistant", "content": clean_chosen }
                ],
                "rejected": [
                    { "role": "assistant", "content": clean_rejected }
                ],
                "metadata": {
                    "timestamp": ts,
                    "cag_slot": input.cag_slot
                }
            });
            append_jsonl_line(&dir.join(DPO_FILE), &dpo_entry)?;
        }
    }

    stats(base_dir)
}

fn append_jsonl_line(file_path: &Path, value: &Value) -> Result<(), String> {
    let mut line =
        serde_json::to_string(value).map_err(|e| format!("JSON serialization failed: {e}"))?;
    line.push('\n');
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(file_path)
        .map_err(|e| format!("can't open {}: {e}", file_path.display()))?;
    file.write_all(line.as_bytes())
        .map_err(|e| format!("can't write to {}: {e}", file_path.display()))
}

pub fn stats(base_dir: &Path) -> Result<DatasetStats, String> {
    let dir = dataset_dir(base_dir);
    let sft_path = dir.join(SFT_FILE);
    let dpo_path = dir.join(DPO_FILE);
    let count_lines = |p: &Path| -> usize {
        let Ok(file) = fs::File::open(p) else {
            return 0;
        };
        BufReader::new(file)
            .lines()
            .filter_map(Result::ok)
            .filter(|l| !l.trim().is_empty())
            .count()
    };
    let file_size = |p: &Path| -> u64 { fs::metadata(p).map(|m| m.len()).unwrap_or(0) };

    Ok(DatasetStats {
        sft_count: count_lines(&sft_path),
        dpo_count: count_lines(&dpo_path),
        sft_bytes: file_size(&sft_path),
        dpo_bytes: file_size(&dpo_path),
        dataset_dir: dir.display().to_string(),
    })
}

pub fn recent_entries(base_dir: &Path, limit: usize) -> Vec<Value> {
    let sft_path = dataset_dir(base_dir).join(SFT_FILE);
    let Ok(file) = fs::File::open(sft_path) else {
        return Vec::new();
    };
    let all: Vec<Value> = BufReader::new(file)
        .lines()
        .filter_map(Result::ok)
        .filter_map(|line| serde_json::from_str::<Value>(&line).ok())
        .collect();
    all.into_iter().rev().take(limit).collect()
}

pub fn export_dataset(base_dir: &Path, destination: &Path, dpo: bool) -> Result<String, String> {
    let src = dataset_dir(base_dir).join(if dpo { DPO_FILE } else { SFT_FILE });
    if !src.is_file() {
        return Err("no dataset entries recorded yet".into());
    }
    if let Some(parent) = destination.parent() {
        let _ = fs::create_dir_all(parent);
    }
    fs::copy(&src, destination).map_err(|e| format!("failed to export JSONL: {e}"))?;
    Ok(destination.display().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;

    #[test]
    fn scrubs_api_keys_bearer_tokens_and_pem_blocks() {
        let raw = "Connect with Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9 and key sk-1234567890abcdef1234 or password=mySuperSecret123\n-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA...\n-----END RSA PRIVATE KEY-----";
        let scrubbed = scrub_secrets(raw);
        assert!(!scrubbed.contains("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"));
        assert!(!scrubbed.contains("sk-1234567890abcdef1234"));
        assert!(!scrubbed.contains("mySuperSecret123"));
        assert!(!scrubbed.contains("MIIEowIBAAKCAQEA"));
        assert!(scrubbed.contains("[REDACTED_TOKEN]"));
        assert!(scrubbed.contains("[REDACTED_SECRET]"));
        assert!(scrubbed.contains("password=[REDACTED]"));
        assert!(scrubbed.contains("[REDACTED_PRIVATE_KEY]"));
    }

    #[test]
    fn logs_sft_and_dpo_jsonl_entries() {
        let tmp = env::temp_dir().join(format!("digup_jsonl_test_{}", unix_timestamp()));
        let _ = fs::remove_dir_all(&tmp);

        let input = SftRecordInput {
            question: "Which Redis port does billing-service use?".into(),
            context: Some(
                "billing-service/config/settings.yaml: redis_port: 6379, api_key=secret999".into(),
            ),
            answer: "It connects on port 6380.".into(),
            edited_answer: Some(
                "billing-service connects to Redis on port 6379 (see settings.yaml).".into(),
            ),
            citations: vec![json!({"path": "billing-service/config/settings.yaml", "loc": 1})],
            cag_slot: Some("billing-core".into()),
            include_context_in_prompt: true,
        };

        let st = log_interaction(&tmp, &input).expect("log_interaction should succeed");
        assert_eq!(st.sft_count, 1);
        assert_eq!(st.dpo_count, 1);
        assert!(st.sft_bytes > 50);
        assert!(st.dpo_bytes > 50);

        let recent = recent_entries(&tmp, 5);
        assert_eq!(recent.len(), 1);
        let messages = recent[0]["messages"].as_array().unwrap();
        assert_eq!(messages.len(), 3);
        assert!(messages[1]["content"]
            .as_str()
            .unwrap()
            .contains("api_key=[REDACTED]"));
        assert!(messages[2]["content"]
            .as_str()
            .unwrap()
            .contains("port 6379"));

        let _ = fs::remove_dir_all(&tmp);
    }
}
