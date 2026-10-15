//! Walking a PST, or reading some of its mails, and turning each mail into a JSON object.
//!
//! The crate reads attachments only from concrete store and message types (Unicode or ANSI PST),
//! so the walk is generic over a small `Backend` trait implemented for both.

use std::{collections::BTreeMap, io, path::Path, rc::Rc};

use outlook_pst::{
    ltp::{prop_context::PropertyValue, table_context::TableContext},
    messaging::{
        attachment::{AnsiAttachment, Attachment, AttachmentData, UnicodeAttachment},
        folder::Folder,
        message::{AnsiMessage, Message, UnicodeMessage},
        store::{AnsiStore, EntryId, Store, UnicodeStore},
    },
    ndb::node_id::NodeId,
    AnsiPstFile, UnicodePstFile,
};
use serde_json::{json, Value};

use crate::text::{collapse_blank_lines, decode_8bit, filetime_to_iso, html_to_text, rtf_to_text};

// MAPI property ids.
const PR_MESSAGE_CLASS: u16 = 0x001A;
const PR_SUBJECT: u16 = 0x0037;
const PR_CLIENT_SUBMIT_TIME: u16 = 0x0039;
const PR_SENT_REPRESENTING_NAME: u16 = 0x0042;
const PR_SENT_REPRESENTING_EMAIL_ADDRESS: u16 = 0x0065;
const PR_TRANSPORT_MESSAGE_HEADERS: u16 = 0x007D;
const PR_DISPLAY_CC: u16 = 0x0E03;
const PR_DISPLAY_TO: u16 = 0x0E04;
const PR_SENDER_NAME: u16 = 0x0C1A;
const PR_SENDER_EMAIL_ADDRESS: u16 = 0x0C1F;
const PR_RECIPIENT_TYPE: u16 = 0x0C15;
const PR_MESSAGE_DELIVERY_TIME: u16 = 0x0E06;
const PR_ATTACH_SIZE: u16 = 0x0E20;
const PR_BODY: u16 = 0x1000;
const PR_RTF_COMPRESSED: u16 = 0x1009;
const PR_HTML: u16 = 0x1013;
const PR_DISPLAY_NAME: u16 = 0x3001;
const PR_EMAIL_ADDRESS: u16 = 0x3003;
const PR_LAST_MODIFICATION_TIME: u16 = 0x3008;
const PR_ATTACH_FILENAME: u16 = 0x3704;
const PR_ATTACH_METHOD: u16 = 0x3705;
const PR_ATTACH_LONG_FILENAME: u16 = 0x3707;
const PR_ATTACH_CONTENT_ID: u16 = 0x3712;
const PR_SMTP_ADDRESS: u16 = 0x39FE;
const PR_INTERNET_CPID: u16 = 0x3FDE;
const PR_MESSAGE_CODEPAGE: u16 = 0x3FFD;
const PR_SENDER_SMTP_ADDRESS: u16 = 0x5D01;
const PR_SENT_REPRESENTING_SMTP_ADDRESS: u16 = 0x5D02;
const PR_ATTACHMENT_HIDDEN: u16 = 0x7FFE;

const ATTACH_BY_VALUE: i32 = 1;

/// Options of a run.
pub struct Options<'a> {
    /// Write attachment bytes there (`ENTRYID_N.ext`); None: list attachments only.
    pub attachments_dir: Option<&'a Path>,
    /// Include body text in the JSON lines.
    pub bodies: bool,
}

/// Counters for the summary line.
#[derive(Default)]
pub struct Stats {
    pub folders: usize,
    pub items: usize,
    pub mails: usize,
    pub other_items: usize,
    pub errors: usize,
    pub body_kinds: BTreeMap<&'static str, usize>,
    pub body_chars: usize,
    pub attachments: usize,
    pub embedded_messages: usize,
    pub error_kinds: BTreeMap<String, usize>,
}

/// What differs between Unicode and ANSI PSTs.
pub trait Backend {
    type Msg: Message + 'static;
    fn store(&self) -> Rc<dyn Store>;
    fn open_message(&self, entry_id: &EntryId) -> io::Result<Rc<Self::Msg>>;
    fn open_attachment(&self, message: &Rc<Self::Msg>, sub_node: NodeId) -> io::Result<Rc<dyn Attachment>>;
}

pub struct UnicodeBackend(pub Rc<UnicodeStore>);
pub struct AnsiBackend(pub Rc<AnsiStore>);

impl Backend for UnicodeBackend {
    type Msg = UnicodeMessage;
    fn store(&self) -> Rc<dyn Store> {
        self.0.clone()
    }
    fn open_message(&self, entry_id: &EntryId) -> io::Result<Rc<UnicodeMessage>> {
        UnicodeMessage::read(self.0.clone(), entry_id, None)
    }
    fn open_attachment(&self, message: &Rc<UnicodeMessage>, sub_node: NodeId) -> io::Result<Rc<dyn Attachment>> {
        Ok(UnicodeAttachment::read(message.clone(), sub_node, None)?)
    }
}

impl Backend for AnsiBackend {
    type Msg = AnsiMessage;
    fn store(&self) -> Rc<dyn Store> {
        self.0.clone()
    }
    fn open_message(&self, entry_id: &EntryId) -> io::Result<Rc<AnsiMessage>> {
        AnsiMessage::read(self.0.clone(), entry_id, None)
    }
    fn open_attachment(&self, message: &Rc<AnsiMessage>, sub_node: NodeId) -> io::Result<Rc<dyn Attachment>> {
        Ok(AnsiAttachment::read(message.clone(), sub_node, None)?)
    }
}

/// Opens a PST, Unicode first then ANSI. A file Outlook has open fails with a lock error.
pub enum Opened {
    Unicode(UnicodeBackend),
    Ansi(AnsiBackend),
}

pub fn open(path: &Path) -> io::Result<Opened> {
    match UnicodePstFile::open(path) {
        Ok(file) => Ok(Opened::Unicode(UnicodeBackend(UnicodeStore::read(Rc::new(file))?))),
        Err(err) if is_locked(&err) => Err(err),
        Err(_) => Ok(Opened::Ansi(AnsiBackend(AnsiStore::read(Rc::new(AnsiPstFile::open(path)?))?))),
    }
}

/// Windows' sharing and lock violations: Outlook has the file open.
pub fn is_locked(err: &io::Error) -> bool {
    matches!(err.raw_os_error(), Some(32) | Some(33)) || err.kind() == io::ErrorKind::PermissionDenied
}

fn string(value: Option<&PropertyValue>, code_page: Option<u32>) -> Option<String> {
    match value? {
        PropertyValue::String8(v) => Some(decode_8bit(v.buffer(), code_page)),
        PropertyValue::Unicode(v) => Some(String::from_utf16_lossy(v.buffer())),
        _ => None,
    }
    .map(|s| s.trim_end_matches('\0').to_string())
}

fn int(value: Option<&PropertyValue>) -> Option<i32> {
    match value? {
        PropertyValue::Integer32(v) => Some(*v),
        _ => None,
    }
}

fn time(value: Option<&PropertyValue>) -> Option<String> {
    match value? {
        PropertyValue::Time(v) => filetime_to_iso(*v),
        _ => None,
    }
}

/// The subject, without the 2-character prefix marker MAPI may store in front of it.
fn subject(value: Option<&PropertyValue>, code_page: Option<u32>) -> String {
    let s = string(value, code_page).unwrap_or_default();
    match s.chars().next() {
        Some('\u{1}') => s.chars().skip(2).collect(),
        _ => s,
    }
}

/// Internet headers (PR_TRANSPORT_MESSAGE_HEADERS), unfolded, by lower-case name (first value wins).
fn headers(raw: &str) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    let mut current: Option<(String, String)> = None;
    for line in raw.lines() {
        if line.starts_with([' ', '\t']) {
            if let Some((_, value)) = current.as_mut() {
                value.push(' ');
                value.push_str(line.trim());
            }
            continue;
        }
        if let Some((name, value)) = current.take() {
            out.entry(name).or_insert(value);
        }
        if line.is_empty() {
            break;
        }
        if let Some((name, value)) = line.split_once(':') {
            current = Some((name.trim().to_ascii_lowercase(), value.trim().to_string()));
        }
    }
    if let Some((name, value)) = current {
        out.entry(name).or_insert(value);
    }
    out
}

/// "Jean Dupont <jean@x.fr>, b@y.fr, Bob" as (name, email) pairs; a part without an address
/// (exports from Lotus Notes and others) keeps its name with an empty email.
fn addresses(list: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let mut depth = 0;
    let mut quoted = false;
    let mut start = 0;
    let bytes = list.as_bytes();
    let mut parts = Vec::new();
    for (i, &b) in bytes.iter().enumerate() {
        match b {
            b'"' => quoted = !quoted,
            b'<' if !quoted => depth += 1,
            b'>' if !quoted => depth -= 1,
            b',' | b';' if !quoted && depth == 0 => {
                parts.push(&list[start..i]);
                start = i + 1;
            }
            _ => {}
        }
    }
    parts.push(&list[start..]);
    for part in parts {
        let part = part.trim();
        let (name, email) = match (part.rfind('<'), part.rfind('>')) {
            (Some(a), Some(b)) if a < b => (part[..a].trim().trim_matches('"').trim(), part[a + 1..b].trim()),
            _ => ("", part),
        };
        if email.contains('@') {
            out.push((name.to_string(), email.to_string()));
        } else if !part.is_empty() {
            out.push((part.trim_matches('"').trim().to_string(), String::new()));
        }
    }
    out
}

fn is_address(s: &str) -> bool {
    s.contains('@') && !s.contains(' ')
}

type Props<'a> = dyn Fn(u16) -> Option<&'a PropertyValue> + 'a;

fn code_page_of(get: &Props) -> Option<u32> {
    int(get(PR_INTERNET_CPID)).or_else(|| int(get(PR_MESSAGE_CODEPAGE))).map(|v| v as u32)
}

/// Body text and where it came from: plain text, else HTML, else RTF.
fn body(get: &Props) -> (&'static str, String) {
    let cp = code_page_of(get);
    if let Some(text) = string(get(PR_BODY), cp).filter(|t| !t.trim().is_empty()) {
        return ("text", collapse_blank_lines(&text));
    }
    let html = match get(PR_HTML) {
        Some(PropertyValue::Binary(v)) => Some(decode_8bit(v.buffer(), cp.or(Some(65001)))),
        other => string(other, cp),
    };
    if let Some(html) = html.filter(|h| !h.trim().is_empty()) {
        return ("html", html_to_text(&html));
    }
    if let Some(PropertyValue::Binary(v)) = get(PR_RTF_COMPRESSED) {
        if let Ok(rtf) = compressed_rtf::decompress_rtf(v.buffer()) {
            return ("rtf", rtf_to_text(&rtf));
        }
    }
    ("none", String::new())
}

/// Rows of a table as maps from property id to value.
fn table_rows(table: &dyn TableContext) -> Vec<(u32, BTreeMap<u16, PropertyValue>)> {
    let context = table.context();
    table
        .rows_matrix()
        .filter_map(|row| {
            let columns = row.columns(context).ok()?;
            let mut values = BTreeMap::new();
            for (column, value) in context.columns().iter().zip(columns) {
                if let Some(value) = value.as_ref() {
                    if let Ok(v) = table.read_column(value, column.prop_type()) {
                        values.insert(column.prop_id(), v);
                    }
                }
            }
            Some((u32::from(row.id()), values))
        })
        .collect()
}

/// Recipients from the recipient table, else from the Internet headers, else names only from
/// PR_DISPLAY_TO / PR_DISPLAY_CC.
fn recipients(message: &dyn Message, get: &Props, hdrs: &BTreeMap<String, String>, code_page: Option<u32>)
              -> Vec<Value> {
    let from_table = match message.recipient_table() {
        Some(table) => table_recipients(table.as_ref(), code_page),
        None => Vec::new(),
    };
    if !from_table.is_empty() {
        return from_table;
    }
    let mut out = Vec::new();
    for (kind, header) in [("to", "to"), ("cc", "cc")] {
        for (name, email) in hdrs.get(header).map(|v| addresses(v)).unwrap_or_default() {
            out.push(json!({"kind": kind, "name": name, "email": email}));
        }
    }
    if !out.is_empty() {
        return out;
    }
    for (kind, id) in [("to", PR_DISPLAY_TO), ("cc", PR_DISPLAY_CC)] {
        for name in string(get(id), code_page).unwrap_or_default().split(';') {
            let name = name.trim();
            if !name.is_empty() {
                out.push(json!({"kind": kind, "name": name, "email": ""}));
            }
        }
    }
    out
}

fn table_recipients(table: &dyn TableContext, code_page: Option<u32>) -> Vec<Value> {
    table_rows(table)
        .into_iter()
        .map(|(_, row)| {
            let kind = match int(row.get(&PR_RECIPIENT_TYPE)) {
                Some(2) => "cc",
                Some(3) => "bcc",
                _ => "to",
            };
            let email = string(row.get(&PR_SMTP_ADDRESS), code_page)
                .or_else(|| string(row.get(&PR_EMAIL_ADDRESS), code_page))
                .unwrap_or_default();
            json!({"kind": kind, "name": string(row.get(&PR_DISPLAY_NAME), code_page).unwrap_or_default(),
                   "email": email})
        })
        .collect()
}

pub fn entry_id_hex(record_key: &[u8; 16], node: u32) -> String {
    let mut bytes = vec![0u8; 4];
    bytes.extend_from_slice(record_key);
    bytes.extend_from_slice(&node.to_le_bytes());
    bytes.iter().map(|b| format!("{b:02X}")).collect()
}

fn safe_name(name: &str) -> String {
    let ext = Path::new(name).extension().and_then(|e| e.to_str()).unwrap_or("");
    let ext: String = ext.chars().filter(|c| c.is_ascii_alphanumeric()).take(10).collect();
    if ext.is_empty() { String::new() } else { format!(".{}", ext.to_ascii_lowercase()) }
}

pub struct Walker<'a, B: Backend> {
    pub backend: B,
    pub options: Options<'a>,
    pub stats: Stats,
    record_key: [u8; 16],
}

impl<'a, B: Backend> Walker<'a, B> {
    pub fn new(backend: B, options: Options<'a>) -> io::Result<Self> {
        let record_key = *backend.store().properties().make_entry_id(NodeId::from(0u32))?.record_key();
        Ok(Self { backend, options, stats: Stats::default(), record_key })
    }

    pub fn store_line(&self) -> Value {
        let store = self.backend.store();
        json!({"type": "store", "display_name": store.properties().display_name().unwrap_or_default(),
               "record_key": self.record_key.iter().map(|b| format!("{b:02X}")).collect::<String>()})
    }

    fn error(&mut self, folder: &str, node: Option<u32>, err: &dyn std::fmt::Display, emit: &mut dyn FnMut(Value)) {
        self.stats.errors += 1;
        let kind: String = err.to_string().chars().take(80).collect();
        *self.stats.error_kinds.entry(kind.clone()).or_default() += 1;
        emit(json!({"type": "error", "folder": folder, "node": node, "error": kind}));
    }

    /// Walks the folders Outlook shows (the IPM subtree), calling `emit` with one JSON value per mail.
    pub fn walk(&mut self, emit: &mut dyn FnMut(Value)) -> io::Result<()> {
        let store = self.backend.store();
        let ipm = store.properties().ipm_sub_tree_entry_id()?;
        let root = store.open_folder(&ipm)?;
        self.folder(root, "", emit);
        Ok(())
    }

    /// Reads the mails with these node ids, in this order, wherever they are (their folder isn't looked up: `list`
    /// gave it). A node that's gone, or isn't a mail, gets an error line.
    pub fn read(&mut self, nodes: &[u32], emit: &mut dyn FnMut(Value)) {
        let store = self.backend.store();
        for &node in nodes {
            let (mails, errors) = (self.stats.mails, self.stats.errors);
            let opened = store
                .properties()
                .make_entry_id(NodeId::from(node))
                .and_then(|entry_id| self.backend.open_message(&entry_id));
            match opened {
                Ok(message) => self.message(&message, node, "", emit),
                Err(err) => self.error("", Some(node), &err, emit),
            }
            if self.stats.mails == mails && self.stats.errors == errors {
                self.error("", Some(node), &"not a mail", emit);
            }
        }
    }

    fn folder(&mut self, folder: Rc<dyn Folder>, path: &str, emit: &mut dyn FnMut(Value)) {
        self.stats.folders += 1;
        let store = self.backend.store();
        if let Some(contents) = folder.contents_table() {
            let nodes: Vec<u32> = contents.rows_matrix().map(|row| u32::from(row.id())).collect();
            for node in nodes {
                self.stats.items += 1;
                let opened = store
                    .properties()
                    .make_entry_id(NodeId::from(node))
                    .and_then(|entry_id| self.backend.open_message(&entry_id));
                match opened {
                    Ok(message) => self.message(&message, node, path, emit),
                    Err(err) => self.error(path, Some(node), &err, emit),
                }
            }
        }
        if let Some(hierarchy) = folder.hierarchy_table() {
            let nodes: Vec<u32> = hierarchy.rows_matrix().map(|row| u32::from(row.id())).collect();
            for node in nodes {
                let sub = store.properties().make_entry_id(NodeId::from(node)).and_then(|id| store.open_folder(&id));
                match sub {
                    Ok(sub) => {
                        let name = sub.properties().display_name().unwrap_or_default();
                        self.folder(sub, &format!("{path}/{name}"), emit);
                    }
                    Err(err) => self.error(path, Some(node), &err, emit),
                }
            }
        }
    }

    fn message(&mut self, message: &Rc<B::Msg>, node: u32, folder: &str, emit: &mut dyn FnMut(Value)) {
        let props = message.properties();
        let get = |id: u16| props.get(id);
        let cp = code_page_of(&get);
        let class = string(get(PR_MESSAGE_CLASS), cp).unwrap_or_default();
        if !class.to_ascii_uppercase().starts_with("IPM.NOTE") {
            self.stats.other_items += 1;
            return;
        }
        self.stats.mails += 1;
        let entry_id = entry_id_hex(&self.record_key, node);
        let (kind, text) = body(&get);
        *self.stats.body_kinds.entry(kind).or_default() += 1;
        self.stats.body_chars += text.chars().count();
        let hdrs = headers(&string(get(PR_TRANSPORT_MESSAGE_HEADERS), cp).unwrap_or_default());
        let header_from = hdrs.get("from").map(|v| addresses(v)).unwrap_or_default().into_iter().next();
        let header_from_email = header_from.as_ref().map(|(_, e)| e.clone()).filter(|e| !e.is_empty());
        let sender_email = [PR_SENDER_SMTP_ADDRESS, PR_SENDER_EMAIL_ADDRESS, PR_SENT_REPRESENTING_SMTP_ADDRESS,
                            PR_SENT_REPRESENTING_EMAIL_ADDRESS]
            .iter()
            .filter_map(|id| string(get(*id), cp))
            .find(|s| is_address(s))
            .or(header_from_email)
            .unwrap_or_default();
        let sender_name = string(get(PR_SENDER_NAME), cp)
            .or_else(|| string(get(PR_SENT_REPRESENTING_NAME), cp))
            .filter(|s| !s.is_empty())
            .or_else(|| header_from.as_ref().map(|(n, _)| n.clone()).filter(|n| !n.is_empty()))
            .unwrap_or_default();
        let attachments = self.attachments(message, &entry_id, folder, node, emit);
        let mut line = json!({
            "type": "mail",
            "entry_id": entry_id,
            "node": node,
            "folder": folder,
            "class": class,
            "subject": subject(get(PR_SUBJECT), cp),
            "sender_name": sender_name,
            "sender_email": sender_email,
            "recipients": recipients(message.as_ref(), &get, &hdrs, cp),
            "sent": time(get(PR_CLIENT_SUBMIT_TIME)),
            "received": time(get(PR_MESSAGE_DELIVERY_TIME)),
            "modified": time(get(PR_LAST_MODIFICATION_TIME)),
            "body_kind": kind,
            "attachments": attachments,
        });
        if self.options.bodies {
            line["body"] = Value::String(text);
        }
        emit(line);
    }

    fn attachments(&mut self, message: &Rc<B::Msg>, entry_id: &str, folder: &str, node: u32,
                   emit: &mut dyn FnMut(Value)) -> Vec<Value> {
        let Some(table) = message.attachment_table() else { return Vec::new() };
        let rows: Vec<u32> = table.rows_matrix().map(|row| u32::from(row.id())).collect();
        let mut out = Vec::new();
        for (n, sub_node) in rows.into_iter().enumerate() {
            let attachment = match self.backend.open_attachment(message, NodeId::from(sub_node)) {
                Ok(a) => a,
                Err(err) => {
                    self.error(folder, Some(node), &format!("attachment: {err}"), emit);
                    continue;
                }
            };
            self.stats.attachments += 1;
            let props = attachment.properties();
            let name = string(props.get(PR_ATTACH_LONG_FILENAME), None)
                .or_else(|| string(props.get(PR_ATTACH_FILENAME), None))
                .or_else(|| string(props.get(PR_DISPLAY_NAME), None))
                .unwrap_or_default();
            let method = int(props.get(PR_ATTACH_METHOD)).unwrap_or(0);
            let content_id = string(props.get(PR_ATTACH_CONTENT_ID), None);
            let hidden = matches!(props.get(PR_ATTACHMENT_HIDDEN), Some(PropertyValue::Boolean(true)));
            let mut item = json!({"name": name, "method": method, "size": int(props.get(PR_ATTACH_SIZE)),
                                  "inline": hidden || content_id.is_some()});
            match attachment.data() {
                Some(AttachmentData::Binary(data)) if method == ATTACH_BY_VALUE => {
                    item["bytes"] = json!(data.buffer().len());
                    if let Some(dir) = self.options.attachments_dir {
                        let path = dir.join(format!("{entry_id}_{n}{}", safe_name(&name)));
                        match std::fs::write(&path, data.buffer()) {
                            Ok(()) => item["path"] = json!(path.to_string_lossy()),
                            Err(err) => self.error(folder, Some(node), &format!("attachment write: {err}"), emit),
                        }
                    }
                }
                Some(AttachmentData::Message(embedded)) => {
                    self.stats.embedded_messages += 1;
                    let eprops = embedded.properties();
                    let eget = |id: u16| eprops.get(id);
                    let ecp = code_page_of(&eget);
                    let (ekind, etext) = body(&eget);
                    let mut e = json!({"subject": subject(eget(PR_SUBJECT), ecp),
                                       "sender_name": string(eget(PR_SENDER_NAME), ecp).unwrap_or_default(),
                                       "sent": time(eget(PR_CLIENT_SUBMIT_TIME)), "body_kind": ekind});
                    if self.options.bodies {
                        e["body"] = Value::String(etext);
                    }
                    item["embedded"] = e;
                }
                _ => {}
            }
            out.push(item);
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn header_parsing() {
        let raw = "Received: from x\r\n\tby y\r\nFrom: \"Dupont, Jean\" <jean.dupont@x.fr>\r\nTo: a@b.fr,\r\n Claire <claire@c.fr>; Bob\r\nSubject: Devis\r\n\r\nbody: no";
        let h = headers(raw);
        assert_eq!(addresses(&h["from"]), vec![("Dupont, Jean".to_string(), "jean.dupont@x.fr".to_string())]);
        assert_eq!(addresses(&h["to"]), vec![(String::new(), "a@b.fr".to_string()),
                                             ("Claire".to_string(), "claire@c.fr".to_string()),
                                             ("Bob".to_string(), String::new())]);
        assert_eq!(h["received"], "from x by y");
        assert!(!h.contains_key("body"));
    }

    #[test]
    fn addresses_need_an_at_sign() {
        assert!(is_address("jean@x.fr"));
        assert!(!is_address("Michelle Cash"));
        assert!(!is_address("/O=ENRON/OU=NA/CN=RECIPIENTS/CN=MCASH"));
    }

    #[test]
    fn entry_id_layout() {
        let key = [0xFFu8, 0xD6, 0xC3, 0xDB, 0xF5, 0x3B, 0x93, 0x4B, 0xBC, 0x64, 0x68, 0x3F, 0x7D, 0xB2, 0xD9, 0xFE];
        assert_eq!(entry_id_hex(&key, 0x0020_0024), "00000000FFD6C3DBF53B934BBC64683F7DB2D9FE24002000");
    }
}
