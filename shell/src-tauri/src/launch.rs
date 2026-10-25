//! Starting programs outside DigUp: a result's app, the file manager, a code editor. From the Linux AppImage they must
//! not inherit the launcher's environment: AppRun puts the bundled libraries first on LD_LIBRARY_PATH and its hooks
//! set the bundled GTK and GStreamer up, which is right for DigUp and wrong for anything else. A viewer linking a
//! newer glib than the bundled one dies on that library path (Evince on Arch), and GTK_THEME would force Adwaita on
//! every app opened from here. DigUp's own helpers keep the environment (helper.rs).

use std::ffi::OsStr;
use std::path::Path;
use std::process::{Command, Stdio};

/// A command for a program outside DigUp. From the AppImage (`APPDIR` set), the entries AppRun and its hooks put
/// under the AppImage come off every list it changed, a list left empty goes, and its two plain settings go.
pub fn outside(program: impl AsRef<OsStr>) -> Command {
    let command = Command::new(program);
    #[cfg(target_os = "linux")]
    let command = without_appimage(command);
    command
}

#[cfg(target_os = "linux")]
fn without_appimage(mut command: Command) -> Command {
    let Ok(appdir) = std::env::var("APPDIR") else { return command };
    for name in LISTS_APPRUN_CHANGES {
        if let Ok(value) = std::env::var(name) {
            match without(&value, &appdir) {
                kept if kept.is_empty() => {
                    command.env_remove(name);
                }
                kept => {
                    command.env(name, kept);
                }
            }
        }
    }
    for name in SETTINGS_APPRUN_MAKES {
        command.env_remove(name);
    }
    command
}

/// The colon-separated lists AppImageKit's AppRun and linuxdeploy's GTK and GStreamer hooks prepend to or set
/// (`$APPDIR/usr/lib` on the library path first of all).
#[cfg(target_os = "linux")]
const LISTS_APPRUN_CHANGES: [&str; 16] = [
    "LD_LIBRARY_PATH", "PATH", "XDG_DATA_DIRS", "PYTHONPATH", "PERLLIB", "QT_PLUGIN_PATH", "GSETTINGS_SCHEMA_DIR",
    "GTK_DATA_PREFIX", "GI_TYPELIB_PATH", "GIO_MODULE_DIR", "GTK_EXE_PREFIX", "GTK_PATH", "GTK_IM_MODULE_FILE",
    "GDK_PIXBUF_MODULE_FILE", "GST_PLUGIN_SYSTEM_PATH_1_0", "GST_PLUGIN_PATH_1_0",
];
/// What the hooks set outright, not paths: the theme (Adwaita, light or dark) and GStreamer's scanner settings.
#[cfg(target_os = "linux")]
const SETTINGS_APPRUN_MAKES: [&str; 4] =
    ["GTK_THEME", "GST_REGISTRY_REUSE_PLUGIN_SCANNER", "GST_PLUGIN_SCANNER_1_0", "GST_PTP_HELPER_1_0"];

/// `list` (colon-separated) without the entries under `appdir`.
#[cfg(any(target_os = "linux", test))]
pub fn without(list: &str, appdir: &str) -> String {
    let appdir = appdir.trim_end_matches('/');
    list.split(':')
        .filter(|entry| !entry.is_empty() && *entry != appdir && !entry.starts_with(&format!("{appdir}/")))
        .collect::<Vec<_>>()
        .join(":")
}

/// Starts `program` with `args`, without waiting for it: an editor's command line hands the file over and ends, an
/// app that is its own program (a PDF viewer) stays; either way it's reaped when it ends.
pub fn start(program: &Path, args: &[String]) -> std::io::Result<()> {
    let mut command = outside(program);
    command.args(args).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x0800_0000); // CREATE_NO_WINDOW: a .cmd would otherwise flash a console
    }
    let mut child = command.spawn()?;
    std::thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(())
}

/// Opens `path` in its default app. On Linux through `xdg-open` started here (the opener plugin can't be told the
/// environment); the plugin where that isn't there, and everywhere else.
pub fn open(app: &tauri::AppHandle, path: &str) -> Result<(), String> {
    #[cfg(target_os = "linux")]
    if start(Path::new("xdg-open"), &[path.to_string()]).is_ok() {
        return Ok(());
    }
    use tauri_plugin_opener::OpenerExt;
    app.opener().open_path(path, None::<&str>).map_err(|error| error.to_string())
}

/// Shows `path` in the file manager, selected. On Linux the file manager is asked over D-Bus (it starts through the
/// bus, with its own environment), else its folder opens through `xdg-open`.
pub fn reveal(app: &tauri::AppHandle, path: &str) -> Result<(), String> {
    #[cfg(target_os = "linux")]
    {
        if show_items(path).is_ok() {
            return Ok(());
        }
        if let Some(folder) = Path::new(path).parent() {
            if start(Path::new("xdg-open"), &[folder.display().to_string()]).is_ok() {
                return Ok(());
            }
        }
    }
    use tauri_plugin_opener::OpenerExt;
    app.opener().reveal_item_in_dir(path).map_err(|error| error.to_string())
}

/// `org.freedesktop.FileManager1.ShowItems`, which Nautilus, Dolphin, Thunar and Nemo answer.
#[cfg(target_os = "linux")]
fn show_items(path: &str) -> Result<(), String> {
    let url = tauri::Url::from_file_path(path).map_err(|_| "not an absolute path".to_string())?;
    let connection = zbus::blocking::Connection::session().map_err(|error| error.to_string())?;
    let proxy = zbus::blocking::Proxy::new(&connection, "org.freedesktop.FileManager1", "/org/freedesktop/FileManager1",
                                           "org.freedesktop.FileManager1")
        .map_err(|error| error.to_string())?;
    proxy.call_method("ShowItems", &(vec![url.as_str()], "")).map_err(|error| error.to_string())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_appimages_entries_come_off_a_list() {
        let appdir = "/tmp/.mount_DigUpAb12";
        assert_eq!(without("/tmp/.mount_DigUpAb12/usr/bin:/usr/local/bin:/usr/bin", appdir), "/usr/local/bin:/usr/bin");
        assert_eq!(without("/tmp/.mount_DigUpAb12//usr/lib:/tmp/.mount_DigUpAb12/usr/lib/x86_64-linux-gnu", appdir), "");
        assert_eq!(without("/opt/own/lib:/tmp/.mount_DigUpAb12/usr/lib", appdir), "/opt/own/lib");
        // Another mount with the same prefix isn't this one.
        assert_eq!(without("/tmp/.mount_DigUpAb12x/lib", appdir), "/tmp/.mount_DigUpAb12x/lib");
        assert_eq!(without("", appdir), "");
    }
}
