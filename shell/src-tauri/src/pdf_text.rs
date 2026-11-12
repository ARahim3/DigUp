// Full-text PDF extraction for exact quote search. The fast book digest used by ranked search only samples a few
// windows of a book, so a sentence from the middle of a chapter is not in it; a quote needs every page's text.

use lopdf::Document;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;

/// The text of every page of the PDF at `path`, each page followed by a form feed (`'\x0c'`) so a position in the
/// text maps back to a page number. `None` when the file cannot be parsed (damaged, password protected) or holds no
/// text (scans).
pub fn extract_full_pdf_text(path: &Path) -> Option<String> {
    catch_unwind(AssertUnwindSafe(|| extract(path))).ok().flatten()
}

fn extract(path: &Path) -> Option<String> {
    let doc = Document::load(path).ok()?;
    if doc.is_encrypted() {
        return None;
    }
    let mut out = String::new();
    for page in doc.get_pages().keys() {
        if let Ok(text) = doc.extract_text(&[*page]) {
            out.push_str(&text);
        }
        out.push('\x0c');
    }
    (out.bytes().any(|b| b.is_ascii_alphabetic())).then_some(out)
}
