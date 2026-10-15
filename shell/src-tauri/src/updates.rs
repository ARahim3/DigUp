//! In-app updates on Windows and Linux (the Mac app has Sparkle: Sources/DigUpApp/Updates.swift). Once a day, unless the
//! person turned it off (Settings → General), DigUp reads its update feed (`plugins.updater.endpoints` in
//! tauri.conf.json: updates/latest.json in DigUp's repository, which a release adds last). An update it finds waits
//! quietly, as on the Mac: "Update to DigUp X…" in the tray menu, a dot on the tray icon, a line in the window's status
//! bar. Choosing it shows what's new; then DigUp downloads it, checks its signature against the public key in
//! tauri.conf.json, installs it and starts again. The Windows installer and the AppImage update themselves; a .deb needs
//! admin rights to be replaced, so there the update's release page opens instead.

use crate::{changed, stop_helpers, Shell};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::utils::config::BundleType;
use tauri::{AppHandle, Manager};
use tauri_plugin_dialog::{DialogExt, MessageDialogButtons, MessageDialogKind};
use tauri_plugin_opener::OpenerExt;
use tauri_plugin_updater::{Update, UpdaterExt};

const DAY: u64 = 24 * 60 * 60;

#[derive(Clone, Copy, Debug, Default, PartialEq)]
enum Phase {
    #[default]
    Idle,
    Checking,
    Downloading,
    Installing,
}

#[derive(Default)]
pub struct Updates {
    /// The update found, waiting for the person to take it.
    found: Mutex<Option<Update>>,
    phase: Mutex<Phase>,
    /// How far its download has come (0…100).
    percent: Mutex<Option<u8>>,
}

impl Updates {
    /// What the tray and the pages show: null, or {"version", "state": "available|downloading|installing", "percent",
    /// "installs"} (false where a new package has to be downloaded by hand).
    pub fn snapshot(&self) -> Value {
        let found = self.found.lock().unwrap();
        let Some(update) = found.as_ref() else { return Value::Null };
        let state = match *self.phase.lock().unwrap() {
            Phase::Downloading => "downloading",
            Phase::Installing => "installing",
            _ => "available",
        };
        json!({"version": update.version, "state": state, "percent": *self.percent.lock().unwrap(),
               "installs": installs_itself()})
    }

    /// The tray menu's line for it, while one waits.
    pub fn menu_text(&self) -> Option<(String, bool)> {
        let found = self.found.lock().unwrap();
        let version = &found.as_ref()?.version;
        Some(match *self.phase.lock().unwrap() {
            Phase::Downloading => match *self.percent.lock().unwrap() {
                Some(percent) => (format!("Downloading DigUp {version}… {percent}%"), false),
                None => (format!("Downloading DigUp {version}…"), false),
            },
            Phase::Installing => (format!("Installing DigUp {version}…"), false),
            _ => (format!("Update to DigUp {version}…"), true),
        })
    }
}

/// The Windows installer and the AppImage replace themselves; a .deb, or a build that no installer put there, doesn't.
pub fn installs_itself() -> bool {
    match tauri::utils::platform::bundle_type() {
        Some(BundleType::Nsis) => true,
        Some(BundleType::AppImage) => std::env::var_os("APPIMAGE").is_some(),
        _ => false,
    }
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|time| time.as_secs()).unwrap_or(0)
}

/// A line in updates.log (beside the other logs), with the time in UTC.
fn log(shell: &Shell, line: &str) {
    use std::io::Write;
    let seconds = now();
    let (days, rest) = (seconds / DAY, seconds % DAY);
    // The civil date of a day count (Howard Hinnant's days_from_civil, inverted).
    let z = days as i64 + 719_468;
    let era = z.div_euclid(146_097);
    let day_of_era = z - era * 146_097;
    let year_of_era = (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month + 2) / 5 + 1;
    let month = if month < 10 { month + 3 } else { month - 9 };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    let stamp = format!("{year}-{month:02}-{day:02} {:02}:{:02}:{:02}Z", rest / 3600, rest / 60 % 60, rest % 60);
    if cfg!(debug_assertions) {
        println!("updates: {line}");
    }
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(shell.logs.join("updates.log")) {
        let _ = writeln!(file, "{stamp} {line}");
    }
}

/// The daily check: from a minute after DigUp starts (its own start goes first), then whenever a day has passed since
/// the last check. Not in dev runs or debug builds (they'd read the real feed), unless `--debug-update-check` asks for
/// one check at once (then `--debug-update-install` takes what it finds without asking).
pub fn start(app: &AppHandle) {
    let shell = app.state::<Arc<Shell>>().inner().clone();
    log(&shell, &format!("DigUp {} started", app.package_info().version));
    let debug = shell.options.debug_update_check;
    if !debug && (cfg!(debug_assertions) || shell.dev_run()) {
        return;
    }
    let app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(if debug { 2 } else { 60 }));
        loop {
            let due = debug || {
                let settings = shell.settings.lock().unwrap();
                !settings.update_checks_off && now().saturating_sub(settings.update_checked) >= DAY
            };
            if due {
                tauri::async_runtime::block_on(check(&app, false));
            }
            if debug {
                return;
            }
            std::thread::sleep(Duration::from_secs(60 * 60));
        }
    });
}

/// Reads the feed. `asked`: the person chose Check for Updates…, and hears the answer (an update is then offered at
/// once); a daily check stays quiet and lets an update wait.
pub async fn check(app: &AppHandle, asked: bool) {
    let shell = app.state::<Arc<Shell>>().inner().clone();
    {
        let mut phase = shell.updates.phase.lock().unwrap();
        if *phase != Phase::Idle {
            drop(phase);
            if asked {
                offer(app);
            }
            return;
        }
        *phase = Phase::Checking;
    }
    // Before DigUp exits for the Windows installer: the helpers stop, and any other `digup` it started (a speed check)
    // ends and is gone, or the installer can't replace their files.
    let exiting = app.clone();
    let result = match app.updater_builder().on_before_exit(move || {
        stop_helpers(&exiting);
        crate::helper::end_all();
        exiting.cleanup_before_exit();
    }).build() {
        Ok(updater) => updater.check().await,
        Err(error) => Err(error),
    };
    *shell.updates.phase.lock().unwrap() = Phase::Idle;
    {
        let mut settings = shell.settings.lock().unwrap();
        settings.update_checked = now();
        let _ = settings.save(&shell.settings_path);
    }
    match result {
        Ok(Some(update)) => {
            log(&shell, &format!("found {} ({})", update.version, update.download_url));
            *shell.updates.found.lock().unwrap() = Some(update);
            changed(app);
            if asked {
                offer(app);
            } else if shell.options.debug_update_install {
                if installs_itself() {
                    install(app).await;
                } else {
                    log(&shell, "not installing it: this copy doesn't update itself (its release page would open)");
                }
            }
        }
        Ok(None) => {
            log(&shell, "up to date");
            *shell.updates.found.lock().unwrap() = None;
            changed(app);
            if asked {
                tell(app, "You're up to date", &format!("DigUp {} is the newest version.", app.package_info().version));
            }
        }
        Err(error) => {
            log(&shell, &format!("couldn't check: {error}"));
            if asked {
                tell(app, "Check for Updates", &format!("DigUp couldn't check for updates: {error}"));
            }
        }
    }
}

/// "Update to DigUp X…": what's new, then Install and Restart (or, for a .deb, the release page to download it from).
pub fn offer(app: &AppHandle) {
    let shell = app.state::<Arc<Shell>>().inner().clone();
    let Some(update) = shell.updates.found.lock().unwrap().clone() else { return };
    if *shell.updates.phase.lock().unwrap() != Phase::Idle {
        return;   // already on its way
    }
    let installs = installs_itself();
    let mut text = format!("DigUp {} is available. You have {}.", update.version, app.package_info().version);
    if let Some(notes) = update.body.as_deref().map(str::trim).filter(|notes| !notes.is_empty()) {
        text.push_str("\n\n");
        text.push_str(notes);
    }
    if !installs {
        text.push_str("\n\nDownload the new package from its release page and install it as you installed this one.");
    }
    let (yes, no) = if installs { ("Install and Restart", "Not Now") } else { ("Download…", "Not Now") };
    let app = app.clone();
    app.clone()
        .dialog()
        .message(text)
        .title("DigUp Update")
        .kind(MessageDialogKind::Info)
        .buttons(MessageDialogButtons::OkCancelCustom(yes.into(), no.into()))
        .show(move |yes| {
            if !yes {
                return;
            }
            if installs {
                tauri::async_runtime::spawn(async move { install(&app).await });
            } else {
                let page = release_page(update.download_url.as_str());
                log(&app.state::<Arc<Shell>>(), &format!("opening {page}"));
                let _ = app.opener().open_url(page, None::<&str>);
            }
        });
}

/// Downloads the update, checks its signature, installs it and starts DigUp again (on Windows the installer starts it:
/// DigUp exits as the installer begins).
pub async fn install(app: &AppHandle) {
    let shell = app.state::<Arc<Shell>>().inner().clone();
    let Some(update) = shell.updates.found.lock().unwrap().clone() else { return };
    if !installs_itself() {
        return;   // a .deb (offer() opens the release page instead)
    }
    {
        let mut phase = shell.updates.phase.lock().unwrap();
        if *phase != Phase::Idle {
            return;
        }
        *phase = Phase::Downloading;
    }
    *shell.updates.percent.lock().unwrap() = None;
    changed(app);
    log(&shell, &format!("downloading {}", update.version));
    let mut received = 0u64;
    let progress = app.clone();
    let downloaded = update
        .download(
            |chunk, total| {
                received += chunk as u64;
                let Some(total) = total.filter(|total| *total > 0) else { return };
                let percent = Some((received * 100 / total).min(100) as u8);
                let shell = progress.state::<Arc<Shell>>();
                let before = std::mem::replace(&mut *shell.updates.percent.lock().unwrap(), percent);
                if before != percent {
                    changed(&progress);
                }
            },
            || {},
        )
        .await;
    // The signature is checked as the download ends: a file that doesn't match it never gets here.
    let bytes = match downloaded {
        Ok(bytes) => bytes,
        Err(error) => return failed(app, &format!("couldn't download {}: {error}", update.version)),
    };
    *shell.updates.phase.lock().unwrap() = Phase::Installing;
    changed(app);
    log(&shell, &format!("installing {} ({} bytes, signature checked)", update.version, bytes.len()));
    match update.install(bytes) {
        Ok(()) => {
            log(&shell, "starting again");
            app.restart();
        }
        Err(error) => failed(app, &format!("couldn't install {}: {error}", update.version)),
    }
}

/// The update waits again (to try later), and the person hears why.
fn failed(app: &AppHandle, problem: &str) {
    let shell = app.state::<Arc<Shell>>().inner().clone();
    log(&shell, problem);
    *shell.updates.phase.lock().unwrap() = Phase::Idle;
    *shell.updates.percent.lock().unwrap() = None;
    changed(app);
    if !shell.options.debug_update_install {
        tell(app, "DigUp Update", &format!("The update didn't go through: {problem}"));
    }
}

fn tell(app: &AppHandle, title: &str, text: &str) {
    app.dialog().message(text).title(title).kind(MessageDialogKind::Info).show(|_| {});
}

/// The GitHub release page of a release's download (…/releases/download/<tag>/<file> → …/releases/tag/<tag>), else
/// DigUp's releases.
fn release_page(download: &str) -> String {
    if let Some((repository, rest)) = download.split_once("/releases/download/") {
        if let Some((tag, _)) = rest.split_once('/') {
            return format!("{repository}/releases/tag/{tag}");
        }
    }
    "https://github.com/ARahim3/DigUp/releases".into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn release_pages() {
        assert_eq!(release_page("https://github.com/ARahim3/DigUp/releases/download/v0.7.0-beta.1/DigUp_0.7.0-beta.1_amd64.AppImage"),
                   "https://github.com/ARahim3/DigUp/releases/tag/v0.7.0-beta.1");
        assert_eq!(release_page("http://127.0.0.1:8765/DigUp.AppImage"), "https://github.com/ARahim3/DigUp/releases");
    }
}
