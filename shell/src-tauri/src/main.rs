// DigUp's shell for Windows and Linux (tried out on the Mac first): the tray icon, the hotkey, the search panel, the
// window, and the setup and settings windows. The work is DigUp's helper, `digup`, run as processes speaking JSON lines
// (helper.rs): `search-service` answers the panel and the window, `index-service` keeps the index current,
// `download-model` fetches the model, `estimate` sizes up folders. The Mac app (Sources/DigUpApp) is the reference for
// behavior.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod clipboard;
mod code;
mod editors;
mod helper;
mod hotkey;
mod hours;
mod moments;
mod options;
mod settings;
mod status;
mod tray_icon;
mod updates;
mod watcher;
mod wayland;

use helper::{IndexService, Launch, ModelDownload, SearchService};
use hotkey::Method;
use options::{Options, DEFAULT_HOTKEY};
use serde_json::{json, Value};
use settings::Settings;
use status::Status;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, LogicalSize, Manager, PhysicalPosition, State, WebviewUrl, WebviewWindowBuilder, WindowEvent, Wry};
use tauri_plugin_autostart::ManagerExt;
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_global_shortcut::{GlobalShortcutExt, ShortcutState};
use tauri_plugin_opener::OpenerExt;
use watcher::FolderWatcher;

const PANEL_WIDTH: f64 = 780.0;
/// The panel's window, under one name or the other: made anew when the person turns centering on or off.
const PANEL: &str = "panel";
const CENTERED_PANEL: &str = "panel-centered";
const FIELD_HEIGHT: f64 = 56.0;
/// The window's label.
const WINDOW: &str = "main";

/// What the commands and events share.
struct Shell {
    options: Options,
    settings: Mutex<Settings>,
    settings_path: PathBuf,
    /// How the panel's shortcut reaches DigUp on this desktop (hotkey.rs).
    shortcut: Method,
    /// The desktop places windows itself (GTK on Wayland), so the panel sits where it puts it unless the person has it
    /// centered (Settings): its window then fills the screen and the page places the panel (wayland.rs).
    wayland: bool,
    /// The panel's window now: PANEL, or CENTERED_PANEL when it fills the screen.
    panel_label: Mutex<&'static str>,
    search: SearchService,
    index: IndexService,
    model: ModelDownload,
    /// The model for the setup window and the tray: {"state": "checking|downloading|waiting|ready|failed", …}.
    model_state: Mutex<Value>,
    /// What indexing is doing, from the index helper's events (status.rs).
    status: Mutex<Status>,
    watcher: Mutex<Option<FolderWatcher>>,
    /// Code search's folders, watched apart: their changes reach the code index a minute after the code goes quiet.
    code_watcher: Mutex<Option<FolderWatcher>>,
    /// The tray menu's first line (what's going on), Index Now, and Pause or Resume Indexing.
    status_item: Mutex<Option<MenuItem<Wry>>>,
    index_item: Mutex<Option<MenuItem<Wry>>>,
    pause_item: Mutex<Option<MenuItem<Wry>>>,
    /// The tray's menu, and the waiting update's line in it with a line under it (while one waits).
    tray_menu: Mutex<Option<Menu<Wry>>>,
    update_item: Mutex<Option<(MenuItem<Wry>, PredefinedMenuItem<Wry>)>>,
    /// In-app updates (updates.rs).
    updates: updates::Updates,
    /// What the tray icon shows now (tray_icon.rs): redrawn only when that changes.
    tray_look: Mutex<Option<tray_icon::Look>>,
    /// When the search service last reloaded the index (while indexing, at most every few seconds).
    reloaded: Mutex<Instant>,
    /// When the index helper's watchdog ended it lately (on a file whose reading ran away).
    watchdog_stops: Mutex<Vec<Instant>>,
    /// The window's size inside its frame, as its page last reported it (GTK's own counts its title bar and shadow).
    window_inner: Mutex<Option<(f64, f64)>>,
    /// A search the panel hands the window (its query, and the kind of results to show): taken when the window opens.
    window_search: Mutex<Option<(String, Option<String>)>>,
    /// Debug runs with setup: the panel's query waits until the first index is in.
    debug_query_sent: AtomicBool,
    /// Quit was chosen: no helper starts again (an index event arriving meanwhile would start the search service).
    quitting: AtomicBool,
    /// The speed check is running (`measure_then_index`): indexing waits for it, so that the two don't share the
    /// processor.
    measuring: AtomicBool,
    /// Folder estimates running (setup's list): the speed check waits for them, for the same reason.
    estimating: AtomicUsize,
    /// A folder was taken out: the next index helper drops its files from the index (`--prune`).
    prune: AtomicBool,
    logs: PathBuf,
}

impl Shell {
    /// The folders searched: the launch arguments' in dev runs, else the settings'.
    fn folders(&self) -> Vec<String> {
        if !self.options.roots.is_empty() {
            return self.options.roots.iter().map(|root| root.display().to_string()).collect();
        }
        self.settings.lock().unwrap().folders.clone()
    }

    /// Code search's folders: the launch arguments' in dev runs, else the settings'.
    fn code_folders(&self) -> Vec<String> {
        if !self.options.code_roots.is_empty() {
            return self.options.code_roots.iter().map(|root| root.display().to_string()).collect();
        }
        self.settings.lock().unwrap().code_folders.clone()
    }

    fn is_set_up(&self) -> bool {
        !self.options.roots.is_empty() || self.settings.lock().unwrap().set_up
    }

    fn hotkey(&self) -> String {
        let chosen = self.settings.lock().unwrap().hotkey.clone();
        self.options.hotkey.clone().unwrap_or(if chosen.is_empty() { DEFAULT_HOTKEY.to_string() } else { chosen })
    }

    /// The shortcut as people read it: the desktop's, once DigUp's is there (it may have been changed there).
    fn hotkey_text(&self) -> String {
        #[cfg(target_os = "linux")]
        match self.shortcut {
            Method::Gnome => {
                if let Some(binding) = hotkey::gnome::binding() {
                    return hotkey::gnome::shown(&binding);
                }
            }
            Method::Kde => {
                if let Some(key) = hotkey::kde::current() {
                    return key;
                }
            }
            _ => {}
        }
        shortcut_text(&self.hotkey())
    }

    /// A background helper (indexing, the download), below the person's own programs for the processor.
    fn launch(&self, args: Vec<String>, log: &str) -> Launch {
        Launch {
            program: self.options.helper.clone(),
            args,
            env: self.options.models.iter().map(|models| ("DIGUP_MODELS".to_string(), models.display().to_string())).collect(),
            log: Some(self.logs.join(log)),
            background: true,
        }
    }

    fn index_arguments(&self) -> Vec<String> {
        self.options.index.iter().flat_map(|index| ["--index".to_string(), index.display().to_string()]).collect()
    }

    /// `index-service` for the folders as they are now.
    fn index_launch(&self) -> Launch {
        let settings = self.settings.lock().unwrap().clone();
        let mut args = vec!["index-service".to_string(), "--backfill".to_string()];
        if self.prune.swap(false, Ordering::SeqCst) {
            args.push("--prune".into());
        }
        args.extend(self.index_arguments());
        args.extend(folder_arguments(&settings, &self.code_folders()));
        args.extend(self.folders());
        self.launch(args, "index.log")
    }

    /// Where the code index is (deleted when code search is turned off).
    fn code_index_files(&self) -> Vec<PathBuf> {
        let Some(index) = self.options.index_folder() else { return Vec::new() };
        ["", "-wal", "-shm"].iter().map(|end| index.join(format!("code.sqlite{end}"))).collect()
    }

    fn model_ready(&self) -> bool {
        self.model_state.lock().unwrap()["state"] == "ready"
    }

    /// The panel sits centered in a window that fills the screen (Settings, on Wayland only).
    fn centers_panel(&self) -> bool {
        self.wayland && self.settings.lock().unwrap().center_panel
    }

    /// A dev run: its own index, folders or settings file. It leaves alone what an installed DigUp keeps outside its
    /// settings (the entry that opens it at login, GNOME's shortcut), which would otherwise point at the dev build.
    fn dev_run(&self) -> bool {
        self.options.index.is_some() || !self.options.roots.is_empty() || self.options.settings.is_some()
    }

    /// DigUp may open at login: not on a Mac (the DigUp app has its own login item) and not in a dev run.
    fn opens_at_login(&self) -> bool {
        !cfg!(target_os = "macos") && !self.dev_run()
    }

    /// What the pages show about indexing and the model (status.rs).
    fn snapshot(&self) -> Value {
        let model = self.model_state.lock().unwrap().clone();
        let mut snapshot = self.status.lock().unwrap().snapshot(!self.folders().is_empty(), &model);
        snapshot["hasCode"] = json!(!self.code_folders().is_empty());
        snapshot["update"] = self.updates.snapshot();
        snapshot
    }
}

/// What both helpers are told besides the folders: what's skipped in them, and code search's folders.
fn folder_arguments(settings: &Settings, code_folders: &[String]) -> Vec<String> {
    let mut args = Vec::new();
    for folder in &settings.skipped {
        args.extend(["--exclude".to_string(), folder.clone()]);
    }
    for extension in &settings.skip_types {
        args.extend(["--exclude-ext".to_string(), extension.clone()]);
    }
    for folder in code_folders {
        args.extend(["--code-root".to_string(), folder.clone()]);
    }
    for folder in &settings.code_skipped {
        args.extend(["--code-exclude".to_string(), folder.clone()]);
    }
    args
}

// MARK: Commands

/// The panel's and the window's questions for `search-service`.
#[tauri::command]
async fn ask(shell: State<'_, Arc<Shell>>, request: Value) -> Result<Value, String> {
    let op = request.get("op").and_then(Value::as_str).unwrap_or_default();
    if !["search", "embed_ahead", "text", "render", "prewarm", "status", "summaries"].contains(&op) {
        return Err(format!("not a question the panel asks: {op}"));
    }
    shell.search.ask(request).await
}

/// What indexing these folders would take, one answer per folder (`digup estimate --json`): files by kind, the first
/// pass's seconds, the rest of long files, subfolders. For setup.
#[tauri::command]
async fn estimate(shell: State<'_, Arc<Shell>>, folders: Vec<String>, code: Option<bool>) -> Result<Vec<Value>, String> {
    let helper = shell.options.helper.clone();
    // Code folders: what the code index would read in them (its time and size, repository by repository).
    let code = if code == Some(true) { vec!["--code".to_string()] } else { Vec::new() };
    // The index's costs.json: what indexing costs on this computer, once it has indexed enough.
    let index = shell.index_arguments();
    shell.estimating.fetch_add(1, Ordering::SeqCst);
    let answers = tauri::async_runtime::spawn_blocking(move || {
        let mut command = std::process::Command::new(&helper);
        command.arg("estimate").args(&folders).args(&index).args(&code).arg("--json");
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
        }
        let child = command.stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::null()).spawn()
            .map_err(|error| format!("can't run {}: {error}", helper.display()))?;
        helper::adopt(&child);
        let output = child.wait_with_output().map_err(|error| format!("can't run {}: {error}", helper.display()))?;
        Ok(String::from_utf8_lossy(&output.stdout).lines().filter_map(|line| serde_json::from_str(line).ok()).collect())
    })
    .await;
    shell.estimating.fetch_sub(1, Ordering::SeqCst);
    answers.map_err(|error| error.to_string())?
}

/// What the setup window starts from: the folders it offers, the hotkey, the model, the folders already chosen.
#[tauri::command]
fn setup_info(app: AppHandle, shell: State<'_, Arc<Shell>>) -> Value {
    let offered: Vec<PathBuf> = match &shell.options.offered {
        Some(folders) => folders.clone(),
        None => {
            let paths = app.path();
            [paths.document_dir(), paths.picture_dir(), paths.video_dir(), paths.audio_dir(), paths.desktop_dir(),
             paths.download_dir()]
                .into_iter()
                .filter_map(Result::ok)
                .filter(|folder| folder.is_dir())
                .collect()
        }
    };
    json!({
        "offered": offered.iter().map(|folder| folder.display().to_string()).collect::<Vec<_>>(),
        "chosen": shell.folders(),
        "skipped": shell.settings.lock().unwrap().skipped.clone(),
        // A first launch asks about code search too when there's code (a step after the folders).
        "codeOffered": if shell.is_set_up() { Vec::new() } else { offered_code(&app, &shell) },
        "setUp": shell.is_set_up(),
        "hotkey": shell.hotkey_text(),
        "shortcut": {"method": shell.shortcut.name(), "command": hotkey::toggle_command()},
        "model": shell.model_state.lock().unwrap().clone(),
        "state": shell.snapshot(),
        "auto": shell.options.debug_setup,
    })
}

/// Folders chosen in the system's folder picker (none when it's cancelled).
#[tauri::command]
async fn pick_folders(app: AppHandle) -> Vec<String> {
    let (sender, receiver) = tokio::sync::oneshot::channel();
    app.dialog().file().set_title("Add Folders").pick_folders(move |folders| {
        let _ = sender.send(folders);
    });
    let picked = receiver.await.ok().flatten().unwrap_or_default();
    picked.into_iter().filter_map(|folder| folder.into_path().ok()).map(|path| path.display().to_string()).collect()
}

/// Setup's folders, kept on leaving its folders step (or on Save, choosing folders later): indexing starts on them at
/// once (once the model is in), while the rest of setup goes on, as on the Mac. `skipped`: folders inside them that
/// aren't searched.
#[tauri::command]
fn apply_setup_folders(app: AppHandle, shell: State<'_, Arc<Shell>>, folders: Vec<String>, skipped: Vec<String>)
    -> Result<(), String> {
    {
        let mut settings = shell.settings.lock().unwrap();
        settings.folders = folders;
        settings.skipped = skipped;
        settings.save(&shell.settings_path).map_err(|error| format!("can't save the settings: {error}"))?;
    }
    apply_folders(&app);
    Ok(())
}

/// Setup's last step, Done (indexing has started already): the first time, DigUp opens at login from now on, gets its
/// shortcut on GNOME, and its window comes up.
#[tauri::command]
fn finish_setup(app: AppHandle, shell: State<'_, Arc<Shell>>) -> Result<(), String> {
    let first = !shell.is_set_up();
    if first {
        let mut settings = shell.settings.lock().unwrap();
        settings.set_up = true;
        settings.save(&shell.settings_path).map_err(|error| format!("can't save the settings: {error}"))?;
    }
    // The first setup has DigUp open at login (it lives in the tray; Settings turns that off), as the Mac app does.
    if first && shell.opens_at_login() {
        if let Err(error) = app.autolaunch().enable() {
            eprintln!("digup-shell: can't open at login: {error}");
        }
    }
    // The first setup adds the shortcut to GNOME's settings; a later one (Choose Folders…) leaves it as the person has
    // it there.
    #[cfg(target_os = "linux")]
    if first && shell.shortcut == Method::Gnome && !shell.dev_run() {
        if let Err(error) = hotkey::gnome::bind(&shell.hotkey(), &hotkey::toggle_command()) {
            set_status(&app, &format!("The shortcut couldn't be added to GNOME's settings: {error}"));
        }
    }
    if let Some(window) = app.get_webview_window("setup") {
        let _ = window.close();
    }
    // The first time, the window comes up: searching starts there while indexing goes on.
    if first && !shell.options.debug_setup {
        later(&app, |app| {
            let _ = show_window(app);
        });
    }
    Ok(())
}

/// Opens a result in its default app: at `page` (a PDF's, from 1) or at `seconds` (a recording's or video's) when that
/// app can be told where.
#[tauri::command]
fn open_path(app: AppHandle, path: String, page: Option<u32>, seconds: Option<f64>) -> Result<(), String> {
    hide_panel(app.clone());
    if (page.is_some() || seconds.is_some()) && moments::open_at(&path, page, seconds) {
        return Ok(());
    }
    app.opener().open_path(path, None::<&str>).map_err(|error| error.to_string())
}

/// Opens a code result at its line in the editor chosen in Settings (or the first one installed), else in its default
/// app.
#[tauri::command]
fn open_code(app: AppHandle, shell: State<'_, Arc<Shell>>, path: String, line: u32) -> Result<(), String> {
    hide_panel(app.clone());
    let choice = shell.settings.lock().unwrap().code_editor.clone();
    if let Some((editor, program)) = editors::chosen(&choice) {
        match editor.open(&program, &path, line.max(1)) {
            Ok(()) => return Ok(()),
            Err(error) => eprintln!("digup-shell: {} didn't start: {error}", program.display()),
        }
    }
    app.opener().open_path(path, None::<&str>).map_err(|error| error.to_string())
}

/// Ctrl+C on a result: the file on the clipboard, to paste in a file manager, a mail or a chat.
#[tauri::command]
fn copy_file(window: tauri::WebviewWindow, path: String) -> Result<(), String> {
    clipboard::copy_file(&window, Path::new(&path)).inspect_err(|error| eprintln!("digup-shell: can't copy {path}: {error}"))
}

/// A result dragged out of the window (to a file manager, a mail, a chat) on Windows and the Mac: the system's own drag
/// of the file, with its thumbnail (`icon`, a picture already rendered) or DigUp's icon under the pointer, started while
/// the button is down. On Linux the page drags it itself (WebKit's drag starts from the press, as Wayland wants).
#[cfg(target_os = "linux")]
#[tauri::command]
fn drag_out() {}

#[cfg(not(target_os = "linux"))]
#[tauri::command]
fn drag_out(window: tauri::WebviewWindow, path: String, icon: Option<String>) -> Result<(), String> {
    let file = PathBuf::from(if cfg!(windows) { path.replace('/', "\\") } else { path });
    let image = match icon {
        Some(icon) => drag::Image::File(icon.into()),
        None => drag::Image::Raw(include_bytes!("../icons/128x128.png").to_vec()),
    };
    let source = window.clone();
    window
        .run_on_main_thread(move || {
            let started = drag::start_drag(&source, drag::DragItem::Files(vec![file]), image, |_, _| {},
                                           drag::Options::default());
            if let Err(error) = started {
                eprintln!("digup-shell: can't drag the file out: {error}");
            }
        })
        .map_err(|error| error.to_string())
}

/// The licenses of what DigUp ships (THIRD-PARTY-NOTICES.txt, which the packages put beside the app; dev builds
/// have none).
fn licenses_file(app: &AppHandle) -> Option<PathBuf> {
    let file = app.path().resource_dir().ok()?.join("THIRD-PARTY-NOTICES.txt");
    file.is_file().then_some(file)
}

/// Settings → Storage → Licenses: the notices, in the system's text viewer.
#[tauri::command]
fn open_licenses(app: AppHandle) -> Result<(), String> {
    let file = licenses_file(&app).ok_or("this build has no license notices")?;
    app.opener().open_path(file.display().to_string(), None::<&str>).map_err(|error| error.to_string())
}

/// Shows a result in the file manager, selected.
#[tauri::command]
fn reveal(app: AppHandle, path: String) -> Result<(), String> {
    hide_panel(app.clone());
    app.opener().reveal_item_in_dir(path).map_err(|error| error.to_string())
}

#[tauri::command]
fn hide_panel(app: AppHandle) {
    if let Some(panel) = panel_window(&app) {
        let _ = panel.hide();
    }
}

/// The panel grows to show results and shrinks back to its field.
#[tauri::command]
fn panel_height(app: AppHandle, height: f64) {
    if let Some(panel) = panel_window(&app) {
        let _ = panel.set_size(LogicalSize::new(PANEL_WIDTH, height.clamp(FIELD_HEIGHT, 640.0)));
    }
}

/// Where the page drew the panel in a window that fills the screen (wayland.rs): only there does it take the pointer.
#[tauri::command]
fn panel_area(app: AppHandle, x: f64, y: f64, width: f64, height: f64) {
    #[cfg(target_os = "linux")]
    if let Some(panel) = panel_window(&app) {
        let area = (x.floor() as i32, y.floor() as i32, width.ceil() as i32, height.ceil() as i32);
        wayland::set_area(&panel, area);
    }
    #[cfg(not(target_os = "linux"))]
    let _ = (app, x, y, width, height);
}

/// Debug runs: the query the panel types in when it loads (with setup, it comes later as a "debug-query" event).
#[tauri::command]
fn debug_query(shell: State<'_, Arc<Shell>>) -> Option<String> {
    if shell.options.debug_setup {
        return None;
    }
    shell.options.debug_query.clone()
}

/// Debug runs: what the page showed for the debug query, printed (and the shell quits, if asked).
#[tauri::command]
fn debug_report(app: AppHandle, shell: State<'_, Arc<Shell>>, report: Value) {
    println!("{report}");
    if shell.options.debug_quit {
        quit(&app);
    }
}

// MARK: The window's commands

/// What the window shows besides results: the folders searched, the shortcut (none where the person has to add one),
/// indexing, and a search the panel handed over (taken once).
#[tauri::command]
fn window_info(shell: State<'_, Arc<Shell>>) -> Value {
    let search = shell.window_search.lock().unwrap().take();
    json!({
        "folders": shell.folders(),
        "hotkey": (shell.shortcut != Method::ByHand).then(|| shell.hotkey_text()),
        "state": shell.snapshot(),
        "search": search.map(|(query, kind)| json!({"query": query, "kind": kind})),
        "hasCode": !shell.code_folders().is_empty(),
        "debugQuery": shell.options.debug_window,
        "debugSettings": shell.options.debug_settings,
        "debugCopy": shell.options.debug_copy,
    })
}

/// Indexing and the model, as the pages show them (also sent as "state" events when they change).
#[tauri::command]
fn app_state(shell: State<'_, Arc<Shell>>) -> Value {
    shell.snapshot()
}

/// The panel's search in the window, for a bigger look (Ctrl+O, "Show all…"); `kind` limits it to one group.
#[tauri::command]
fn open_window(app: AppHandle, shell: State<'_, Arc<Shell>>, query: String, kind: Option<String>) {
    hide_panel(app.clone());
    *shell.window_search.lock().unwrap() = Some((query, kind));
    later(&app, |app| {
        let _ = show_window(app);
    });
}

#[tauri::command]
fn open_settings(app: AppHandle) {
    later(&app, |app| {
        let _ = show_settings(app);
    });
}

#[tauri::command]
fn choose_folders(app: AppHandle) {
    later(&app, |app| {
        let _ = show_setup(app);
    });
}

#[tauri::command]
fn index_now(app: AppHandle) {
    run_index(&app);
}

#[tauri::command]
fn quit_app(app: AppHandle) {
    quit(&app);
}

#[tauri::command]
fn pause_indexing(app: AppHandle, paused: bool) {
    set_paused(&app, paused);
}

/// The window's page, at its size now (its inside, in logical pixels).
#[tauri::command]
fn window_resized(shell: State<'_, Arc<Shell>>, width: f64, height: f64) {
    *shell.window_inner.lock().unwrap() = Some((width, height));
}

/// Ctrl+W in a window.
#[tauri::command]
fn close_window(window: tauri::WebviewWindow) {
    let _ = window.close();
}

/// Runs `work` on the main thread from its event loop, after whatever called this has returned. It's asked from another
/// thread: asked on the main thread, `run_on_main_thread` runs it at once, and a window made inside a page's command or
/// inside the message a second launch sends deadlocks WebView2 on Windows (a blank window and a frozen DigUp).
fn later(app: &AppHandle, work: impl FnOnce(&AppHandle) + Send + 'static) {
    let handle = app.clone();
    tauri::async_runtime::spawn(async move {
        let main = handle.clone();
        let _ = handle.run_on_main_thread(move || work(&main));
    });
}

/// The window, or setup while DigUp isn't set up (the tray's Open DigUp, a click on the tray icon, a second launch).
fn show_window_or_setup(app: &AppHandle) {
    later(app, |app| {
        let _ = if app.state::<Arc<Shell>>().is_set_up() { show_window(app) } else { show_setup(app) };
    });
}

fn main() {
    let options = match Options::from_args() {
        Ok(options) => options,
        Err(error) => {
            eprintln!("digup-shell: {error}");
            std::process::exit(2);
        }
    };
    // A desktop shortcut's `--toggle` while DigUp runs goes to it before this process starts GTK (hotkey.rs).
    #[cfg(target_os = "linux")]
    if options.toggle && hotkey::hand_over() {
        return;
    }
    let app = tauri::Builder::default()
        // A second launch (DigUp opened again from the app grid or the Start menu) shows the window, as on the Mac; a
        // desktop shortcut's `--toggle` shows or hides the panel. The window is made once the second launch's message
        // has been answered: on Windows it comes as a message the other process waits on.
        .plugin(tauri_plugin_single_instance::init(|app, args, _| {
            if args.iter().any(|arg| arg == "--toggle") {
                toggle_panel(app)
            } else {
                show_window_or_setup(app);
            }
        }))
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        // The launch at login says so: DigUp then waits in the tray instead of showing its window.
        .plugin(tauri_plugin_autostart::init(tauri_plugin_autostart::MacosLauncher::LaunchAgent, Some(vec!["--at-login"])))
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, _, event| {
                    if event.state == ShortcutState::Pressed {
                        toggle_panel(app);
                    }
                })
                .build(),
        )
        .setup(move |app| setup(app, options))
        .invoke_handler(tauri::generate_handler![
            ask, estimate, setup_info, pick_folders, apply_setup_folders, finish_setup, open_path, open_code, reveal, hide_panel, panel_height,
            panel_area, settings_info, set_open_at_login, set_center_panel, debug_query, debug_report, window_info,
            app_state, open_window, open_settings, choose_folders, index_now, quit_app, close_window, pause_indexing,
            remove_folder, set_skipped, set_skip_types, set_index_hours, code_setup_info, set_code_folders, choose_code_folders,
            remove_code_folder, turn_off_code, set_code_editor, window_resized, copy_file, drag_out, set_hotkey, hold_hotkey,
            set_tray_click, check_for_updates, offer_update, set_update_checks, open_licenses
        ])
        .build(tauri::generate_context!())
        .expect("DigUp couldn't start");
    app.run(|app, event| match event {
        tauri::RunEvent::Exit => {
            stop_helpers(app);
            #[cfg(target_os = "linux")]
            if app.state::<Arc<Shell>>().shortcut == Method::Kde {
                hotkey::kde::stop();
            }
        }
        // Closing the last window isn't quitting: DigUp lives in the tray.
        tauri::RunEvent::ExitRequested { code: None, api, .. } => api.prevent_exit(),
        _ => {}
    });
}

fn setup(app: &mut tauri::App, options: Options) -> Result<(), Box<dyn std::error::Error>> {
    #[cfg(target_os = "macos")]
    app.set_activation_policy(tauri::ActivationPolicy::Accessory); // the menu bar only, no Dock icon

    let handle = app.handle().clone();
    let logs = app.path().app_log_dir()?;
    std::fs::create_dir_all(&logs)?;
    let settings_path = match &options.settings {
        Some(path) => path.clone(),
        None => app.path().app_config_dir()?.join("settings.json"),
    };
    let settings = Settings::load(&settings_path);
    let roots: Vec<String> = if options.roots.is_empty() {
        settings.folders.clone()
    } else {
        options.roots.iter().map(|root| root.display().to_string()).collect()
    };
    let code_folders: Vec<String> = if options.code_roots.is_empty() {
        settings.code_folders.clone()
    } else {
        options.code_roots.iter().map(|root| root.display().to_string()).collect()
    };
    let mut search_args = vec!["search-service".to_string()];
    search_args.extend(options.index.iter().flat_map(|index| ["--index".to_string(), index.display().to_string()]));
    search_args.extend(folder_arguments(&settings, &code_folders));
    search_args.extend(roots);
    let search = SearchService::new(
        Launch {
            program: options.helper.clone(),
            args: search_args,
            env: options.models.iter().map(|models| ("DIGUP_MODELS".to_string(), models.display().to_string())).collect(),
            log: Some(logs.join("search.log")),
            background: false,   // it answers typing
        },
        {
            let app = handle.clone();
            move |event| search_event(&app, event)
        },
    );
    let index = IndexService::new({
        let app = handle.clone();
        move |event| index_event(&app, event)
    });
    let model = ModelDownload::new({
        let app = handle.clone();
        move |event| model_event(&app, event)
    });
    // Previews show files from the chosen folders (and the helper's renders, once it says where the index is).
    for root in &settings.folders {
        let _ = app.asset_protocol_scope().allow_directory(root, true);
    }
    for root in &options.roots {
        let _ = app.asset_protocol_scope().allow_directory(root, true);
    }
    let shell = Arc::new(Shell {
        options,
        settings: Mutex::new(settings),
        settings_path,
        shortcut: hotkey::method(),
        wayland: wayland::active(),
        panel_label: Mutex::new(PANEL),
        search,
        index,
        model,
        model_state: Mutex::new(json!({"state": "checking"})),
        watcher: Mutex::new(None),
        code_watcher: Mutex::new(None),
        status: Mutex::new(Status::default()),
        status_item: Mutex::new(None),
        index_item: Mutex::new(None),
        pause_item: Mutex::new(None),
        tray_menu: Mutex::new(None),
        update_item: Mutex::new(None),
        updates: updates::Updates::default(),
        tray_look: Mutex::new(None),
        reloaded: Mutex::new(Instant::now()),
        watchdog_stops: Mutex::default(),
        window_inner: Mutex::new(None),
        window_search: Mutex::new(None),
        debug_query_sent: AtomicBool::new(false),
        quitting: AtomicBool::new(false),
        measuring: AtomicBool::new(false),
        estimating: AtomicUsize::new(0),
        prune: AtomicBool::new(false),
        logs,
    });
    app.manage(shell.clone());
    if shell.settings.lock().unwrap().delete_code_index {
        delete_code_index(&shell);
    }

    make_panel(&handle, shell.centers_panel())?;
    // No tray (a session without a taskbar, a Linux desktop without one): the hotkey and the panel still work.
    if let Err(error) = make_tray(&handle, &shell) {
        eprintln!("digup-shell: no tray icon: {error}");
    }
    match shell.shortcut {
        Method::Grab => {
            let hotkey = shell.hotkey();
            if let Err(error) = app.global_shortcut().register(hotkey.as_str()) {
                set_status(&handle, &format!("The shortcut {} is taken", shortcut_text(&hotkey)));
                eprintln!("digup-shell: can't use {hotkey} as the shortcut: {error}");
            }
        }
        // GNOME runs DigUp's custom shortcut (added at setup); its command follows DigUp when DigUp moves.
        #[cfg(target_os = "linux")]
        Method::Gnome if shell.is_set_up() && !shell.dev_run() => hotkey::gnome::refresh(&hotkey::toggle_command()),
        // KDE signals DigUp while it runs.
        #[cfg(target_os = "linux")]
        Method::Kde => {
            let pressed = handle.clone();
            if let Err(error) = hotkey::kde::listen(&shell.hotkey(), move || toggle_panel(&pressed)) {
                set_status(&handle, &format!("The shortcut couldn't be added to KDE's settings: {error}"));
                eprintln!("digup-shell: can't add the shortcut to KDE's: {error}");
            }
        }
        _ => {}
    }

    // The search service starts now (the first search is then quick); the model is checked (and fetched if it's
    // missing: on first launch that runs while setup is open, as on the Mac); indexing waits for both.
    let warm = shell.clone();
    let counted = handle.clone();
    tauri::async_runtime::spawn(async move {
        if let Ok(reply) = warm.search.ask(json!({"op": "status"})).await {
            // What's indexed already, before any index helper says (none runs while indexing is held or paused).
            {
                let mut status = warm.status.lock().unwrap();
                if status.files == 0 && reply["files"].is_u64() {
                    status.apply(&json!({"event": "counts", "files": reply["files"], "searchable": reply["searchable"],
                                         "pending": reply["pending"], "unfinished": reply["unfinished"]}));
                    if status.activity == status::Activity::Starting && (status.paused || status.held_until.is_some()) {
                        status.activity = status::Activity::Idle;
                    }
                }
            }
            changed(&counted);
        }
    });
    let mut download = vec!["download-model".to_string()];
    if let Some(models) = &shell.options.models {
        download.extend(["--to".to_string(), models.display().to_string()]);
    }
    if let Err(error) = shell.model.run(&shell.launch(download, "model.log")) {
        model_event(&handle, json!({"event": "error", "message": error}));
    }
    if !shell.folders().is_empty() || !shell.code_folders().is_empty() {
        watch_folders(&handle);
    } else {
        changed(&handle);
    }
    if !shell.is_set_up() {
        show_setup(&handle)?;
    }
    let options = &shell.options;
    if options.toggle || options.debug_show && options.debug_window.is_none() {
        // Started by the shortcut (DigUp wasn't running): the panel comes up as it would have.
        show_panel(&handle);
    } else if options.debug_window.is_some() || shell.is_set_up() && !options.at_login && options.debug_query.is_none() {
        // Opened by hand: the window, so opening DigUp never looks like nothing happened (at login it waits in the
        // tray).
        if let Err(error) = show_window(&handle) {
            eprintln!("digup-shell: can't open the window: {error}");
        }
    }
    watch_hours(&handle);
    updates::start(&handle);
    // The entry that opens DigUp at login is written again: it follows DigUp if it moved, and older ones didn't say
    // `--at-login`.
    if shell.opens_at_login() && app.autolaunch().is_enabled().unwrap_or(false) {
        if let Err(error) = app.autolaunch().enable() {
            eprintln!("digup-shell: can't renew opening at login: {error}");
        }
    }
    Ok(())
}

/// After setup or a change of folders: the search service, the watcher and indexing follow the new folders.
fn apply_folders(app: &AppHandle) {
    let shell = app.state::<Arc<Shell>>().inner().clone();
    let folders = shell.folders();
    for folder in &folders {
        let _ = app.asset_protocol_scope().allow_directory(folder, true);
    }
    let request = folders_request(&shell);
    let search = shell.clone();
    tauri::async_runtime::spawn(async move {
        let _ = search.search.ask(request).await;
    });
    watch_folders(app);
}

/// The search service's "folders": what it searches (without code folders, it closes the code index).
fn folders_request(shell: &Shell) -> Value {
    let settings = shell.settings.lock().unwrap().clone();
    json!({"op": "folders", "roots": shell.folders(), "skipped": settings.skipped, "types": settings.skip_types,
           "code_roots": shell.code_folders(), "code_skipped": settings.code_skipped})
}

/// Watches the folders and code search's, and indexes them now when the model is in.
fn watch_folders(app: &AppHandle) {
    let shell = app.state::<Arc<Shell>>().inner().clone();
    let folders: Vec<PathBuf> = shell.folders().iter().map(PathBuf::from).collect();
    let code_folders: Vec<PathBuf> = shell.code_folders().iter().map(PathBuf::from).collect();
    let (skipped, code_skipped) = {
        let settings = shell.settings.lock().unwrap();
        (settings.skipped.iter().map(PathBuf::from).collect(), settings.code_skipped.iter().map(PathBuf::from).collect())
    };
    changed(app);
    let index = shell.options.index_folder();
    *shell.watcher.lock().unwrap() = (!folders.is_empty()).then(|| {
        let app = app.clone();
        FolderWatcher::start(&folders, skipped, index.clone(), Duration::from_secs(2), Duration::MAX, move || run_index(&app))
    });
    *shell.code_watcher.lock().unwrap() = (!code_folders.is_empty()).then(|| {
        let app = app.clone();
        FolderWatcher::start(&code_folders, code_skipped, index, Duration::from_secs(60), Duration::from_secs(600),
                             move || sync_code(&app))
    });
    if !folders.is_empty() || !code_folders.is_empty() {
        run_index(app);
    }
}

/// Indexing may run: there's a model and a folder (from setup's folders step on), the speed check isn't running, and
/// indexing isn't paused or waiting for its hours.
fn may_index(shell: &Shell) -> bool {
    (!shell.folders().is_empty() || !shell.code_folders().is_empty()) && shell.model_ready()
        && !shell.measuring.load(Ordering::SeqCst) && !shell.quitting.load(Ordering::SeqCst) && {
            let status = shell.status.lock().unwrap();
            !status.paused && status.held_until.is_none()
        }
}

/// Has the index helper sync and index.
fn run_index(app: &AppHandle) {
    let shell = app.state::<Arc<Shell>>();
    if !may_index(&shell) {
        return;
    }
    if let Err(error) = shell.index.run(&shell.index_launch()) {
        set_status(app, &format!("Indexing couldn't start: {error}"));
    }
}

/// Code changed in code search's folders: the code index syncs.
fn sync_code(app: &AppHandle) {
    let shell = app.state::<Arc<Shell>>();
    if !may_index(&shell) {
        return;
    }
    if let Err(error) = shell.index.sync_code(&shell.index_launch()) {
        set_status(app, &format!("Indexing couldn't start: {error}"));
    }
}

/// Deletes the code index once code search is off (the helpers have let it go: the search service closes it when its
/// code folders go, an index helper without code folders never opens it). Tried for a while (Windows won't delete a
/// file still open), then at the next start.
fn delete_code_index(shell: &Arc<Shell>) {
    let shell = shell.clone();
    std::thread::spawn(move || {
        for _ in 0..30 {
            if !shell.code_folders().is_empty() {
                return;   // turned on again meanwhile
            }
            let files = shell.code_index_files();
            if files.iter().all(|file| std::fs::remove_file(file).is_ok() || !file.exists()) {
                let mut settings = shell.settings.lock().unwrap();
                if settings.delete_code_index {
                    settings.delete_code_index = false;
                    let _ = settings.save(&shell.settings_path);
                }
                return;
            }
            std::thread::sleep(Duration::from_secs(2));
        }
    });
}

fn stop_helpers(app: &AppHandle) {
    let shell = app.state::<Arc<Shell>>();
    shell.model.stop();
    shell.index.stop();
    shell.search.stop();
}

fn quit(app: &AppHandle) {
    if let Some(window) = app.get_webview_window(WINDOW) {
        remember_place(&window);
    }
    app.state::<Arc<Shell>>().quitting.store(true, Ordering::SeqCst);
    stop_helpers(app);
    app.exit(0);
}

// MARK: Windows

/// The panel's window, hidden: fitted to the panel, or filling the screen with the panel centered in it.
fn make_panel(app: &AppHandle, centered: bool) -> tauri::Result<()> {
    let (label, page) = if centered { (CENTERED_PANEL, "index.html?fills") } else { (PANEL, "index.html") };
    let panel = WebviewWindowBuilder::new(app, label, WebviewUrl::App(page.into()))
        .title("DigUp")
        .inner_size(PANEL_WIDTH, FIELD_HEIGHT)
        .decorations(false)
        .transparent(true)
        .shadow(true)
        // GTK 3 makes a window that can't be resized at least 200 px tall when its content has no height of its own (a
        // web view's), so the field alone wouldn't fit; resizable, it takes the size asked for. It has no edges to drag.
        .resizable(cfg!(target_os = "linux"))
        .maximizable(false)
        .minimizable(false)
        .always_on_top(true)
        .visible_on_all_workspaces(true)
        .skip_taskbar(true)
        .visible(false)
        .build()?;
    #[cfg(target_os = "linux")]
    if centered {
        wayland::track(&panel);
    }
    *app.state::<Arc<Shell>>().panel_label.lock().unwrap() = label;
    let app = app.clone();
    panel.on_window_event(move |event| {
        // Like Spotlight: it steps away when you click elsewhere.
        if let WindowEvent::Focused(false) = event {
            if !app.state::<Arc<Shell>>().options.debug_show {
                hide_panel(app.clone());
            }
        }
    });
    Ok(())
}

fn panel_window(app: &AppHandle) -> Option<tauri::WebviewWindow> {
    let label = *app.state::<Arc<Shell>>().panel_label.lock().unwrap();
    app.get_webview_window(label)
}

/// Settings turned centering on or off: the panel's window is made the other way (a window can't change between the
/// two), then the old one goes.
fn remake_panel(app: &AppHandle) {
    let shell = app.state::<Arc<Shell>>().inner().clone();
    let old = panel_window(app);
    if old.as_ref().is_some_and(|panel| (panel.label() == CENTERED_PANEL) == shell.centers_panel()) {
        return;
    }
    if let Err(error) = make_panel(app, shell.centers_panel()) {
        eprintln!("digup-shell: can't make the panel: {error}");
        return;
    }
    if let Some(old) = old {
        let _ = old.destroy();
    }
}

fn show_panel(app: &AppHandle) {
    if !app.state::<Arc<Shell>>().is_set_up() {
        later(app, |app| {
            let _ = show_setup(app);
        });
        return;
    }
    let Some(panel) = panel_window(app) else { return };
    // On the screen with the pointer, centered, a fifth of the way down: the page puts it there in a window that fills
    // the screen (GTK keeps the window maximized while it's hidden). Elsewhere on Wayland the desktop places it.
    if panel.label() == CENTERED_PANEL {
        let _ = panel.maximize();
    } else if let Ok(pointer) = app.cursor_position() {
        if let Ok(Some(screen)) = app.monitor_from_point(pointer.x, pointer.y) {
            let width = (PANEL_WIDTH * screen.scale_factor()) as i32;
            let x = screen.position().x + (screen.size().width as i32 - width) / 2;
            let y = screen.position().y + (screen.size().height as f64 * 0.2) as i32;
            let _ = panel.set_position(PhysicalPosition::new(x, y));
        }
    }
    let _ = panel.show();
    let _ = panel.set_focus();
    let _ = panel.emit("panel-shown", ());
    if cfg!(debug_assertions) {
        println!("panel: shown");
    }
}

fn toggle_panel(app: &AppHandle) {
    match panel_window(app) {
        Some(panel) if panel.is_visible().unwrap_or(false) => hide_panel(app.clone()),
        _ => show_panel(app),
    }
}

/// The window: searches bigger than the panel (kind filters, a grid of pictures, the preview beside it), the home
/// DigUp opens to by hand, and its menu (Choose Folders, Index Now, Settings, Quit) where a desktop has no tray. It's
/// made when it opens and gone when it closes, so a closed window costs nothing. A search the panel hands over is in
/// `window_search`: a new window takes it as it loads, an open one is told.
fn show_window(app: &AppHandle) -> tauri::Result<()> {
    let shell = app.state::<Arc<Shell>>().inner().clone();
    if let Some(window) = app.get_webview_window(WINDOW) {
        if let Some((query, kind)) = shell.window_search.lock().unwrap().take() {
            let _ = window.emit("window-search", json!({"query": query, "kind": kind}));
        }
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
        return Ok(());
    }
    // Debug runs look at it hidden: a window on screen takes the keyboard.
    let hidden = shell.options.debug_window.is_some() && !shell.options.debug_show;
    let mut builder = WebviewWindowBuilder::new(app, WINDOW, WebviewUrl::App("window.html".into()))
        .title("DigUp")
        .min_inner_size(820.0, 520.0)
        .visible(false);
    // Where it was left, at the size it had, while that's still on a screen; else sized to this screen, centered.
    let place = shell.settings.lock().unwrap().window.clone().filter(|place| place.width >= 820.0 && place.height >= 520.0);
    let position = place.as_ref().and_then(|place| place.x.zip(place.y)).filter(|&(x, y)| {
        app.monitor_from_point(f64::from(x) + 40.0, f64::from(y) + 20.0).ok().flatten().is_some()
    });
    match &place {
        Some(place) => builder = builder.inner_size(place.width, place.height).maximized(place.maximized),
        None => {
            let (width, height) = window_size(app);
            builder = builder.inner_size(width, height);
        }
    }
    if position.is_none() {
        builder = builder.center();
    }
    let window = builder.build()?;
    if let Some((x, y)) = position {
        let _ = window.set_position(PhysicalPosition::new(x, y));
    }
    if !hidden {
        let _ = window.show();
        let _ = window.set_focus();
    }
    let closing = window.clone();
    window.on_window_event(move |event| {
        if let WindowEvent::CloseRequested { .. } = event {
            remember_place(&closing);
        }
    });
    Ok(())
}

/// Keeps the window's place as it closes (and as DigUp quits with it open), for the next time; not a hidden debug
/// run's.
fn remember_place(window: &tauri::WebviewWindow) {
    let shell = window.state::<Arc<Shell>>();
    if !window.is_visible().unwrap_or(false) {
        return;
    }
    let maximized = window.is_maximized().unwrap_or(false);
    let mut settings = shell.settings.lock().unwrap();
    let mut place = settings.window.clone().unwrap_or_default();
    place.maximized = maximized;
    // A maximized window keeps the size and place it comes back to.
    if !maximized {
        let reported = *shell.window_inner.lock().unwrap();
        let measured = || window.inner_size().ok().zip(window.scale_factor().ok())
            .map(|(size, scale)| size.to_logical::<f64>(scale)).map(|size| (size.width, size.height));
        if let Some((width, height)) = reported.or_else(measured) {
            (place.width, place.height) = (width, height);
        }
        if !shell.wayland {
            if let Ok(position) = window.outer_position() {
                (place.x, place.y) = (Some(position.x), Some(position.y));
            }
        }
    }
    settings.window = Some(place);
    let _ = settings.save(&shell.settings_path);
}

/// The window's size: 1040 × 700, or less on a small screen (a laptop's 1366 × 768 at 125% has 1093 × 614 to show
/// it in), but never under its least, 820 × 520.
fn window_size(app: &AppHandle) -> (f64, f64) {
    let screen = app.cursor_position().ok().and_then(|pointer| app.monitor_from_point(pointer.x, pointer.y).ok().flatten())
        .or_else(|| app.primary_monitor().ok().flatten());
    let Some(screen) = screen else { return (1040.0, 700.0) };
    let area = screen.work_area().size.to_logical::<f64>(screen.scale_factor());
    ((area.width * 0.9).clamp(820.0, 1040.0), (area.height * 0.9).clamp(520.0, 700.0))
}

/// Code search's folders: setup's folder list for code, with Save.
fn show_code_folders(app: &AppHandle) -> tauri::Result<()> {
    if let Some(window) = app.get_webview_window("code-folders") {
        let _ = window.show();
        let _ = window.set_focus();
        return Ok(());
    }
    WebviewWindowBuilder::new(app, "code-folders", WebviewUrl::App("setup.html?code".into()))
        .title("Code Folders")
        .inner_size(720.0, 600.0)
        .resizable(false)
        .maximizable(false)
        .center()
        .build()?;
    Ok(())
}

/// The setup window (first launch, and Choose Folders… later). Debug runs that click through it keep it hidden.
fn show_setup(app: &AppHandle) -> tauri::Result<()> {
    if let Some(window) = app.get_webview_window("setup") {
        let _ = window.show();
        let _ = window.set_focus();
        return Ok(());
    }
    let hidden = app.state::<Arc<Shell>>().options.debug_setup;
    WebviewWindowBuilder::new(app, "setup", WebviewUrl::App("setup.html".into()))
        .title("Set Up DigUp")
        .inner_size(720.0, 600.0)
        .resizable(false)
        .maximizable(false)
        .center()
        .visible(!hidden)
        .build()?;
    Ok(())
}

/// Settings: opening at login, centering the panel (where the desktop places windows), and where the shortcut is.
fn show_settings(app: &AppHandle) -> tauri::Result<()> {
    if let Some(window) = app.get_webview_window("settings") {
        let _ = window.show();
        let _ = window.set_focus();
        return Ok(());
    }
    let options = &app.state::<Arc<Shell>>().options;
    WebviewWindowBuilder::new(app, "settings", WebviewUrl::App("settings.html".into()))
        .title("DigUp Settings")
        .inner_size(660.0, 620.0)
        .resizable(false)
        .maximizable(false)
        .center()
        .visible(!options.debug_settings || options.debug_show)
        .build()?;
    Ok(())
}

/// What the Settings window shows.
#[tauri::command]
fn settings_info(app: AppHandle, shell: State<'_, Arc<Shell>>) -> Value {
    let settings = shell.settings.lock().unwrap().clone();
    json!({
        "openAtLogin": shell.opens_at_login() && app.autolaunch().is_enabled().unwrap_or(false),
        "canOpenAtLogin": shell.opens_at_login(),
        "centered": shell.settings.lock().unwrap().center_panel,
        // Windows' tray reports clicks (Linux's open the menu, a Mac's too).
        "canChooseTrayClick": cfg!(windows),
        "trayClick": if settings.tray_click == "panel" { "panel" } else { "window" },
        "canCenter": shell.wayland,
        "hotkey": shell.hotkey_text(),
        "shortcut": {"method": shell.shortcut.name(), "command": hotkey::toggle_command()},
        "folders": shell.folders(),
        "skipped": settings.skipped,
        "skipTypes": settings.skip_types,
        "indexHours": {"on": settings.index_hours_on, "start": settings.index_hours.start, "end": settings.index_hours.end},
        "storage": storage(&shell),
        "code": {
            "folders": shell.code_folders(),
            "skipped": settings.code_skipped,
            "editor": if settings.code_editor == "default" { "default" } else {
                editors::chosen(&settings.code_editor).map(|(editor, _)| editor.id).unwrap_or("default")
            },
            "editors": editors::installed().iter().map(|(editor, _)| json!({"id": editor.id, "name": editor.name}))
                .collect::<Vec<_>>(),
        },
        "state": shell.snapshot(),
        "updateChecks": !settings.update_checks_off,
        "installsUpdates": updates::installs_itself(),
        "version": app.package_info().version.to_string(),
        "licenses": licenses_file(&app).is_some(),
        "debug": shell.options.debug_settings,
    })
}

/// Where the model and the index are, and how big the index is on disk (its database and write-ahead log).
fn storage(shell: &Shell) -> Value {
    let index = shell.options.index_folder();
    let size = |name: &str| -> u64 {
        let Some(index) = &index else { return 0 };
        ["", "-wal", "-shm"].iter().filter_map(|end| std::fs::metadata(index.join(format!("{name}{end}"))).ok()).map(|file| file.len()).sum()
    };
    let models = shell.options.models.clone().or_else(|| {
        if cfg!(windows) {
            std::env::var_os("LOCALAPPDATA").map(|local| PathBuf::from(local).join("DigUp").join("Models"))
        } else {
            let data = std::env::var_os("XDG_DATA_HOME").filter(|value| !value.is_empty()).map(PathBuf::from)
                .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/share")));
            data.map(|data| data.join("digup").join("Models"))
        }
    });
    json!({
        "index": index.as_ref().map(|folder| folder.display().to_string()),
        "indexBytes": size("index.sqlite"),
        "codeBytes": size("code.sqlite"),
        "models": models.map(|folder| folder.display().to_string()),
    })
}

/// Settings → General, recording a new shortcut: the current one is let go meanwhile (`held`), so that pressing it
/// reaches the page instead of opening the panel, and taken again after.
#[tauri::command]
fn hold_hotkey(app: AppHandle, shell: State<'_, Arc<Shell>>, held: bool) {
    if shell.shortcut != Method::Grab {
        return;
    }
    let hotkey = shell.hotkey();
    let shortcuts = app.global_shortcut();
    if held {
        let _ = shortcuts.unregister(hotkey.as_str());
    } else if !shortcuts.is_registered(hotkey.as_str()) {
        let _ = shortcuts.register(hotkey.as_str());
    }
}

/// Settings → General: a new shortcut for the panel, where DigUp grabs it itself (Windows, X11; GNOME and KDE keep it in
/// their own settings). The new one is registered before the old one goes, so one another app holds is refused and the
/// old one stays. Returns the shortcut as it's shown.
#[tauri::command]
fn set_hotkey(app: AppHandle, shell: State<'_, Arc<Shell>>, hotkey: String) -> Result<String, String> {
    if shell.shortcut != Method::Grab {
        return Err("This desktop keeps the shortcut in its own settings.".into());
    }
    let old = shell.hotkey();
    if hotkey != old {
        let shortcuts = app.global_shortcut();
        shortcuts.register(hotkey.as_str())
            .map_err(|_| format!("{} can't be used: another app may have it.", shortcut_text(&hotkey)))?;
        if shortcuts.is_registered(old.as_str()) {
            let _ = shortcuts.unregister(old.as_str());
        }
        let mut settings = shell.settings.lock().unwrap();
        settings.hotkey = hotkey;
        settings.save(&shell.settings_path).map_err(|error| format!("can't save the settings: {error}"))?;
    }
    Ok(shell.hotkey_text())
}

/// Settings → Folders: stops searching a folder (and what's skipped inside it); its files leave the index.
#[tauri::command]
fn remove_folder(app: AppHandle, shell: State<'_, Arc<Shell>>, folder: String) -> Result<(), String> {
    {
        let mut settings = shell.settings.lock().unwrap();
        let inside = |path: &str| Path::new(path).starts_with(&folder);
        settings.folders.retain(|path| path != &folder);
        settings.skipped.retain(|path| !inside(path));
        settings.save(&shell.settings_path).map_err(|error| format!("can't save the settings: {error}"))?;
    }
    shell.prune.store(true, Ordering::SeqCst);
    apply_folders(&app);
    Ok(())
}

/// The folders with code offered for code search: the home folder's (`code.rs`), or `--offer-code`'s; none in a dev run
/// without it, which never offers real folders.
fn offered_code(app: &AppHandle, shell: &Shell) -> Vec<String> {
    let folders = match (&shell.options.offered_code, shell.dev_run()) {
        (Some(folders), _) => folders.clone(),
        (None, true) => Vec::new(),
        (None, false) => app.path().home_dir().map(|home| code::candidates(&home)).unwrap_or_default(),
    };
    folders.iter().map(|folder| folder.display().to_string()).collect()
}

/// The code folders window (setup's folder list for code): the folders with code it offers, those chosen, and the
/// folders skipped in them.
#[tauri::command]
async fn code_setup_info(app: AppHandle, shell: State<'_, Arc<Shell>>) -> Result<Value, String> {
    let shell = shell.inner().clone();
    let offered = {
        let (app, shell) = (app.clone(), shell.clone());
        tauri::async_runtime::spawn_blocking(move || offered_code(&app, &shell)).await.map_err(|error| error.to_string())?
    };
    Ok(json!({
        "code": true,
        "setUp": true,
        "offered": offered,
        "chosen": shell.code_folders(),
        "skipped": shell.settings.lock().unwrap().code_skipped.clone(),
    }))
}

/// The code folders window's Save: the folders whose code is searched (code search starts with the first; none turns
/// it off), and the folders skipped in them.
#[tauri::command]
fn set_code_folders(app: AppHandle, shell: State<'_, Arc<Shell>>, folders: Vec<String>, skipped: Vec<String>)
    -> Result<(), String> {
    if folders.is_empty() {
        return turn_off_code(app, shell);
    }
    {
        let mut settings = shell.settings.lock().unwrap();
        if settings.code_folders.iter().any(|folder| !folders.contains(folder)) {
            shell.prune.store(true, Ordering::SeqCst);
        }
        settings.code_folders = folders;
        settings.code_skipped = skipped;
        settings.delete_code_index = false;
        settings.save(&shell.settings_path).map_err(|error| format!("can't save the settings: {error}"))?;
    }
    apply_folders(&app);
    Ok(())
}

#[tauri::command]
fn choose_code_folders(app: AppHandle) {
    later(&app, |app| {
        let _ = show_code_folders(app);
    });
}

/// Settings → Code: stops searching the code in a folder (its files leave the code index).
#[tauri::command]
fn remove_code_folder(app: AppHandle, shell: State<'_, Arc<Shell>>, folder: String) -> Result<(), String> {
    let off = {
        let mut settings = shell.settings.lock().unwrap();
        let inside = |path: &str| Path::new(path).starts_with(&folder);
        settings.code_folders.retain(|path| path != &folder);
        settings.code_skipped.retain(|path| !inside(path));
        settings.save(&shell.settings_path).map_err(|error| format!("can't save the settings: {error}"))?;
        settings.code_folders.is_empty()
    };
    if off {
        return turn_off_code(app, shell);
    }
    shell.prune.store(true, Ordering::SeqCst);
    apply_folders(&app);
    Ok(())
}

/// Settings → Code → Turn Off Code Search: no code folders, and the code index is deleted once the helpers let it go
/// (the search service closes it on hearing there are none; the index helper starts again without it).
#[tauri::command]
fn turn_off_code(app: AppHandle, shell: State<'_, Arc<Shell>>) -> Result<(), String> {
    {
        let mut settings = shell.settings.lock().unwrap();
        settings.code_folders.clear();
        settings.code_skipped.clear();
        settings.delete_code_index = true;
        settings.save(&shell.settings_path).map_err(|error| format!("can't save the settings: {error}"))?;
    }
    let shell = shell.inner().clone();
    let request = folders_request(&shell);
    tauri::async_runtime::spawn(async move {
        let _ = shell.search.ask(request).await;
        // Stopped rather than asked to sync: one still reading code holds the code index until it's done.
        shell.index.stop();
        watch_folders(&app);
        delete_code_index(&shell);
    });
    Ok(())
}

/// Settings → General: what a click on the tray icon does ("window" or "panel").
#[tauri::command]
fn set_tray_click(shell: State<'_, Arc<Shell>>, click: String) -> Result<(), String> {
    let mut settings = shell.settings.lock().unwrap();
    settings.tray_click = if click == "panel" { click } else { String::new() };
    settings.save(&shell.settings_path).map_err(|error| format!("can't save the settings: {error}"))
}

/// Check for Updates… (the tray, the window's ⋯, Settings): the answer is shown, and an update found is offered.
#[tauri::command]
async fn check_for_updates(app: AppHandle) {
    updates::check(&app, true).await;
}

/// "Update to DigUp X…" (the tray, the window's status bar and ⋯): what's new, then Install and Restart.
#[tauri::command]
fn offer_update(app: AppHandle) {
    updates::offer(&app);
}

/// Settings → General: "Check for updates automatically".
#[tauri::command]
fn set_update_checks(shell: State<'_, Arc<Shell>>, on: bool) -> Result<(), String> {
    let mut settings = shell.settings.lock().unwrap();
    settings.update_checks_off = !on;
    settings.save(&shell.settings_path).map_err(|error| format!("can't save the settings: {error}"))
}

/// Settings → Code: the editor code results open in (an editor's id, or "default" for the file's default app).
#[tauri::command]
fn set_code_editor(shell: State<'_, Arc<Shell>>, editor: String) -> Result<(), String> {
    let mut settings = shell.settings.lock().unwrap();
    settings.code_editor = editor;
    settings.save(&shell.settings_path).map_err(|error| format!("can't save the settings: {error}"))
}

/// Settings → Folders: the folders skipped inside the ones searched.
#[tauri::command]
fn set_skipped(app: AppHandle, shell: State<'_, Arc<Shell>>, skipped: Vec<String>) -> Result<(), String> {
    {
        let mut settings = shell.settings.lock().unwrap();
        settings.skipped = skipped;
        settings.save(&shell.settings_path).map_err(|error| format!("can't save the settings: {error}"))?;
    }
    apply_folders(&app);
    Ok(())
}

/// Settings → Folders: file types to leave out, as typed ("heic, .txt").
#[tauri::command]
fn set_skip_types(app: AppHandle, shell: State<'_, Arc<Shell>>, types: String) -> Result<Vec<String>, String> {
    let mut list: Vec<String> = types
        .split(|c: char| c == ',' || c.is_whitespace())
        .map(|kind| kind.trim().trim_start_matches('.').to_lowercase())
        .filter(|kind| !kind.is_empty())
        .collect();
    list.dedup();
    {
        let mut settings = shell.settings.lock().unwrap();
        if settings.skip_types == list {
            return Ok(list);
        }
        settings.skip_types = list.clone();
        settings.save(&shell.settings_path).map_err(|error| format!("can't save the settings: {error}"))?;
    }
    apply_folders(&app);
    Ok(list)
}

/// Settings → Folders: "Index only at set hours".
#[tauri::command]
fn set_index_hours(app: AppHandle, shell: State<'_, Arc<Shell>>, on: bool, start: u32, end: u32) -> Result<(), String> {
    {
        let mut settings = shell.settings.lock().unwrap();
        settings.index_hours_on = on;
        settings.index_hours = hours::Hours { start: start % 1440, end: end % 1440 };
        settings.save(&shell.settings_path).map_err(|error| format!("can't save the settings: {error}"))?;
    }
    held_now(&app);
    Ok(())
}

#[tauri::command]
fn set_open_at_login(app: AppHandle, shell: State<'_, Arc<Shell>>, on: bool) -> Result<(), String> {
    if !shell.opens_at_login() {
        return Err("not in a dev run".into());
    }
    let autolaunch = app.autolaunch();
    (if on { autolaunch.enable() } else { autolaunch.disable() }).map_err(|error| error.to_string())
}

#[tauri::command]
fn set_center_panel(app: AppHandle, shell: State<'_, Arc<Shell>>, on: bool) -> Result<(), String> {
    {
        let mut settings = shell.settings.lock().unwrap();
        settings.center_panel = on;
        settings.save(&shell.settings_path).map_err(|error| format!("can't save the settings: {error}"))?;
    }
    later(&app, remake_panel);
    Ok(())
}

/// "CommandOrControl+Shift+Space" as people read it here: "Ctrl+Shift+Space", or "⇧⌘Space" on a Mac.
fn shortcut_text(accelerator: &str) -> String {
    let parts: Vec<&str> = accelerator.split('+').collect();
    if cfg!(target_os = "macos") {
        let mut text = String::new();
        for (name, sign) in [("Ctrl", "⌃"), ("Control", "⌃"), ("Alt", "⌥"), ("Option", "⌥"), ("Shift", "⇧"),
                             ("CommandOrControl", "⌘"), ("CmdOrCtrl", "⌘"), ("Cmd", "⌘"), ("Command", "⌘"),
                             ("Super", "⌘")] {
            if parts.iter().any(|part| part.eq_ignore_ascii_case(name)) && !text.contains(sign) {
                text.push_str(sign);
            }
        }
        return text + parts.last().copied().unwrap_or_default();
    }
    parts
        .iter()
        .map(|part| match *part {
            "CommandOrControl" | "CmdOrCtrl" | "Control" => "Ctrl",
            "Super" if cfg!(windows) => "Win",
            other => other,
        })
        .collect::<Vec<_>>()
        .join("+")
}

// MARK: The tray

fn make_tray(app: &AppHandle, shell: &Arc<Shell>) -> tauri::Result<()> {
    let status = MenuItem::with_id(app, "status", "Starting…", false, None::<&str>)?;
    // The shortcut beside Search… only where DigUp grabs it: elsewhere the desktop has it, maybe changed there.
    let accelerator = (shell.shortcut == Method::Grab).then(|| shell.hotkey());
    let search = MenuItem::with_id(app, "search", "Search…", true, accelerator.as_deref())?;
    let open = MenuItem::with_id(app, "open", "Open DigUp", true, None::<&str>)?;
    let folders = MenuItem::with_id(app, "folders", "Choose Folders…", true, None::<&str>)?;
    let index = MenuItem::with_id(app, "index", "Index Now", true, None::<&str>)?;
    let pause = MenuItem::with_id(app, "pause", "Pause Indexing", true, None::<&str>)?;
    let settings = MenuItem::with_id(app, "settings", "Settings…", true, None::<&str>)?;
    let check = MenuItem::with_id(app, "check", "Check for Updates…", true, None::<&str>)?;
    let quit_item = MenuItem::with_id(app, "quit", "Quit DigUp", true, None::<&str>)?;
    let separator = PredefinedMenuItem::separator(app)?;
    let menu = Menu::with_items(
        app,
        &[&status, &separator, &search, &open, &folders, &index, &pause, &settings, &check,
          &PredefinedMenuItem::separator(app)?, &quit_item],
    )?;
    // DigUp's logo, in its colors (tray_icon.rs).
    let look = tray_icon::Look::new(None, false);
    *shell.tray_look.lock().unwrap() = Some(look);
    TrayIconBuilder::with_id("digup")
        .icon(tray_icon::image(look))
        .tooltip("DigUp")
        .menu(&menu)
        .show_menu_on_left_click(cfg!(target_os = "macos"))
        .on_menu_event(|app, event| match event.id().as_ref() {
            "search" => show_panel(app),
            "open" => show_window_or_setup(app),
            "folders" => later(app, |app| {
                let _ = show_setup(app);
            }),
            "index" => run_index(app),
            "pause" => {
                let paused = app.state::<Arc<Shell>>().status.lock().unwrap().paused;
                set_paused(app, !paused);
            }
            "settings" => later(app, |app| {
                let _ = show_settings(app);
            }),
            "update" => updates::offer(app),
            "check" => {
                let app = app.clone();
                tauri::async_runtime::spawn(async move { updates::check(&app, true).await });
            }
            "quit" => quit(app),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            // Windows (and trays on Linux that report clicks): a click opens DigUp's window, as a click on an app's
            // tray icon does there, or shows the search panel if the person chose that (Settings → General); the menu
            // is on the other button.
            if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = event {
                if !cfg!(target_os = "macos") {
                    let app = tray.app_handle();
                    if app.state::<Arc<Shell>>().settings.lock().unwrap().tray_click == "panel" {
                        toggle_panel(app);
                    } else {
                        show_window_or_setup(app);
                    }
                }
            }
        })
        .build(app)?;
    *shell.status_item.lock().unwrap() = Some(status);
    *shell.index_item.lock().unwrap() = Some(index);
    *shell.pause_item.lock().unwrap() = Some(pause);
    *shell.tray_menu.lock().unwrap() = Some(menu);
    Ok(())
}

/// "Index only at set hours": every half minute, whether indexing may run now. Leaving the hours stops the index helper
/// (what it was reading is read again later); entering them starts one.
fn watch_hours(app: &AppHandle) {
    let app = app.clone();
    std::thread::spawn(move || loop {
        held_now(&app);
        std::thread::sleep(Duration::from_secs(30));
    });
}

/// Brings the hold up to date with the clock and the setting.
fn held_now(app: &AppHandle) {
    let shell = app.state::<Arc<Shell>>().inner().clone();
    let held = {
        let settings = shell.settings.lock().unwrap();
        (settings.index_hours_on && !settings.index_hours.contains(hours::now())).then(|| hours::clock(settings.index_hours.start))
    };
    let before = std::mem::replace(&mut shell.status.lock().unwrap().held_until, held.clone());
    if before == held {
        return;
    }
    if held.is_some() {
        let stopping = shell.clone();
        std::thread::spawn(move || stopping.index.stop());
    }
    changed(app);
    if held.is_none() {
        run_index(app);
    }
}

/// Pause Indexing stops the index helper (what it was reading is read again later) and starts none until Resume; search
/// goes on. As on the Mac, a new launch isn't paused.
fn set_paused(app: &AppHandle, paused: bool) {
    let shell = app.state::<Arc<Shell>>().inner().clone();
    shell.status.lock().unwrap().paused = paused;
    if paused {
        // It may take a moment to leave (up to two seconds): not on the main thread.
        let stopping = shell.clone();
        std::thread::spawn(move || stopping.index.stop());
    }
    changed(app);
    if !paused {
        run_index(app);
    }
}

/// A problem to see in the tray's first line (the shortcut is taken…), until indexing next has news.
fn set_status(app: &AppHandle, text: &str) {
    if let Some(status) = app.state::<Arc<Shell>>().status_item.lock().unwrap().as_ref() {
        let _ = status.set_text(text);
    }
}

/// Indexing or the model moved on: the tray's first line and items, and every page, follow (status.rs has the words).
fn changed(app: &AppHandle) {
    let shell = app.state::<Arc<Shell>>().inner().clone();
    let snapshot = shell.snapshot();
    let folders = !shell.folders().is_empty();
    if let Some(status) = shell.status_item.lock().unwrap().as_ref() {
        let _ = status.set_text(snapshot["line"].as_str().unwrap_or_default());
    }
    if let Some(index) = shell.index_item.lock().unwrap().as_ref() {
        let _ = index.set_enabled(folders && snapshot["busy"] == false);
    }
    if let Some(pause) = shell.pause_item.lock().unwrap().as_ref() {
        let _ = pause.set_text(if snapshot["paused"] == true { "Resume Indexing" } else { "Pause Indexing" });
        let _ = pause.set_enabled(folders);
    }
    update_line(app, &shell);
    // The ring when it moves a step, the bars when paused, a dot while an update waits.
    let look = tray_icon::Look::new(snapshot["progress"].as_f64(), snapshot["paused"] == true)
        .with_update(!snapshot["update"].is_null());
    let mut shown = shell.tray_look.lock().unwrap();
    if shown.is_some() && *shown != Some(look) {
        if let Some(tray) = app.tray_by_id("digup") {
            if tray.set_icon(Some(tray_icon::image(look))).is_ok() {
                *shown = Some(look);
            }
        }
    }
    drop(shown);
    let _ = app.emit("state", snapshot);
}

/// The waiting update's line in the tray menu, under the status line: added when one is found, its words following the
/// download, gone when there's none.
fn update_line(app: &AppHandle, shell: &Shell) {
    let menu = shell.tray_menu.lock().unwrap();
    let Some(menu) = menu.as_ref() else { return };
    let mut shown = shell.update_item.lock().unwrap();
    match (shell.updates.menu_text(), shown.as_ref()) {
        (Some((text, enabled)), Some((item, _))) => {
            let _ = item.set_text(text);
            let _ = item.set_enabled(enabled);
        }
        (Some((text, enabled)), None) => {
            let made = MenuItem::with_id(app, "update", text, enabled, None::<&str>)
                .and_then(|item| Ok((item, PredefinedMenuItem::separator(app)?)));
            if let Ok((item, line)) = made {
                if menu.insert(&item, 2).is_ok() && menu.insert(&line, 3).is_ok() {
                    *shown = Some((item, line));
                }
            }
        }
        (None, Some((item, line))) => {
            let _ = menu.remove(item);
            let _ = menu.remove(line);
            *shown = None;
        }
        (None, None) => {}
    }
}

// MARK: The helpers' events

fn search_event(app: &AppHandle, event: Value) {
    if cfg!(debug_assertions) {
        println!("search: {event}");
    }
    if event["event"] == "ready" {
        if let Some(index) = event["index"].as_str() {
            let _ = app.asset_protocol_scope().allow_directory(Path::new(index).join("previews"), false);
        }
    }
    let _ = app.emit("helper", json!({"from": "search", "event": event}));
}

fn index_event(app: &AppHandle, event: Value) {
    if cfg!(debug_assertions) {
        println!("index: {event}");
    }
    app.state::<Arc<Shell>>().status.lock().unwrap().apply(&event);
    match event["event"].as_str().unwrap_or_default() {
        "file" | "rest" => reload(app, false),
        "idle" => {
            reload(app, true);
            // A debug run through setup searches once the first index is in.
            let shell = app.state::<Arc<Shell>>();
            if let Some(query) = &shell.options.debug_query {
                if shell.options.debug_setup && !shell.debug_query_sent.swap(true, Ordering::SeqCst) {
                    let label = *shell.panel_label.lock().unwrap();
                    let _ = app.emit_to(label, "debug-query", query.clone());
                }
            }
        }
        "exit" => reload(app, true),
        "ended" => index_ended(app, &event),
        _ => {}
    }
    changed(app);
    let _ = app.emit("helper", json!({"from": "index", "event": event}));
}

/// The index helper ended by itself (helper.rs's "ended"). A sync asked of it as it was leaving (it exits a minute after
/// it's done) still has to happen; its watchdog's exit (75: a file whose reading ran away, which the next helper skips)
/// starts another, though not over and over if something else is wrong (as the Mac app's `Engine.helperExited`).
fn index_ended(app: &AppHandle, event: &Value) {
    const STOPPED_ON_FILE: i64 = 75;
    let shell = app.state::<Arc<Shell>>().inner().clone();
    let again = if event["status"].as_i64() == Some(STOPPED_ON_FILE) {
        let mut stops = shell.watchdog_stops.lock().unwrap();
        stops.retain(|stop| stop.elapsed() < Duration::from_secs(600));
        stops.push(Instant::now());
        if stops.len() > 3 {
            eprintln!("digup-shell: indexing stopped on files 4 times in 10 min");
        }
        stops.len() <= 3
    } else {
        event["owed"] == true && event["status"].as_i64() == Some(0)
    };
    if again {
        run_index(app);
    }
}

fn model_event(app: &AppHandle, event: Value) {
    if cfg!(debug_assertions) && event["event"] != "progress" {
        println!("model: {event}");
    }
    let shell = app.state::<Arc<Shell>>().inner().clone();
    let before = shell.model_state.lock().unwrap().clone();
    let state = match event["event"].as_str().unwrap_or_default() {
        "progress" => {
            let (bytes, total) = (event["all_bytes"].as_f64().unwrap_or(0.0), event["all_total"].as_f64().unwrap_or(1.0));
            json!({"state": "downloading", "bytes": bytes, "total": total})
        }
        "file" => json!({"state": "downloading", "from": event["from"]}),
        "verifying" => json!({"state": "checking"}),
        "waiting" => json!({"state": "waiting"}),
        // Where it got to stays shown while it waits to try again.
        "retry" => json!({"state": "downloading", "bytes": before["bytes"], "total": before["total"], "problem": event["message"]}),
        "done" => json!({"state": "ready"}),
        "error" => json!({"state": "failed", "message": event["message"]}),
        _ => return,
    };
    let ready = state["state"] == "ready";
    *shell.model_state.lock().unwrap() = state.clone();
    let _ = app.emit("model", state);
    changed(app);
    if ready {
        measure_then_index(app);
    }
}

/// Once the model is in: this computer's speed with the model (`digup speed --model --if-needed`: once, kept beside
/// the index; estimates on Linux and Windows go by it until indexing has measured enough itself), then indexing.
fn measure_then_index(app: &AppHandle) {
    let shell = app.state::<Arc<Shell>>().inner().clone();
    // A Mac times itself without the model (Metal, and Vision for the OCR that indexing runs there).
    if cfg!(target_os = "macos") {
        return run_index(app);
    }
    if shell.measuring.swap(true, Ordering::SeqCst) {
        return;
    }
    shell.status.lock().unwrap().measuring = true;
    changed(app);
    let app = app.clone();
    std::thread::spawn(move || {
        // Setup's folder estimates (walking folders, reading PDFs and media) would slow the check, and DigUp would then
        // take this computer for slower than it is: they go first (two minutes at most).
        let waiting = Instant::now();
        while shell.estimating.load(Ordering::SeqCst) > 0 && waiting.elapsed() < Duration::from_secs(120) {
            std::thread::sleep(Duration::from_millis(250));
        }
        // The check itself waits (a minute at most) for other programs to settle: just after the model's download a
        // virus scanner reads the new files, and at a login everything starts at once.
        let mut command = std::process::Command::new(&shell.options.helper);
        command.args(["speed", "--model", "--if-needed", "--when-quiet", "60", "--json"]).args(shell.index_arguments());
        if let Some(models) = &shell.options.models {
            command.env("DIGUP_MODELS", models);
        }
        // Its reply goes to speed.log after what it said on the way (the model's own lines go to the index's worker.log).
        let log = std::fs::OpenOptions::new().create(true).append(true).open(shell.logs.join("speed.log")).ok();
        if let Some(log) = log.as_ref().and_then(|log| log.try_clone().ok()) {
            command.stderr(log);
        }
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
        }
        let started = hours::clock(hours::now());
        command.stdout(std::process::Stdio::piped());
        let output = command.spawn().and_then(|child| {
            helper::adopt(&child);
            child.wait_with_output()
        });
        let reply = match output {
            Ok(output) => String::from_utf8_lossy(&output.stdout).lines().filter_map(|line| serde_json::from_str(line).ok())
                .last().unwrap_or_else(|| json!({"event": "speed", "error": format!("exit {}", output.status)})),
            Err(error) => json!({"event": "speed", "error": error.to_string()}),
        };
        if let Some(mut log) = log {
            use std::io::Write;
            let _ = writeln!(log, "speed check from {started}: {reply}");
        }
        if cfg!(debug_assertions) {
            println!("speed: {reply}");
        }
        shell.measuring.store(false, Ordering::SeqCst);
        shell.status.lock().unwrap().measuring = false;
        let _ = app.emit("speed", reply);
        changed(&app);
        run_index(&app);
    });
}

/// Has the search service read the index again: at once when indexing settles, else at most every three seconds.
fn reload(app: &AppHandle, now: bool) {
    let shell = app.state::<Arc<Shell>>().inner().clone();
    if shell.quitting.load(Ordering::SeqCst) {
        return;
    }
    {
        let mut reloaded = shell.reloaded.lock().unwrap();
        if !now && reloaded.elapsed() < Duration::from_secs(3) {
            return;
        }
        *reloaded = Instant::now();
    }
    tauri::async_runtime::spawn(async move {
        let reply = shell.search.ask(json!({"op": "reload"})).await;
        if cfg!(debug_assertions) {
            println!("search: reload {reply:?}");
        }
    });
}
