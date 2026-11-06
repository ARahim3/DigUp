//! Copying a result as a file (Ctrl+C), to paste in a file manager, a mail or a chat: the system's file list on Windows
//! (CF_HDROP, as Explorer's own Copy), GNOME's and the freedesktop file targets on Linux (Files, Dolphin and the rest take
//! one of them), with the path as text besides.

use std::path::Path;

#[cfg(windows)]
pub fn copy_file(window: &tauri::WebviewWindow, path: &Path) -> Result<(), String> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Foundation::{GlobalFree, POINT};
    use windows_sys::Win32::System::DataExchange::{CloseClipboard, EmptyClipboard, OpenClipboard, SetClipboardData};
    use windows_sys::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};
    use windows_sys::Win32::UI::Shell::DROPFILES;
    const CF_HDROP: u32 = 15;
    // DROPFILES, then the paths, each ending in a NUL and the list in another; written as Windows writes them (the helper
    // reports "D:/…").
    let native = std::path::PathBuf::from(path.to_string_lossy().replace('/', "\\"));
    let names: Vec<u16> = native.as_os_str().encode_wide().chain([0, 0]).collect();
    let header = std::mem::size_of::<DROPFILES>();
    let owner = window.hwnd().map_err(|error| error.to_string())?.0 as _;
    // SAFETY: the memory is allocated for the header and the names and written within that; once the clipboard has it,
    // it's the clipboard's (freed here only when it didn't take it).
    unsafe {
        let memory = GlobalAlloc(GMEM_MOVEABLE, header + names.len() * 2);
        if memory.is_null() {
            return Err("no memory for the clipboard".into());
        }
        let start = GlobalLock(memory) as *mut u8;
        start.cast::<DROPFILES>().write(DROPFILES { pFiles: header as u32, pt: POINT { x: 0, y: 0 }, fNC: 0, fWide: 1 });
        std::ptr::copy_nonoverlapping(names.as_ptr().cast::<u8>(), start.add(header), names.len() * 2);
        GlobalUnlock(memory);
        // The window owns the clipboard: without an owner, Windows won't take the data.
        if OpenClipboard(owner) == 0 {
            GlobalFree(memory);
            return Err("the clipboard is busy".into());
        }
        EmptyClipboard();
        let taken = !SetClipboardData(CF_HDROP, memory).is_null();
        CloseClipboard();
        if !taken {
            GlobalFree(memory);
            return Err("the clipboard didn't take the file".into());
        }
    }
    Ok(())
}

/// GTK's clipboard, from the main thread; it answers whoever pastes for as long as DigUp runs (it lives in the tray).
#[cfg(target_os = "linux")]
pub fn copy_file(window: &tauri::WebviewWindow, path: &Path) -> Result<(), String> {
    use gtk::prelude::*;
    let uri = gio::File::for_path(path).uri().to_string();
    let text = path.display().to_string();
    window
        .run_on_main_thread(move || {
            let targets = [
                gtk::TargetEntry::new("x-special/gnome-copied-files", gtk::TargetFlags::empty(), 0),
                gtk::TargetEntry::new("text/uri-list", gtk::TargetFlags::empty(), 1),
                gtk::TargetEntry::new("UTF8_STRING", gtk::TargetFlags::empty(), 2),
                gtk::TargetEntry::new("text/plain;charset=utf-8", gtk::TargetFlags::empty(), 2),
            ];
            let clipboard = gtk::Clipboard::get(&gtk::gdk::SELECTION_CLIPBOARD);
            clipboard.set_with_data(&targets, move |_, selection, info| match info {
                0 => selection.set(&selection.target(), 8, format!("copy\n{uri}").as_bytes()),
                1 => selection.set(&selection.target(), 8, format!("{uri}\r\n").as_bytes()),
                _ => {
                    selection.set_text(&text);
                }
            });
        })
        .map_err(|error| error.to_string())
}

#[cfg(not(any(windows, target_os = "linux")))]
pub fn copy_file(_: &tauri::WebviewWindow, _: &Path) -> Result<(), String> {
    Err("the shell copies files on Windows and Linux (on a Mac, the DigUp app does)".into())
}

/// Copy a result's path as plain text (Ctrl+Shift+C / Ctrl+Shift+R, issue #148): the same native
/// clipboard route as `copy_file` above, because that one is what the app has always pasted with.
/// The webview API (`navigator.clipboard`) is not a dependable floor here — Tauri serves its pages
/// from a custom scheme, `http://tauri.localhost` on Windows, which WebKit/WebView2 treat as a
/// non-secure context where the clipboard API is unavailable — so the hotkeys ride the native
/// channel, which needs no capability, no plugin, and no secure origin.
#[cfg(windows)]
pub fn copy_text(window: &tauri::WebviewWindow, text: &str) -> Result<(), String> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Foundation::GlobalFree;
    use windows_sys::Win32::System::DataExchange::{CloseClipboard, EmptyClipboard, OpenClipboard, SetClipboardData};
    use windows_sys::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};
    const CF_UNICODETEXT: u32 = 13;
    let wide: Vec<u16> = std::ffi::OsStr::new(text).encode_wide().chain([0]).collect();
    let owner = window.hwnd().map_err(|error| error.to_string())?.0 as _;
    // SAFETY: the block is sized for the text and its NUL and written within that; once the
    // clipboard takes it, it owns it (freed here only when it didn't).
    unsafe {
        let memory = GlobalAlloc(GMEM_MOVEABLE, wide.len() * 2);
        if memory.is_null() {
            return Err("no memory for the clipboard".into());
        }
        std::ptr::copy_nonoverlapping(wide.as_ptr().cast::<u8>(), GlobalLock(memory) as *mut u8, wide.len() * 2);
        GlobalUnlock(memory);
        // The window owns the clipboard: without an owner, Windows won't take the data.
        if OpenClipboard(owner) == 0 {
            GlobalFree(memory);
            return Err("the clipboard is busy".into());
        }
        EmptyClipboard();
        let taken = !SetClipboardData(CF_UNICODETEXT, memory).is_null();
        CloseClipboard();
        if !taken {
            GlobalFree(memory);
            return Err("the clipboard didn't take the text".into());
        }
    }
    Ok(())
}

#[cfg(target_os = "linux")]
pub fn copy_text(window: &tauri::WebviewWindow, text: &str) -> Result<(), String> {
    use gtk::prelude::*;
    let text = text.to_string();
    window
        .run_on_main_thread(move || {
            let clipboard = gtk::Clipboard::get(&gtk::gdk::SELECTION_CLIPBOARD);
            clipboard.set_text(&text);
        })
        .map_err(|error| error.to_string())
}

#[cfg(not(any(windows, target_os = "linux")))]
pub fn copy_text(_: &tauri::WebviewWindow, _: &str) -> Result<(), String> {
    Err("the shell copies text on Windows and Linux (on a Mac, the DigUp app does)".into())
}
