//! The editors a code result opens in, at its line (the Mac app's CodeEditors.swift): each found by its command-line
//! program, on PATH or where its installer puts it, and told the line the way it takes it. Visual Studio Code's own
//! `vscode://file/…` links would need no program, but they ask for a confirmation each time.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// How an editor is told the line.
#[derive(Clone, Copy, Debug, PartialEq)]
enum Form {
    /// `-g path:line`: Visual Studio Code and the editors built on it.
    Goto,
    /// `path:line`: Zed, Sublime Text.
    Suffix,
    /// `-nLINE path`: Notepad++.
    DashN,
    /// `+LINE path`: gedit.
    Plus,
    /// `--line LINE path`: JetBrains' IDEs.
    LineFlag,
}

pub struct Editor {
    pub id: &'static str,
    pub name: &'static str,
    /// Its program's names, looked for on PATH (and in Flatpak's and Snap's folders on Linux).
    programs: &'static [&'static str],
    /// Where its installers put the program on Windows when it may not be on PATH: below %LOCALAPPDATA% or
    /// %ProgramFiles%.
    windows: &'static [&'static str],
    form: Form,
}

pub const EDITORS: &[Editor] = &[
    Editor { id: "vscode", name: "Visual Studio Code", programs: &["code", "com.visualstudio.code"],
             windows: &["Programs/Microsoft VS Code/bin/code.cmd", "Microsoft VS Code/bin/code.cmd"], form: Form::Goto },
    Editor { id: "cursor", name: "Cursor", programs: &["cursor"],
             windows: &["Programs/cursor/resources/app/bin/cursor.cmd"], form: Form::Goto },
    Editor { id: "windsurf", name: "Windsurf", programs: &["windsurf"], windows: &["Programs/Windsurf/bin/windsurf.cmd"],
             form: Form::Goto },
    Editor { id: "vscodium", name: "VSCodium", programs: &["codium", "com.vscodium.codium"],
             windows: &["Programs/VSCodium/bin/codium.cmd", "VSCodium/bin/codium.cmd"], form: Form::Goto },
    Editor { id: "zed", name: "Zed", programs: &["zed", "zeditor", "dev.zed.Zed"], windows: &["Programs/Zed/bin/zed.exe"],
             form: Form::Suffix },
    Editor { id: "sublime", name: "Sublime Text", programs: &["subl", "com.sublimetext.three"],
             windows: &["Sublime Text/subl.exe", "Sublime Text 3/subl.exe"], form: Form::Suffix },
    Editor { id: "notepad++", name: "Notepad++", programs: &["notepad++"], windows: &["Notepad++/notepad++.exe"],
             form: Form::DashN },
    Editor { id: "gedit", name: "gedit", programs: &["gedit", "org.gnome.gedit"], windows: &[], form: Form::Plus },
    Editor { id: "idea", name: "IntelliJ IDEA", programs: &["idea", "idea64"], windows: &[], form: Form::LineFlag },
    Editor { id: "pycharm", name: "PyCharm", programs: &["pycharm", "pycharm64"], windows: &[], form: Form::LineFlag },
    Editor { id: "webstorm", name: "WebStorm", programs: &["webstorm", "webstorm64"], windows: &[], form: Form::LineFlag },
    Editor { id: "goland", name: "GoLand", programs: &["goland", "goland64"], windows: &[], form: Form::LineFlag },
    Editor { id: "clion", name: "CLion", programs: &["clion", "clion64"], windows: &[], form: Form::LineFlag },
    Editor { id: "rustrover", name: "RustRover", programs: &["rustrover", "rustrover64"], windows: &[],
             form: Form::LineFlag },
    Editor { id: "rider", name: "Rider", programs: &["rider", "rider64"], windows: &[], form: Form::LineFlag },
];

impl Editor {
    /// Its program, when it's installed: in `folders` (`program_folders()`), or where its installer puts it.
    fn program(&self, folders: &[PathBuf]) -> Option<PathBuf> {
        if let Some(found) = self.programs.iter().find_map(|name| find(name, folders)) {
            return Some(found);
        }
        if cfg!(windows) {
            let bases: Vec<PathBuf> = ["LOCALAPPDATA", "ProgramFiles", "ProgramFiles(x86)"]
                .iter()
                .filter_map(|variable| std::env::var_os(variable).map(PathBuf::from))
                .collect();
            return self.windows.iter().flat_map(|below| bases.iter().map(move |base| base.join(below))).find(|path| path.is_file());
        }
        None
    }

    /// What its program is given to open `path` at `line` (from 1).
    fn arguments(&self, path: &str, line: u32) -> Vec<String> {
        match self.form {
            Form::Goto => vec!["-g".into(), format!("{path}:{line}")],
            Form::Suffix => vec![format!("{path}:{line}")],
            Form::DashN => vec![format!("-n{line}"), path.into()],
            Form::Plus => vec![format!("+{line}"), path.into()],
            Form::LineFlag => vec!["--line".into(), line.to_string(), path.into()],
        }
    }

    /// Opens `path` at `line` with `program` (this editor's), without waiting for it.
    pub fn open(&self, program: &Path, path: &str, line: u32) -> std::io::Result<()> {
        start(program, &self.arguments(path, line))
    }
}

/// Starts an app with `args`, without waiting for it.
pub fn start(program: &Path, args: &[String]) -> std::io::Result<()> {
    let mut command = Command::new(program);
    command.args(args).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x0800_0000); // CREATE_NO_WINDOW: a .cmd would otherwise flash a console
    }
    let mut child = command.spawn()?;
    // An editor's command line hands the file over and ends; an app that is its own program (gedit, a PDF viewer) stays:
    // either way it's reaped when it ends.
    std::thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(())
}

/// The editors installed, in the list's order.
pub fn installed() -> Vec<(&'static Editor, PathBuf)> {
    installed_in(&program_folders())
}

fn installed_in(folders: &[PathBuf]) -> Vec<(&'static Editor, PathBuf)> {
    EDITORS.iter().filter_map(|editor| editor.program(folders).map(|program| (editor, program))).collect()
}

/// The editor code opens in: the one chosen (`choice`: an id) if it's installed, else the first installed; none for
/// "default" (the file's default app) or when none is.
pub fn chosen(choice: &str) -> Option<(&'static Editor, PathBuf)> {
    chosen_in(choice, &program_folders())
}

fn chosen_in(choice: &str, folders: &[PathBuf]) -> Option<(&'static Editor, PathBuf)> {
    if choice == "default" {
        return None;
    }
    let mut found = installed_in(folders);
    let at = found.iter().position(|(editor, _)| editor.id == choice).unwrap_or(0);
    (!found.is_empty()).then(|| found.swap_remove(at))
}

/// Where programs are: PATH, and on Linux the folders a desktop session's PATH may lack (~/.local/bin, Snap's,
/// Flatpak's).
pub fn program_folders() -> Vec<PathBuf> {
    let mut folders: Vec<PathBuf> = std::env::var_os("PATH").map(|path| std::env::split_paths(&path).collect()).unwrap_or_default();
    if cfg!(target_os = "linux") {
        if let Some(home) = std::env::var_os("HOME").map(PathBuf::from) {
            folders.push(home.join(".local/bin"));
            folders.push(home.join(".local/share/flatpak/exports/bin"));
        }
        folders.push("/snap/bin".into());
        folders.push("/var/lib/flatpak/exports/bin".into());
    }
    folders
}

/// `name` as a program in one of `folders` (with Windows' .exe, .cmd and .bat).
pub fn find(name: &str, folders: &[PathBuf]) -> Option<PathBuf> {
    let names: Vec<String> = if cfg!(windows) {
        ["exe", "cmd", "bat"].iter().map(|extension| format!("{name}.{extension}")).collect()
    } else {
        vec![name.to_string()]
    };
    folders.iter().flat_map(|folder| names.iter().map(move |name| folder.join(name))).find(|path| runnable(path))
}

#[cfg(unix)]
fn runnable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
}

#[cfg(not(unix))]
fn runnable(path: &Path) -> bool {
    path.is_file()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn editor(id: &str) -> &'static Editor {
        EDITORS.iter().find(|editor| editor.id == id).unwrap()
    }

    #[test]
    fn each_editor_is_told_the_line_its_way() {
        let path = "/home/me/code/my app/main.rs";
        assert_eq!(editor("vscode").arguments(path, 12), ["-g", "/home/me/code/my app/main.rs:12"]);
        assert_eq!(editor("zed").arguments(path, 12), ["/home/me/code/my app/main.rs:12"]);
        assert_eq!(editor("sublime").arguments(path, 1), ["/home/me/code/my app/main.rs:1"]);
        assert_eq!(editor("notepad++").arguments(path, 7), ["-n7", path]);
        assert_eq!(editor("gedit").arguments(path, 7), ["+7", path]);
        assert_eq!(editor("pycharm").arguments(path, 7), ["--line", "7", path]);
    }

    #[test]
    fn ids_are_unique() {
        let mut ids: Vec<&str> = EDITORS.iter().map(|editor| editor.id).collect();
        ids.sort();
        ids.dedup();
        assert_eq!(ids.len(), EDITORS.len());
    }

    #[cfg(unix)]
    #[test]
    fn found_on_path_and_chosen() {
        use std::os::unix::fs::PermissionsExt;
        let folder = std::env::temp_dir().join(format!("digup-editors-{}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        for name in ["subl", "codium"] {
            let program = folder.join(name);
            std::fs::write(&program, "#!/bin/sh\n").unwrap();
            std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        std::fs::write(folder.join("zed"), "not runnable").unwrap();
        let folders = [folder.clone()];
        assert_eq!(editor("sublime").program(&folders), Some(folder.join("subl")));
        assert_eq!(editor("zed").program(&folders), None);
        // The first installed in the list's order, unless another installed one is chosen.
        assert_eq!(chosen_in("", &folders).map(|(editor, _)| editor.id), Some("vscodium"));
        assert_eq!(chosen_in("sublime", &folders).map(|(editor, _)| editor.id), Some("sublime"));
        assert_eq!(chosen_in("zed", &folders).map(|(editor, _)| editor.id), Some("vscodium"));
        assert!(chosen_in("default", &folders).is_none());
        std::fs::remove_dir_all(folder).unwrap();
    }

    /// Visual Studio Code's command line on Windows is a .cmd: it runs without a console window, and a path with
    /// spaces reaches it whole.
    #[cfg(windows)]
    #[test]
    fn runs_a_cmd_editor() {
        let folder = std::env::temp_dir().join(format!("digup editors {}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        let program = folder.join("code.cmd");
        let said = folder.join("said.txt");
        std::fs::write(&program, format!("@echo off\r\necho %* > \"{}\"\r\n", said.display())).unwrap();
        let file = folder.join("my app").join("main.rs").display().to_string();
        editor("vscode").open(&program, &file, 12).unwrap();
        let mut text = String::new();
        for _ in 0..50 {
            text = std::fs::read_to_string(&said).unwrap_or_default();
            if text.ends_with('\n') {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        assert_eq!(text.trim(), format!("-g \"{file}:12\""));
        std::fs::remove_dir_all(folder).unwrap();
    }
}
