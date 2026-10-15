//! What the person chose: the folders DigUp searches, what it skips in them, the hotkey, and whether setup is done. A
//! JSON file in the app's config folder (%APPDATA%\com.abdurrahim.DigUp on Windows, ~/.config/com.abdurrahim.DigUp on
//! Linux). Launch arguments (`--roots`, `--hotkey`) stand in for it in dev runs.

use crate::hours::Hours;
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Settings {
    /// The folders searched and kept indexed.
    pub folders: Vec<String>,
    /// Folders inside them that aren't (`FolderSelection` in the engine).
    pub skipped: Vec<String>,
    /// File extensions left out ("heic", "txt").
    pub skip_types: Vec<String>,
    /// The panel's hotkey (Tauri's accelerator form); empty: the default.
    pub hotkey: String,
    /// Onboarding is done: the shell starts in the tray.
    pub set_up: bool,
    /// The panel sits centered where the desktop places windows itself (Wayland), in a window that fills the screen.
    pub center_panel: bool,
    /// Index only between these times of day (hours.rs); the times are kept while it's off.
    pub index_hours_on: bool,
    pub index_hours: Hours,
    /// Code search: its folders (an index of its own, code.sqlite), the folders skipped inside them, and the editor its
    /// results open in (editors.rs: an editor's id, "" for the first one found, "default" for the file's default app).
    pub code_folders: Vec<String>,
    pub code_skipped: Vec<String>,
    pub code_editor: String,
    /// Code search was turned off and its index is still to be deleted (Windows won't delete a file a helper has open).
    pub delete_code_index: bool,
    /// Where the window was left, for the next time it opens.
    pub window: Option<WindowPlace>,
    /// A click on the tray icon (Windows): "panel" shows the search panel, anything else opens the window.
    pub tray_click: String,
    /// The daily check for updates was turned off (Settings → General; it's on by default).
    pub update_checks_off: bool,
    /// When DigUp last checked for updates (seconds since 1970).
    pub update_checked: u64,
}

/// The window's size inside its frame (logical pixels), where it was (physical; Wayland doesn't tell), and whether it
/// filled the screen.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct WindowPlace {
    pub width: f64,
    pub height: f64,
    pub x: Option<i32>,
    pub y: Option<i32>,
    pub maximized: bool,
}

impl Settings {
    /// The file's settings, or the defaults when there's none (or it can't be read).
    pub fn load(path: &Path) -> Settings {
        std::fs::read(path).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default()
    }

    /// Written whole to a temporary file first, so a crash never leaves half of it.
    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        if let Some(folder) = path.parent() {
            std::fs::create_dir_all(folder)?;
        }
        let temporary = path.with_extension("json.new");
        std::fs::write(&temporary, serde_json::to_vec_pretty(self)?)?;
        std::fs::rename(temporary, path)
    }
}
