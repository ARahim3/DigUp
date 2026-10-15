//! digup-pst: Outlook mail stored in .pst files, for DigUp's helper. It reads PSTs without Outlook, MAPI or COM, with
//! microsoft/outlook-pst-rs (MIT), and on Windows opens a mail in classic Outlook through its COM automation.
//!
//! Usage:
//!   digup-pst list FILE.pst                     one JSON line per mail (no body), then a summary line
//!   digup-pst read FILE.pst NODE... [--attachments DIR]
//!                                               those mails with their body as plain text, and with --attachments
//!                                               their attachments written into DIR
//!   digup-pst open FILE.pst NODE                shows the mail in Outlook (Windows)
//!
//! A mail is known by its node id in the PST (NODE, as `list` gives it); its Outlook EntryID is built from it and the
//! PST's record key when it's opened, since Outlook can give a PST a new record key (a copy attached beside the original).
//!
//! Lines: {"type":"store"...}, then {"type":"mail"...} or {"type":"error"...}, then {"type":"summary"...}. Error lines
//! carry the library's error kind and a node id, never mail content.
//! Exit codes: 0 ok, 1 error, 3 the PST is locked (Outlook has it open: try again later), 4 classic Outlook isn't
//! there, 5 the PST isn't open in Outlook, 6 Outlook can't find the mail.

mod open;
mod reader;
mod text;

use std::{
    io::{BufWriter, Write},
    path::{Path, PathBuf},
    process::ExitCode,
    time::Instant,
};

use anyhow::{anyhow, Context, Result};
use reader::{is_locked, open, Backend, Opened, Options, Walker};
use serde_json::{json, Value};

enum Command {
    List,
    Read { nodes: Vec<u32>, attachments: Option<PathBuf> },
    Open { node: u32 },
}

const USAGE: &str = "usage: digup-pst list FILE.pst | read FILE.pst NODE... [--attachments DIR] | open FILE.pst NODE";

fn parse_args() -> Result<(Command, PathBuf)> {
    let mut args = std::env::args().skip(1);
    let command = args.next().context(USAGE)?;
    let file: PathBuf = args.next().context(USAGE)?.into();
    let rest: Vec<String> = args.collect();
    let node = |s: &str| s.parse::<u32>().with_context(|| format!("not a node id: {s}"));
    let command = match command.as_str() {
        "list" if rest.is_empty() => Command::List,
        "read" => {
            let (mut nodes, mut attachments) = (Vec::new(), None);
            let mut rest = rest.iter();
            while let Some(arg) = rest.next() {
                if arg == "--attachments" {
                    attachments = Some(rest.next().context("--attachments needs a folder")?.into());
                } else {
                    nodes.push(node(arg)?);
                }
            }
            Command::Read { nodes, attachments }
        }
        "open" if rest.len() == 1 => Command::Open { node: node(&rest[0])? },
        _ => return Err(anyhow!(USAGE)),
    };
    Ok((command, file))
}

fn list<B: Backend>(backend: B) -> Result<()> {
    let started = Instant::now();
    let mut walker = Walker::new(backend, Options { attachments_dir: None, bodies: false })?;
    let mut out = BufWriter::new(std::io::stdout().lock());
    writeln!(out, "{}", walker.store_line())?;
    let mut failed = None;
    walker.walk(&mut |line: Value| {
        if let Err(err) = writeln!(out, "{line}") {
            failed.get_or_insert(err);
        }
    })?;
    if let Some(err) = failed {
        return Err(err.into());
    }
    let s = &walker.stats;
    writeln!(out, "{}", json!({
        "type": "summary", "folders": s.folders, "mails": s.mails, "other_items": s.other_items, "errors": s.errors,
        "seconds": (started.elapsed().as_secs_f64() * 100.0).round() / 100.0,
    }))?;
    out.flush()?;
    Ok(())
}

fn read<B: Backend>(backend: B, nodes: &[u32], attachments: Option<&Path>) -> Result<()> {
    if let Some(dir) = attachments {
        std::fs::create_dir_all(dir)?;
    }
    let mut walker = Walker::new(backend, Options { attachments_dir: attachments, bodies: true })?;
    let mut out = BufWriter::new(std::io::stdout().lock());
    writeln!(out, "{}", walker.store_line())?;
    let mut failed = None;
    walker.read(nodes, &mut |line: Value| {
        if let Err(err) = writeln!(out, "{line}") {
            failed.get_or_insert(err);
        }
    });
    if let Some(err) = failed {
        return Err(err.into());
    }
    writeln!(out, "{}", json!({"type": "summary", "mails": walker.stats.mails, "errors": walker.stats.errors}))?;
    out.flush()?;
    Ok(())
}

fn main() -> ExitCode {
    let (command, file) = match parse_args() {
        Ok(parsed) => parsed,
        Err(err) => {
            eprintln!("{err:#}");
            return ExitCode::from(1);
        }
    };
    if let Command::Open { node } = command {
        return open::show(&file, node);
    }
    let result = match open(&file) {
        Ok(Opened::Unicode(b)) => run(b, &command),
        Ok(Opened::Ansi(b)) => run(b, &command),
        Err(err) if is_locked(&err) => {
            println!("{}", json!({"type": "error", "error": "locked", "detail": "the PST is open in Outlook"}));
            return ExitCode::from(3);
        }
        Err(err) => Err(anyhow!(err).context("cannot open the PST")),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("{err:#}");
            ExitCode::from(1)
        }
    }
}

fn run<B: Backend>(backend: B, command: &Command) -> Result<()> {
    match command {
        Command::List => list(backend),
        Command::Read { nodes, attachments } => read(backend, nodes, attachments.as_deref()),
        Command::Open { .. } => unreachable!(),
    }
}
