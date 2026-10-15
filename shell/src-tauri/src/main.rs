// DigUp's shell for Windows and Linux (tried out on the Mac first): the tray icon, the hotkey, the search panel and the
// setup window. The work is DigUp's helper, `digup`, run as processes speaking JSON lines (helper.rs): `search-service`
// answers the panel, `index-service` keeps the index current, `download-model` fetches the model, `estimate` sizes up
// folders. The Mac app (Sources/DigUpApp) is the reference for behavior.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod helper;
mod options;
mod settings;
mod watcher;

use helper::{IndexService, Launch, ModelDownload, SearchService};
use options::{Options, DEFAULT_HOTKEY};
use serde_json::{json, Value};
use settings::Settings;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, LogicalSize, Manager, PhysicalPosition, State, WebviewUrl, WebviewWindowBuilder, WindowEvent, Wry};
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_global_shortcut::{GlobalShortcutExt, ShortcutState};
use tauri_plugin_opener::OpenerExt;
use watcher::FolderWatcher;

const PANEL_WIDTH: f64 = 780.0;
const FIELD_HEIGHT: f64 = 56.0;

/// What the commands and events share.
struct Shell {
    options: Options,
    settings: Mutex<Settings>,
    settings_path: PathBuf,
    search: SearchService,
    index: IndexService,
    model: ModelDownload,
    /// The model for the setup window and the tray: {"state": "checking|downloading|waiting|ready|failed", …}.
    model_state: Mutex<Value>,
    watcher: Mutex<Option<FolderWatcher>>,
    /// The tray menu's first line: what's going on.
    status: Mutex<Option<MenuItem<Wry>>>,
    /// When the search service last reloaded the index (while indexing, at most every few seconds).
    reloaded: Mutex<Instant>,
    /// Debug runs with setup: the panel's query waits until the first index is in.
    debug_query_sent: AtomicBool,
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

    fn is_set_up(&self) -> bool {
        !self.options.roots.is_empty() || self.settings.lock().unwrap().set_up
    }

    fn hotkey(&self) -> String {
        let chosen = self.settings.lock().unwrap().hotkey.clone();
        self.options.hotkey.clone().unwrap_or(if chosen.is_empty() { DEFAULT_HOTKEY.to_string() } else { chosen })
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
        args.extend(self.index_arguments());
        for folder in &settings.skipped {
            args.extend(["--exclude".to_string(), folder.clone()]);
        }
        for extension in &settings.skip_types {
            args.extend(["--exclude-ext".to_string(), extension.clone()]);
        }
        args.extend(self.folders());
        self.launch(args, "index.log")
    }

    fn model_ready(&self) -> bool {
        self.model_state.lock().unwrap()["state"] == "ready"
    }
}

// MARK: Commands

/// The panel's questions for `search-service`.
#[tauri::command]
async fn ask(shell: State<'_, Arc<Shell>>, request: Value) -> Result<Value, String> {
    let op = request.get("op").and_then(Value::as_str).unwrap_or_default();
    if !["search", "embed_ahead", "text", "render", "prewarm", "status"].contains(&op) {
        return Err(format!("not a question the panel asks: {op}"));
    }
    shell.search.ask(request).await
}

/// What indexing these folders would take, one answer per folder (`digup estimate --json`): files by kind, the first
/// pass's seconds, the rest of long files, subfolders. For setup.
#[tauri::command]
async fn estimate(shell: State<'_, Arc<Shell>>, folders: Vec<String>) -> Result<Vec<Value>, String> {
    let helper = shell.options.helper.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let mut command = std::process::Command::new(&helper);
        command.arg("estimate").args(&folders).arg("--json");
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
        }
        let output = command.output().map_err(|error| format!("can't run {}: {error}", helper.display()))?;
        Ok(String::from_utf8_lossy(&output.stdout).lines().filter_map(|line| serde_json::from_str(line).ok()).collect())
    })
    .await
    .map_err(|error| error.to_string())?
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
        "hotkey": shortcut_text(&shell.hotkey()),
        "model": shell.model_state.lock().unwrap().clone(),
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

/// Setup's last step: the folders are saved and indexing starts (once the model is in).
#[tauri::command]
fn finish_setup(app: AppHandle, shell: State<'_, Arc<Shell>>, folders: Vec<String>) -> Result<(), String> {
    {
        let mut settings = shell.settings.lock().unwrap();
        settings.folders = folders;
        settings.set_up = true;
        settings.save(&shell.settings_path).map_err(|error| format!("can't save the settings: {error}"))?;
    }
    apply_folders(&app);
    if let Some(window) = app.get_webview_window("setup") {
        let _ = window.close();
    }
    Ok(())
}

/// Opens a result in its default app.
#[tauri::command]
fn open_path(app: AppHandle, path: String) -> Result<(), String> {
    hide_panel(app.clone());
    app.opener().open_path(path, None::<&str>).map_err(|error| error.to_string())
}

/// Shows a result in the file manager, selected.
#[tauri::command]
fn reveal(app: AppHandle, path: String) -> Result<(), String> {
    hide_panel(app.clone());
    app.opener().reveal_item_in_dir(path).map_err(|error| error.to_string())
}

#[tauri::command]
fn hide_panel(app: AppHandle) {
    if let Some(panel) = app.get_webview_window("panel") {
        let _ = panel.hide();
    }
}

/// The panel grows to show results and shrinks back to its field.
#[tauri::command]
fn panel_height(app: AppHandle, height: f64) {
    if let Some(panel) = app.get_webview_window("panel") {
        let _ = panel.set_size(LogicalSize::new(PANEL_WIDTH, height.clamp(FIELD_HEIGHT, 640.0)));
    }
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

fn main() {
    let options = match Options::from_args() {
        Ok(options) => options,
        Err(error) => {
            eprintln!("digup-shell: {error}");
            std::process::exit(2);
        }
    };
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _, _| show_panel(app)))
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
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
            ask, estimate, setup_info, pick_folders, finish_setup, open_path, reveal, hide_panel, panel_height,
            debug_query, debug_report
        ])
        .build(tauri::generate_context!())
        .expect("DigUp couldn't start");
    app.run(|app, event| match event {
        tauri::RunEvent::Exit => stop_helpers(app),
        // Closing the setup window isn't quitting: DigUp lives in the tray.
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
    let mut search_args = vec!["search-service".to_string()];
    search_args.extend(options.index.iter().flat_map(|index| ["--index".to_string(), index.display().to_string()]));
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
        search,
        index,
        model,
        model_state: Mutex::new(json!({"state": "checking"})),
        watcher: Mutex::new(None),
        status: Mutex::new(None),
        reloaded: Mutex::new(Instant::now()),
        debug_query_sent: AtomicBool::new(false),
        logs,
    });
    app.manage(shell.clone());

    make_panel(&handle)?;
    // No tray (a session without a taskbar, a Linux desktop without one): the hotkey and the panel still work.
    if let Err(error) = make_tray(&handle, &shell) {
        eprintln!("digup-shell: no tray icon: {error}");
    }
    let hotkey = shell.hotkey();
    if let Err(error) = app.global_shortcut().register(hotkey.as_str()) {
        set_status(&handle, &format!("The shortcut {} is taken", shortcut_text(&hotkey)));
        eprintln!("digup-shell: can't use {hotkey} as the shortcut: {error}");
    }

    // The search service starts now (the first search is then quick); the model is checked (and fetched if it's
    // missing: on first launch that runs while setup is open, as on the Mac); indexing waits for both.
    let warm = shell.clone();
    tauri::async_runtime::spawn(async move {
        let _ = warm.search.ask(json!({"op": "status"})).await;
    });
    let mut download = vec!["download-model".to_string()];
    if let Some(models) = &shell.options.models {
        download.extend(["--to".to_string(), models.display().to_string()]);
    }
    if let Err(error) = shell.model.run(&shell.launch(download, "model.log")) {
        model_event(&handle, json!({"event": "error", "message": error}));
    }
    if shell.is_set_up() {
        watch_folders(&handle);
    } else {
        show_setup(&handle)?;
    }
    if shell.options.debug_show {
        show_panel(&handle);
    }
    Ok(())
}

/// After setup or a change of folders: the search service, the watcher and indexing follow the new folders.
fn apply_folders(app: &AppHandle) {
    let shell = app.state::<Arc<Shell>>().inner().clone();
    let folders = shell.folders();
    let (skipped, types) = {
        let settings = shell.settings.lock().unwrap();
        (settings.skipped.clone(), settings.skip_types.clone())
    };
    for folder in &folders {
        let _ = app.asset_protocol_scope().allow_directory(folder, true);
    }
    let search = shell.clone();
    tauri::async_runtime::spawn(async move {
        let _ = search.search.ask(json!({"op": "folders", "roots": folders, "skipped": skipped, "types": types})).await;
    });
    watch_folders(app);
}

/// Watches the folders, and indexes them now when the model is in.
fn watch_folders(app: &AppHandle) {
    let shell = app.state::<Arc<Shell>>().inner().clone();
    let folders: Vec<PathBuf> = shell.folders().iter().map(PathBuf::from).collect();
    if folders.is_empty() {
        set_status(app, "No folders chosen yet");
        return;
    }
    let changed = {
        let app = app.clone();
        move || run_index(&app)
    };
    *shell.watcher.lock().unwrap() = Some(FolderWatcher::start(&folders, shell.options.index_folder(), changed));
    run_index(app);
}

/// Has the index helper sync and index, once there's a model and a folder.
fn run_index(app: &AppHandle) {
    let shell = app.state::<Arc<Shell>>();
    if !shell.is_set_up() || shell.folders().is_empty() || !shell.model_ready() {
        return;
    }
    if let Err(error) = shell.index.run(&shell.index_launch()) {
        set_status(app, &format!("Indexing couldn't start: {error}"));
    }
}

fn stop_helpers(app: &AppHandle) {
    let shell = app.state::<Arc<Shell>>();
    shell.model.stop();
    shell.index.stop();
    shell.search.stop();
}

fn quit(app: &AppHandle) {
    stop_helpers(app);
    app.exit(0);
}

// MARK: Windows

fn make_panel(app: &AppHandle) -> tauri::Result<()> {
    let panel = WebviewWindowBuilder::new(app, "panel", WebviewUrl::App("index.html".into()))
        .title("DigUp")
        .inner_size(PANEL_WIDTH, FIELD_HEIGHT)
        .decorations(false)
        .transparent(true)
        .shadow(true)
        .resizable(false)
        .maximizable(false)
        .minimizable(false)
        .always_on_top(true)
        .visible_on_all_workspaces(true)
        .skip_taskbar(true)
        .visible(false)
        .build()?;
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

fn show_panel(app: &AppHandle) {
    if !app.state::<Arc<Shell>>().is_set_up() {
        let _ = show_setup(app);
        return;
    }
    let Some(panel) = app.get_webview_window("panel") else { return };
    // On the screen with the pointer, centered, a fifth of the way down.
    if let Ok(pointer) = app.cursor_position() {
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
}

fn toggle_panel(app: &AppHandle) {
    match app.get_webview_window("panel") {
        Some(panel) if panel.is_visible().unwrap_or(false) => hide_panel(app.clone()),
        _ => show_panel(app),
    }
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
            "Super" => "Win",
            other => other,
        })
        .collect::<Vec<_>>()
        .join("+")
}

// MARK: The tray

fn make_tray(app: &AppHandle, shell: &Arc<Shell>) -> tauri::Result<()> {
    let status = MenuItem::with_id(app, "status", "Starting…", false, None::<&str>)?;
    let search = MenuItem::with_id(app, "search", "Search…", true, Some(shell.hotkey().as_str()))?;
    let folders = MenuItem::with_id(app, "folders", "Choose Folders…", true, None::<&str>)?;
    let index = MenuItem::with_id(app, "index", "Index Now", true, None::<&str>)?;
    let quit_item = MenuItem::with_id(app, "quit", "Quit DigUp", true, None::<&str>)?;
    let separator = PredefinedMenuItem::separator(app)?;
    let menu = Menu::with_items(
        app,
        &[&status, &separator, &search, &folders, &index, &PredefinedMenuItem::separator(app)?, &quit_item],
    )?;
    // A Mac's menu bar takes a template (it colors it); trays elsewhere show the app's own small icon.
    #[cfg(target_os = "macos")]
    let icon = tauri::include_image!("icons/tray-template.png");
    #[cfg(not(target_os = "macos"))]
    let icon = tauri::include_image!("icons/tray.png");
    TrayIconBuilder::with_id("digup")
        .icon(icon)
        .icon_as_template(cfg!(target_os = "macos"))
        .tooltip("DigUp")
        .menu(&menu)
        .show_menu_on_left_click(cfg!(target_os = "macos"))
        .on_menu_event(|app, event| match event.id().as_ref() {
            "search" => show_panel(app),
            "folders" => {
                let _ = show_setup(app);
            }
            "index" => run_index(app),
            "quit" => quit(app),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            // Windows and Linux: a click opens the panel, the menu is on the other button.
            if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = event {
                if !cfg!(target_os = "macos") {
                    toggle_panel(tray.app_handle());
                }
            }
        })
        .build(app)?;
    *shell.status.lock().unwrap() = Some(status);
    Ok(())
}

fn set_status(app: &AppHandle, text: &str) {
    if let Some(status) = app.state::<Arc<Shell>>().status.lock().unwrap().as_ref() {
        let _ = status.set_text(text);
    }
    let _ = app.emit("status", text);
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
    let count = |key: &str| event[key].as_u64().unwrap_or(0);
    match event["event"].as_str().unwrap_or_default() {
        "file" => {
            set_status(app, &format!("Indexing {} of {}", count("done"), count("total")));
            reload(app, false);
        }
        "rest" => {
            set_status(app, &format!("Reading the rest of {} long files", count("files")));
            reload(app, false);
        }
        "idle" => {
            set_status(app, &format!("Up to date · {} files", count("searchable")));
            reload(app, true);
            // A debug run through setup searches once the first index is in.
            let shell = app.state::<Arc<Shell>>();
            if let Some(query) = &shell.options.debug_query {
                if shell.options.debug_setup && !shell.debug_query_sent.swap(true, Ordering::SeqCst) {
                    let _ = app.emit_to("panel", "debug-query", query.clone());
                }
            }
        }
        "waiting" => set_status(app, "Waiting for the model"),
        "error" => set_status(app, &format!("Indexing: {}", event["message"].as_str().unwrap_or("error"))),
        "exit" => reload(app, true),
        _ => {}
    }
    let _ = app.emit("helper", json!({"from": "index", "event": event}));
}

fn model_event(app: &AppHandle, event: Value) {
    if cfg!(debug_assertions) && event["event"] != "progress" {
        println!("model: {event}");
    }
    let shell = app.state::<Arc<Shell>>().inner().clone();
    let state = match event["event"].as_str().unwrap_or_default() {
        "progress" => {
            let (bytes, total) = (event["all_bytes"].as_f64().unwrap_or(0.0), event["all_total"].as_f64().unwrap_or(1.0));
            set_status(app, &format!("Downloading the model · {:.0}%", 100.0 * bytes / total.max(1.0)));
            json!({"state": "downloading", "bytes": bytes, "total": total})
        }
        "file" => json!({"state": "downloading", "from": event["from"]}),
        "verifying" => json!({"state": "checking"}),
        "waiting" => json!({"state": "waiting"}),
        "retry" => json!({"state": "downloading", "problem": event["message"]}),
        "done" => json!({"state": "ready"}),
        "error" => {
            set_status(app, "The model couldn't download");
            json!({"state": "failed", "message": event["message"]})
        }
        _ => return,
    };
    let ready = state["state"] == "ready";
    *shell.model_state.lock().unwrap() = state.clone();
    let _ = app.emit("model", state);
    if ready {
        if shell.folders().is_empty() {
            set_status(app, "No folders chosen yet");
        }
        run_index(app);
    }
}

/// Has the search service read the index again: at once when indexing settles, else at most every three seconds.
fn reload(app: &AppHandle, now: bool) {
    let shell = app.state::<Arc<Shell>>().inner().clone();
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
