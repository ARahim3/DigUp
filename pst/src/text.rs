//! Turning MAPI values into text: dates, 8-bit strings, HTML and RTF bodies.

/// FILETIME (100 ns ticks since 1601-01-01 UTC) as ISO 8601 UTC. Outlook's "no date" (year 4501)
/// and zero are None.
pub fn filetime_to_iso(ticks: i64) -> Option<String> {
    if ticks <= 0 {
        return None;
    }
    let secs = ticks / 10_000_000 - 11_644_473_600;
    let (days, rem) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    let (y, m, d) = civil_from_days(days);
    if y >= 4500 {
        return None;
    }
    Some(format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z", rem / 3600, rem % 3600 / 60, rem % 60))
}

/// Days since 1970-01-01 to a proleptic Gregorian date (Howard Hinnant's algorithm).
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let y = yoe + era * 400;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// Bytes in a Windows code page (1252 when unknown).
pub fn decode_8bit(bytes: &[u8], code_page: Option<u32>) -> String {
    let encoding = code_page
        .and_then(|cp| u16::try_from(cp).ok())
        .and_then(codepage::to_encoding)
        .unwrap_or(encoding_rs::WINDOWS_1252);
    encoding.decode(bytes).0.into_owned()
}

/// HTML as plain text (no styling, no link targets), without hard wrapping.
pub fn html_to_text(html: &str) -> String {
    html2text::config::plain_no_decorate()
        .link_footnotes(false)
        .string_from_read(html.as_bytes(), 100_000)
        .unwrap_or_default()
        .lines()
        .map(str::trim_end)
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string()
}

/// Destinations whose content is never text.
const SKIPPED_DESTINATIONS: &[&str] = &[
    "fonttbl", "colortbl", "stylesheet", "info", "pict", "object", "themedata", "colorschememapping",
    "latentstyles", "datastore", "xmlnstbl", "listtable", "listoverridetable", "rsidtbl", "generator",
    "header", "footer", "headerl", "headerr", "footerl", "footerr", "fldinst", "filetbl", "revtbl",
];

/// RTF as plain text. Ignorable destinations (`{\*...}`) are skipped, which also drops the HTML
/// tags of RTF that encapsulates HTML (`\fromhtml1`) and keeps its readable text.
pub fn rtf_to_text(rtf: &str) -> String {
    #[derive(Clone, Copy)]
    struct Group {
        skip: bool,
        uc: usize,
    }
    let bytes = rtf.as_bytes();
    let mut out = String::new();
    let mut pending: Vec<u8> = Vec::new(); // \'hh bytes, decoded together (multi-byte code pages)
    let mut code_page: Option<u32> = None;
    let mut stack = vec![Group { skip: false, uc: 1 }];
    let mut fallback_skip = 0usize; // characters to drop after a \uN
    let mut i = 0;

    fn flush(out: &mut String, pending: &mut Vec<u8>, code_page: Option<u32>) {
        if !pending.is_empty() {
            out.push_str(&decode_8bit(pending, code_page));
            pending.clear();
        }
    }

    while i < bytes.len() {
        let skip = stack.last().map(|g| g.skip).unwrap_or(false);
        match bytes[i] {
            b'{' => {
                let top = *stack.last().unwrap_or(&Group { skip: false, uc: 1 });
                stack.push(top);
                i += 1;
            }
            b'}' => {
                if stack.len() > 1 {
                    stack.pop();
                }
                i += 1;
            }
            b'\\' if i + 1 < bytes.len() => {
                let c = bytes[i + 1];
                if c == b'\'' && i + 3 < bytes.len() {
                    if let Ok(byte) = u8::from_str_radix(&rtf[i + 2..i + 4], 16) {
                        if fallback_skip > 0 {
                            fallback_skip -= 1;
                        } else if !skip {
                            pending.push(byte);
                        }
                    }
                    i += 4;
                } else if c.is_ascii_alphabetic() {
                    let start = i + 1;
                    let mut j = start;
                    while j < bytes.len() && bytes[j].is_ascii_alphabetic() {
                        j += 1;
                    }
                    let word = &rtf[start..j];
                    let num_start = j;
                    if j < bytes.len() && bytes[j] == b'-' {
                        j += 1;
                    }
                    while j < bytes.len() && bytes[j].is_ascii_digit() {
                        j += 1;
                    }
                    let param: Option<i64> = rtf[num_start..j].parse().ok();
                    if j < bytes.len() && bytes[j] == b' ' {
                        j += 1;
                    }
                    i = j;
                    if !word.starts_with("u") || word == "uc" || param.is_none() {
                        flush(&mut out, &mut pending, code_page);
                    }
                    match word {
                        "ansicpg" => code_page = param.map(|p| p as u32),
                        "par" | "line" | "sect" | "row" if !skip => out.push('\n'),
                        "tab" | "cell" if !skip => out.push('\t'),
                        "emdash" if !skip => out.push('—'),
                        "endash" if !skip => out.push('–'),
                        "bullet" if !skip => out.push('•'),
                        "lquote" | "rquote" if !skip => out.push('\''),
                        "ldblquote" | "rdblquote" if !skip => out.push('"'),
                        "uc" => {
                            if let (Some(g), Some(p)) = (stack.last_mut(), param) {
                                g.uc = p.max(0) as usize;
                            }
                        }
                        "u" => {
                            if let Some(p) = param {
                                if !skip {
                                    flush(&mut out, &mut pending, code_page);
                                    let code = if p < 0 { p + 65_536 } else { p } as u32;
                                    if let Some(ch) = char::from_u32(code) {
                                        out.push(ch);
                                    }
                                }
                                fallback_skip = stack.last().map(|g| g.uc).unwrap_or(1);
                            }
                        }
                        w if SKIPPED_DESTINATIONS.contains(&w) => {
                            if let Some(g) = stack.last_mut() {
                                g.skip = true;
                            }
                        }
                        _ => {}
                    }
                } else {
                    flush(&mut out, &mut pending, code_page);
                    match c {
                        b'*' => {
                            if let Some(g) = stack.last_mut() {
                                g.skip = true;
                            }
                        }
                        b'\\' | b'{' | b'}' if !skip => out.push(c as char),
                        b'~' if !skip => out.push(' '),
                        b'\n' | b'\r' if !skip => out.push('\n'),
                        _ => {}
                    }
                    i += 2;
                }
            }
            b'\r' | b'\n' => i += 1,
            _ => {
                // One UTF-8 character of plain text.
                let ch = rtf[i..].chars().next().unwrap_or(' ');
                if fallback_skip > 0 {
                    fallback_skip -= 1;
                } else if !skip {
                    flush(&mut out, &mut pending, code_page);
                    out.push(ch);
                }
                i += ch.len_utf8();
            }
        }
    }
    flush(&mut out, &mut pending, code_page);
    collapse_blank_lines(&out)
}

/// Trim line ends and keep at most one empty line in a row.
pub fn collapse_blank_lines(text: &str) -> String {
    let mut out = Vec::new();
    let mut blank = 0;
    for line in text.lines().map(str::trim_end) {
        if line.trim().is_empty() {
            blank += 1;
            if blank > 1 {
                continue;
            }
        } else {
            blank = 0;
        }
        out.push(line);
    }
    out.join("\n").trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filetimes() {
        // 2000-06-09T14:45:00Z
        assert_eq!(filetime_to_iso(126_050_355_000_000_000).as_deref(), Some("2000-06-09T14:45:00Z"));
        assert_eq!(filetime_to_iso(0), None);
        // 4501-01-01, Outlook's "none"
        assert_eq!(filetime_to_iso(915_151_392_000_000_000), None);
    }

    #[test]
    fn code_pages() {
        assert_eq!(decode_8bit(b"r\xe9union", None), "réunion");
        assert_eq!(decode_8bit(b"r\xc3\xa9union", Some(65001)), "réunion");
        assert_eq!(decode_8bit(&[0x82, 0xa0], Some(932)), "あ");
    }

    #[test]
    fn html() {
        let text = html_to_text("<html><head><style>p{color:red}</style></head><body><p>Bonjour <b>Jean</b>,</p>\
                                 <p>Voir <a href=\"https://x.example\">le devis</a>.</p></body></html>");
        assert!(text.contains("Bonjour Jean,"), "{text}");
        assert!(text.contains("le devis"), "{text}");
        assert!(!text.contains("color"), "{text}");
    }

    #[test]
    fn rtf_plain() {
        let rtf = r"{\rtf1\ansi\ansicpg1252{\fonttbl{\f0 Calibri;}}{\colortbl;\red0\green0\blue0;}\f0 Bonjour,\par Le devis est valid\'e9.\par\pard \u8364? 42\par}";
        assert_eq!(rtf_to_text(rtf), "Bonjour,\nLe devis est validé.\n€ 42");
    }

    #[test]
    fn rtf_encapsulated_html() {
        let rtf = r"{\rtf1\ansi\ansicpg1252\fromhtml1 {\*\htmltag19 <html>}{\*\htmltag50 <body>}\htmlrtf {\htmlrtf0 Bonjour\htmlrtf }{\*\htmltag84 <br>}\htmlrtf \par \htmlrtf0 Le devis\htmlrtf }{\*\htmltag58 </body>}}";
        let text = rtf_to_text(rtf);
        assert!(text.contains("Bonjour") && text.contains("Le devis"), "{text}");
        assert!(!text.contains('<'), "{text}");
    }
}
