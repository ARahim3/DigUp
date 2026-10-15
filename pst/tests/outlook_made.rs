//! Reads tests/data/outlook_made.pst, a PST that classic Outlook 16.0 created (30 synthetic mails in three folders, 5
//! attachments, plain and HTML bodies), and checks it against what Outlook itself listed (outlook_made.expected.tsv).

use std::{collections::BTreeMap, path::PathBuf, process::Command};

use serde_json::Value;

fn data(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/data").join(name)
}

fn run(args: &[&str]) -> (Option<i32>, Vec<Value>) {
    let output = Command::new(env!("CARGO_BIN_EXE_digup-pst")).args(args).output().expect("run digup-pst");
    let lines = String::from_utf8(output.stdout)
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str(l).expect("one JSON value per line"))
        .collect();
    (output.status.code(), lines)
}

fn mails(lines: &[Value]) -> BTreeMap<String, Value> {
    lines
        .iter()
        .filter(|l| l["type"] == "mail")
        .map(|l| (l["entry_id"].as_str().unwrap().to_string(), l.clone()))
        .collect()
}

fn pst() -> String {
    data("outlook_made.pst").to_string_lossy().to_string()
}

#[test]
fn list_matches_outlook() {
    let (code, lines) = run(&["list", &pst()]);
    assert_eq!(code, Some(0));
    let mails = mails(&lines);
    let expected: Vec<Vec<String>> = std::fs::read_to_string(data("outlook_made.expected.tsv"))
        .unwrap()
        .lines()
        .filter(|l| !l.starts_with('#'))
        .map(|l| l.split('\t').map(String::from).collect())
        .collect();
    assert_eq!(expected.len(), 30);
    assert_eq!(mails.len(), 30);
    for row in &expected {
        let mail = mails.get(&row[0]).unwrap_or_else(|| panic!("missing {}", row[0]));
        assert_eq!(mail["subject"], row[1].as_str());
        assert_eq!(mail["folder"], row[2].as_str());
        assert!(mail.get("body").is_none());
        assert!(mail["node"].as_u64().is_some());
    }
    let summary = lines.last().unwrap();
    assert_eq!(summary["type"], "summary");
    assert_eq!(summary["mails"], 30);
    assert_eq!(summary["errors"], 0);
}

#[test]
fn read_gives_plain_text_bodies_and_attachments() {
    let (_, listed) = run(&["list", &pst()]);
    let nodes: BTreeMap<String, u64> = listed
        .iter()
        .filter(|l| l["type"] == "mail")
        .map(|l| (l["subject"].as_str().unwrap().to_string(), l["node"].as_u64().unwrap()))
        .collect();
    let dir = std::env::temp_dir().join(format!("digup-pst-test-{}", std::process::id()));
    let (seven, twelve) = (nodes["PST test 07"].to_string(), nodes["PST test 12"].to_string());
    let (code, lines) = run(&["read", &pst(), &seven, &twelve, "--attachments", dir.to_str().unwrap()]);
    assert_eq!(code, Some(0));
    let read: Vec<&Value> = lines.iter().filter(|l| l["type"] == "mail").collect();
    assert_eq!(read.len(), 2);
    assert_eq!(read[0]["subject"], "PST test 07");   // in the order asked
    assert_eq!(read[1]["subject"], "PST test 12");
    for mail in &read {
        // Outlook stored every body as HTML, even the ones written as plain text.
        assert_eq!(mail["body_kind"], "html");
        let body = mail["body"].as_str().unwrap();
        assert!(body.contains("reference DEV-2024-00"), "{body}");
        assert!(!body.contains('<'), "{body}");
    }
    let attachment = &read[0]["attachments"][0];   // mails 0, 7, 14, 21 and 28 have one
    assert_eq!(attachment["name"], "piece_jointe.txt");
    let saved = std::fs::read_to_string(attachment["path"].as_str().unwrap()).unwrap();
    assert_eq!(saved, "Contenu de la piece jointe de test.");
    assert!(read[1]["attachments"].as_array().unwrap().is_empty());
    std::fs::remove_dir_all(dir).ok();
}

#[test]
fn read_reports_nodes_that_are_not_mails() {
    let (code, lines) = run(&["read", &pst(), "99"]);
    assert_eq!(code, Some(0));
    assert_eq!(lines.iter().filter(|l| l["type"] == "error" && l["node"] == 99).count(), 1);
    assert_eq!(lines.last().unwrap()["mails"], 0);
}

#[test]
fn missing_file_and_bad_arguments_fail_cleanly() {
    assert_eq!(run(&["list", &data("absent.pst").to_string_lossy()]).0, Some(1));
    assert_eq!(run(&["read", &pst(), "seven"]).0, Some(1));
    assert_eq!(run(&["frobnicate", &pst()]).0, Some(1));
}

#[cfg(not(windows))]
#[test]
fn opening_needs_windows() {
    assert_eq!(run(&["open", &pst(), "2097412"]).0, Some(4));
}
