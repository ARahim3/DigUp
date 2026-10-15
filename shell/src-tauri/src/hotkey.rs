//! The panel's shortcut. Windows, macOS and X11 desktops let an app grab a key combination for itself (Tauri's global
//! shortcut). Wayland doesn't let any app do that, so DigUp puts its shortcut where the desktop keeps them, where the
//! person can change or remove it: on GNOME (Wayland or X11) a custom shortcut in its keyboard settings that runs
//! `DigUp --toggle`, which asks the DigUp already running to show or hide the panel; on KDE an action in its global
//! shortcuts (KGlobalAccel), which signals DigUp while it runs. On other Wayland desktops the person adds a shortcut that
//! runs the command.

use std::path::PathBuf;

/// How the shortcut reaches DigUp on this desktop.
#[derive(Clone, Copy, PartialEq, Eq)]
#[cfg_attr(not(target_os = "linux"), allow(dead_code))] // Windows and macOS always grab it
pub enum Method {
    /// DigUp grabs the keys itself.
    Grab,
    /// A custom shortcut in GNOME's keyboard settings runs `--toggle`.
    Gnome,
    /// KDE's global shortcuts signal DigUp.
    Kde,
    /// The desktop lets no app set a shortcut: the person adds one that runs `--toggle`.
    ByHand,
}

impl Method {
    pub fn name(self) -> &'static str {
        match self {
            Method::Grab => "grab",
            Method::Gnome => "gnome",
            Method::Kde => "kde",
            Method::ByHand => "by_hand",
        }
    }
}

pub fn method() -> Method {
    #[cfg(target_os = "linux")]
    {
        if gnome::available() {
            return Method::Gnome;
        }
        if kde::available() {
            return Method::Kde;
        }
        let wayland = std::env::var_os("WAYLAND_DISPLAY").is_some_and(|display| !display.is_empty())
            || std::env::var("XDG_SESSION_TYPE").is_ok_and(|session| session == "wayland");
        if wayland {
            return Method::ByHand;
        }
    }
    Method::Grab
}

/// What a desktop shortcut runs: this program (the AppImage itself, when it runs from one) with `--toggle`.
pub fn toggle_command() -> String {
    let program = std::env::var_os("APPIMAGE")
        .map(PathBuf::from)
        .or_else(|| std::env::current_exe().ok())
        .unwrap_or_else(|| PathBuf::from("digup"));
    format!("{} --toggle", quoted(&program.display().to_string()))
}

/// A word as a shell reads it (GNOME splits a shortcut's command the same way).
fn quoted(word: &str) -> String {
    if !word.is_empty() && word.chars().all(|c| c.is_ascii_alphanumeric() || "/._-+:@%,=".contains(c)) {
        return word.to_string();
    }
    format!("'{}'", word.replace('\'', r"'\''"))
}

/// `--toggle` while DigUp runs: the toggle goes to it over D-Bus, as a second launch's single-instance plugin would
/// send it, but before this process starts GTK (the panel shows ~35 ms sooner). False when no DigUp answers.
#[cfg(target_os = "linux")]
pub fn hand_over() -> bool {
    // tauri-plugin-single-instance 2.5's object: the app's identifier + ".SingleInstance", and that as a path.
    const NAME: &str = "com.abdurrahim.DigUp.SingleInstance";
    const PATH: &str = "/com/abdurrahim/DigUp/SingleInstance";
    let Ok(connection) = zbus::blocking::Connection::session() else { return false };
    let args: Vec<String> = std::env::args().collect();
    let folder = std::env::current_dir().map(|folder| folder.display().to_string()).unwrap_or_default();
    connection.call_method(Some(NAME), PATH, Some("org.SingleInstance.DBus"), "ExecuteCallback", &(args, folder)).is_ok()
}

/// GNOME's custom shortcuts (Settings → Keyboard → View and Customize Shortcuts → Custom Shortcuts), which its
/// settings daemon runs on X11 and Wayland alike. DigUp keeps one entry of its own there.
#[cfg(target_os = "linux")]
pub mod gnome {
    use gio::prelude::*;

    const MEDIA_KEYS: &str = "org.gnome.settings-daemon.plugins.media-keys";
    const CUSTOM: &str = "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding";
    const OURS: &str = "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/digup/";

    /// A GNOME session with its settings daemon's shortcut settings.
    pub fn available() -> bool {
        let gnome = std::env::var("XDG_CURRENT_DESKTOP")
            .is_ok_and(|desktops| desktops.split(':').any(|desktop| desktop.eq_ignore_ascii_case("GNOME")));
        gnome
            && gio::SettingsSchemaSource::default()
                .is_some_and(|source| source.lookup(MEDIA_KEYS, true).is_some() && source.lookup(CUSTOM, true).is_some())
    }

    fn listed(list: &gio::Settings) -> bool {
        list.strv("custom-keybindings").iter().any(|path| path.as_str() == OURS)
    }

    /// DigUp's shortcut as GNOME has it now ("<Control><Shift>space"), if it's there.
    pub fn binding() -> Option<String> {
        if !listed(&gio::Settings::new(MEDIA_KEYS)) {
            return None;
        }
        Some(gio::Settings::with_path(CUSTOM, OURS).string("binding").to_string()).filter(|binding| !binding.is_empty())
    }

    /// Adds DigUp's shortcut (`accelerator` in Tauri's form) running `command`. When it's there already, only the
    /// command is brought up to date: a key the person chose in GNOME's settings stays.
    pub fn bind(accelerator: &str, command: &str) -> Result<(), String> {
        let list = gio::Settings::new(MEDIA_KEYS);
        let ours = gio::Settings::with_path(CUSTOM, OURS);
        let set = |key: &str, value: &str| ours.set_string(key, value).map_err(|error| error.to_string());
        let new = !listed(&list);
        if new {
            set("binding", &to_gnome(accelerator)?)?;
        }
        set("name", "DigUp")?;
        set("command", command)?;
        if new {
            // Listed last, so GNOME never reads half an entry.
            let mut paths: Vec<String> = list.strv("custom-keybindings").iter().map(|path| path.to_string()).collect();
            paths.push(OURS.to_string());
            list.set_strv("custom-keybindings", paths.iter().map(String::as_str).collect::<Vec<_>>())
                .map_err(|error| error.to_string())?;
        }
        gio::Settings::sync();
        Ok(())
    }

    /// Brings the command of DigUp's shortcut up to date when it's there (DigUp moved: a new AppImage, a new install).
    pub fn refresh(command: &str) {
        if listed(&gio::Settings::new(MEDIA_KEYS)) {
            let ours = gio::Settings::with_path(CUSTOM, OURS);
            if ours.string("command") != command && ours.set_string("command", command).is_ok() {
                gio::Settings::sync();
            }
        }
    }

    /// Tauri's form of a shortcut ("CommandOrControl+Shift+Space") in GNOME's ("<Control><Shift>space").
    pub fn to_gnome(accelerator: &str) -> Result<String, String> {
        let parts: Vec<&str> = accelerator.split('+').map(str::trim).collect();
        let (key, modifiers) = parts.split_last().ok_or("no key")?;
        let mut text = String::new();
        for modifier in modifiers {
            text.push_str(match modifier.to_ascii_lowercase().as_str() {
                "commandorcontrol" | "cmdorctrl" | "control" | "ctrl" => "<Control>",
                "shift" => "<Shift>",
                "alt" | "option" => "<Alt>",
                "super" | "meta" | "command" | "cmd" => "<Super>",
                _ => return Err(format!("{accelerator}: {modifier} isn't a key GNOME knows")),
            });
        }
        let lower = key.to_ascii_lowercase();
        let named = match lower.as_str() {
            "space" => Some("space"),
            "enter" | "return" => Some("Return"),
            "tab" => Some("Tab"),
            "backquote" => Some("grave"),
            "slash" => Some("slash"),
            "period" => Some("period"),
            "comma" => Some("comma"),
            _ => None,
        };
        let function = lower.strip_prefix('f').and_then(|number| number.parse::<u8>().ok()).filter(|n| (1..=24).contains(n));
        let plain = lower.chars().count() == 1 && lower.chars().all(|c| c.is_ascii_alphanumeric());
        match (named, function) {
            (Some(name), _) => text.push_str(name),
            (None, Some(number)) => text.push_str(&format!("F{number}")),
            _ if plain => text.push_str(&lower),
            _ => return Err(format!("{accelerator}: {key} isn't a key GNOME knows")),
        }
        Ok(text)
    }

    /// GNOME's form in the words of the panel and setup: "<Control><Shift>space" → "Ctrl+Shift+Space".
    pub fn shown(binding: &str) -> String {
        let mut parts = Vec::new();
        let mut rest = binding;
        while let Some(end) = rest.strip_prefix('<').and_then(|inner| inner.find('>')) {
            parts.push(match &rest[1..=end] {
                "Control" | "Primary" | "Ctrl" => "Ctrl".to_string(),
                "Mod1" | "Alt" => "Alt".to_string(),
                "Mod4" | "Super" => "Super".to_string(),
                other => other.to_string(),
            });
            rest = &rest[end + 2..];
        }
        let mut key = rest.chars();
        parts.push(key.next().map(|first| first.to_uppercase().chain(key).collect()).unwrap_or_default());
        parts.join("+")
    }
}

/// KDE's global shortcuts (System Settings → Shortcuts), which KDE's own apps register through KGlobalAccel: DigUp's
/// component there has one action, the panel, with DigUp's shortcut as its default. A key the person sets there stays.
#[cfg(target_os = "linux")]
pub mod kde {
    use zbus::blocking::{Connection, Proxy};
    use zbus::zvariant::OwnedObjectPath;

    const SERVICE: &str = "org.kde.kglobalaccel";
    /// The component, the action, and their names as System Settings shows them (sent as a slice: `as` on D-Bus).
    const ACTION: [&str; 4] = ["com.abdurrahim.DigUp", "toggle-panel", "DigUp", "Show or Hide the Search Panel"];
    // KGlobalAccel's flags (kglobalacceld.h), and Qt's modifiers in a key code.
    const SET_PRESENT: u32 = 2;
    const IS_DEFAULT: u32 = 8;
    const SHIFT: i32 = 0x0200_0000;
    const CTRL: i32 = 0x0400_0000;
    const ALT: i32 = 0x0800_0000;
    const META: i32 = 0x1000_0000;
    const F1: i32 = 0x0100_0030;

    /// A KDE session with its shortcut service.
    pub fn available() -> bool {
        let kde = std::env::var("XDG_CURRENT_DESKTOP")
            .is_ok_and(|desktops| desktops.split(':').any(|desktop| desktop.eq_ignore_ascii_case("KDE")));
        kde && Connection::session().is_ok_and(|connection| {
            connection
                .call_method(Some("org.freedesktop.DBus"), "/org/freedesktop/DBus", Some("org.freedesktop.DBus"),
                             "NameHasOwner", &(SERVICE,))
                .is_ok_and(|reply| reply.body().deserialize::<bool>().unwrap_or(false))
        })
    }

    fn service(connection: &Connection) -> zbus::Result<Proxy<'static>> {
        Proxy::new(connection, SERVICE, "/kglobalaccel", "org.kde.KGlobalAccel")
    }

    /// Registers the panel's action with `accelerator` (Tauri's form) as its default, then runs `pressed` on a thread of
    /// its own each time the key is pressed while DigUp runs.
    pub fn listen(accelerator: &str, pressed: impl Fn() + Send + 'static) -> Result<(), String> {
        let key = to_qt(accelerator)?;
        let (ready, answer) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let register = || -> zbus::Result<_> {
                let connection = Connection::session()?;
                let accel = service(&connection)?;
                // A key sequence is always four ints on D-Bus (unused ones 0): KDE reads four, and one short aborts it.
                let keys = vec![(vec![key, 0, 0, 0],)];
                accel.call_method("doRegister", &(ACTION.as_slice(),))?;
                // Active, then the default, as KDE's own library does. Without NoAutoloading, a key the person chose
                // stays and comes back instead of ours.
                accel.call_method("setShortcutKeys", &(ACTION.as_slice(), &keys, SET_PRESENT))?;
                accel.call_method("setShortcutKeys", &(ACTION.as_slice(), &keys, IS_DEFAULT))?;
                let path: OwnedObjectPath = accel.call("getComponent", &(ACTION[0],))?;
                let component = Proxy::new(&connection, SERVICE, path, "org.kde.kglobalaccel.Component")?;
                let signals = component.receive_signal("globalShortcutPressed")?;
                Ok((connection, signals))
            };
            let (_connection, signals) = match register() {
                Ok(registered) => registered,
                Err(error) => {
                    let _ = ready.send(Err(error.to_string()));
                    return;
                }
            };
            let _ = ready.send(Ok(()));
            for message in signals {
                if let Ok((_, action, _)) = message.body().deserialize::<(String, String, i64)>() {
                    if action == ACTION[1] {
                        pressed();
                    }
                }
            }
        });
        answer.recv().map_err(|_| "KDE's shortcut service didn't answer".to_string())?
    }

    /// DigUp's key as KDE has it now ("Ctrl+Shift+Space"), once registered.
    pub fn current() -> Option<String> {
        let connection = Connection::session().ok()?;
        let keys: Vec<(Vec<i32>,)> = service(&connection).ok()?.call("shortcutKeys", &(ACTION.as_slice(),)).ok()?;
        keys.first().and_then(|(chords,)| chords.first()).map(|&key| shown(key))
    }

    /// DigUp quits: the key is free again until it runs.
    pub fn stop() {
        if let Ok(connection) = Connection::session() {
            if let Ok(accel) = service(&connection) {
                let _ = accel.call_method("setInactive", &(ACTION.as_slice(),));
            }
        }
    }

    /// Tauri's form of a shortcut ("CommandOrControl+Shift+Space") as Qt's key code.
    pub fn to_qt(accelerator: &str) -> Result<i32, String> {
        let parts: Vec<&str> = accelerator.split('+').map(str::trim).collect();
        let (key, modifiers) = parts.split_last().ok_or("no key")?;
        let mut code = 0;
        for modifier in modifiers {
            code |= match modifier.to_ascii_lowercase().as_str() {
                "commandorcontrol" | "cmdorctrl" | "control" | "ctrl" => CTRL,
                "shift" => SHIFT,
                "alt" | "option" => ALT,
                "super" | "meta" | "command" | "cmd" => META,
                _ => return Err(format!("{accelerator}: {modifier} isn't a key KDE knows")),
            };
        }
        let upper = key.to_ascii_uppercase();
        let function = upper.strip_prefix('F').and_then(|number| number.parse::<i32>().ok()).filter(|n| (1..=24).contains(n));
        code |= match (upper.as_str(), function) {
            ("SPACE", _) => 0x20,
            ("ENTER" | "RETURN", _) => 0x0100_0004,
            ("TAB", _) => 0x0100_0001,
            ("BACKQUOTE", _) => 0x60,
            ("SLASH", _) => 0x2f,
            ("PERIOD", _) => 0x2e,
            ("COMMA", _) => 0x2c,
            (_, Some(number)) => F1 + number - 1,
            (one, None) if one.len() == 1 && one.chars().all(|c| c.is_ascii_alphanumeric()) => one.as_bytes()[0] as i32,
            _ => return Err(format!("{accelerator}: {key} isn't a key KDE knows")),
        };
        Ok(code)
    }

    /// A Qt key code in the words of the panel and setup: "Ctrl+Shift+Space".
    pub fn shown(code: i32) -> String {
        let mut parts = Vec::new();
        for (flag, name) in [(META, "Meta"), (CTRL, "Ctrl"), (ALT, "Alt"), (SHIFT, "Shift")] {
            if code & flag != 0 {
                parts.push(name.to_string());
            }
        }
        let key = code & !(SHIFT | CTRL | ALT | META);
        parts.push(match key {
            0x20 => "Space".to_string(),
            0x0100_0004 => "Enter".to_string(),
            0x0100_0001 => "Tab".to_string(),
            _ if (F1..F1 + 35).contains(&key) => format!("F{}", key - F1 + 1),
            _ => char::from_u32(key as u32).map(String::from).unwrap_or_else(|| format!("{key:#x}")),
        });
        parts.join("+")
    }
}
