//! Opening a result at its page (a PDF) or moment (audio, video) in the app that opens its kind (the Mac app's Opener):
//! the system's default app for the file, told where in the way it takes it. Any other app just opens the file.

use std::path::{Path, PathBuf};

/// Opens `path` at `page` (from 1) or at `seconds` in its default app, when that app can be told where; false when it
/// can't (the caller opens it plainly).
pub fn open_at(path: &str, page: Option<u32>, seconds: Option<f64>) -> bool {
    let Some(program) = default_app(path) else { return false };
    let Some(args) = arguments(&program, path, page, seconds) else { return false };
    match crate::editors::start(&program, &args) {
        Ok(()) => true,
        Err(error) => {
            eprintln!("digup-shell: {} didn't start: {error}", program.display());
            false
        }
    }
}

/// What `program` is given to show `path` at the page or the moment, if it's an app known to take one.
fn arguments(program: &Path, path: &str, page: Option<u32>, seconds: Option<f64>) -> Option<Vec<String>> {
    let name = program.file_stem()?.to_string_lossy().to_lowercase();
    if let Some(page) = page {
        return match name.as_str() {
            // Evince and its forks (Atril, Xreader, GNOME's Papers); `--page-label` would take the PDF's own labels.
            "evince" | "atril" | "xreader" | "papers" => Some(vec![format!("--page-index={page}"), path.into()]),
            "okular" => Some(vec!["-p".into(), page.to_string(), path.into()]),
            "sumatrapdf" => Some(vec!["-page".into(), page.to_string(), path.into()]),
            "acrobat" | "acrord32" => Some(vec!["/A".into(), format!("page={page}"), path.into()]),
            // Browsers show PDFs, and go to `#page=N`: Edge is Windows' usual PDF app.
            "msedge" | "chrome" | "google-chrome" | "google-chrome-stable" | "chromium" | "chromium-browser" | "brave"
            | "brave-browser" | "firefox" => {
                let mut url = tauri::Url::from_file_path(path).ok()?;
                url.set_fragment(Some(&format!("page={page}")));
                Some(vec![url.to_string()])
            }
            _ => None,
        };
    }
    let seconds = seconds?;
    match name.as_str() {
        "vlc" => Some(vec![format!("--start-time={seconds:.1}"), path.into()]),
        "mpv" => Some(vec![format!("--start={seconds:.1}"), path.into()]),
        "mpc-hc" | "mpc-hc64" | "mpc-be" | "mpc-be64" => {
            Some(vec![path.into(), "/start".into(), ((seconds * 1000.0) as u64).to_string()])
        }
        _ => None,
    }
}

/// The program that opens `path` by default: GIO's choice for its type on Linux (a Flatpak app's program is `flatpak`,
/// which nothing here knows), the association for its extension on Windows.
#[cfg(target_os = "linux")]
fn default_app(path: &str) -> Option<PathBuf> {
    use gio::prelude::AppInfoExt;
    let (kind, _) = gio::content_type_guess(Some(path), &[]);
    let program = gio::AppInfo::default_for_type(&kind, false)?.executable();
    (!program.as_os_str().is_empty()).then_some(program)
}

#[cfg(windows)]
fn default_app(path: &str) -> Option<PathBuf> {
    use windows_sys::Win32::UI::Shell::{AssocQueryStringW, ASSOCSTR_EXECUTABLE};
    let extension = Path::new(path).extension()?.to_string_lossy().to_string();
    let wide: Vec<u16> = format!(".{extension}").encode_utf16().chain([0]).collect();
    let mut buffer = [0u16; 1024];
    let mut length = buffer.len() as u32;
    // SAFETY: the extension is NUL-terminated, the buffer holds `length` characters and gets the count written back.
    let result = unsafe {
        AssocQueryStringW(0, ASSOCSTR_EXECUTABLE, wide.as_ptr(), std::ptr::null(), buffer.as_mut_ptr(), &mut length)
    };
    (result == 0 && length > 1).then(|| PathBuf::from(String::from_utf16_lossy(&buffer[..length as usize - 1])))
}

#[cfg(not(any(target_os = "linux", windows)))]
fn default_app(_: &str) -> Option<PathBuf> {
    None   // the shell is only tried out on a Mac, where the DigUp app opens at the page or moment itself
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_app_is_told_where_its_way() {
        let pdf = if cfg!(windows) { r"C:\Users\me\My Papers\report.pdf" } else { "/home/me/My Papers/report.pdf" };
        let page = |program: &str| arguments(Path::new(program), pdf, Some(3), None);
        assert_eq!(page("/usr/bin/evince"), Some(vec!["--page-index=3".to_string(), pdf.into()]));
        assert_eq!(page("okular"), Some(vec!["-p".to_string(), "3".into(), pdf.into()]));
        assert_eq!(page("SumatraPDF.exe"), Some(vec!["-page".to_string(), "3".into(), pdf.into()]));
        assert_eq!(page("Acrobat.exe"), Some(vec!["/A".to_string(), "page=3".into(), pdf.into()]));
        let url = page("msedge.exe").unwrap();
        assert!(url[0].starts_with("file:///") && url[0].ends_with("My%20Papers/report.pdf#page=3"), "{url:?}");
        assert_eq!(page("gnome-text-editor"), None);
        let video = "/home/me/clip.mp4";
        let moment = |program: &str| arguments(Path::new(program), video, None, Some(6.08));
        assert_eq!(moment("vlc"), Some(vec!["--start-time=6.1".to_string(), video.into()]));
        assert_eq!(moment("mpv"), Some(vec!["--start=6.1".to_string(), video.into()]));
        assert_eq!(moment("mpc-hc64.exe"), Some(vec![video.to_string(), "/start".into(), "6080".into()]));
        assert_eq!(moment("totem"), None);
        assert_eq!(arguments(Path::new("vlc"), video, None, None), None);
    }

    /// Windows knows an app for text files: Notepad, unless the person chose another.
    #[cfg(windows)]
    #[test]
    fn finds_the_default_app() {
        let program = default_app(r"C:\x\notes.txt").expect("an app for .txt");
        assert!(program.extension().is_some_and(|extension| extension.eq_ignore_ascii_case("exe")), "{program:?}");
    }
}
