//! The folders code search offers before the person picks their own (the Mac app's CodeFolders.swift): where people
//! keep repositories.

use std::path::{Path, PathBuf};

/// Home folders that aren't where code is kept (Windows', Linux's and the Mac's).
const NOT_CODE: [&str; 20] = ["Desktop", "Documents", "Downloads", "Pictures", "Videos", "Music", "Movies", "Public",
                              "Templates", "Library", "Applications", "AppData", "OneDrive", "Contacts", "Favorites",
                              "Links", "Saved Games", "Searches", "3D Objects", "snap"];
/// The names people keep repositories under in Documents and on the Desktop.
const HOLDERS: [&str; 8] = ["GitHub", "Code", "Projects", "Developer", "dev", "src", "repos", "Repositories"];

/// The home folder's folders that hold a repository (themselves or one level down), the usual places for them in
/// Documents and on the Desktop, and Visual Studio's source\repos; by name.
pub fn candidates(home: &Path) -> Vec<PathBuf> {
    let mut found: Vec<PathBuf> = std::fs::read_dir(home)
        .into_iter()
        .flatten()
        .filter_map(Result::ok)
        .filter(|entry| {
            let name = entry.file_name().to_string_lossy().to_string();
            !name.starts_with('.') && !NOT_CODE.contains(&name.as_str())
        })
        .map(|entry| entry.path())
        .filter(|folder| folder.is_dir() && holds_code(folder))
        .collect();
    for parent in ["Documents", "Desktop"] {
        found.extend(HOLDERS.iter().map(|name| home.join(parent).join(name)).filter(|folder| holds_code(folder)));
    }
    let repos = home.join("source").join("repos");
    if !found.contains(&home.join("source")) && holds_code(&repos) {
        found.push(repos);
    }
    found.sort_by_key(|folder| folder.file_name().map(|name| name.to_string_lossy().to_lowercase()));
    found.dedup();
    found
}

/// A repository, or a folder with one in it (one level down; the first 500 folders looked at).
fn holds_code(folder: &Path) -> bool {
    if folder.join(".git").exists() {
        return true;
    }
    std::fs::read_dir(folder)
        .into_iter()
        .flatten()
        .filter_map(Result::ok)
        .filter(|entry| !entry.file_name().to_string_lossy().starts_with('.'))
        .take(500)
        .any(|entry| entry.path().join(".git").exists())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn offers_folders_that_hold_repositories() {
        let home = std::env::temp_dir().join(format!("digup-code-home-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        for repo in ["Codes/app/.git", "tool/.git", "Documents/GitHub/site/.git", "Documents/notes/x/.git",
                     "Downloads/thing/.git", "source/repos/game/.git", ".hidden/repo/.git", "papers/drafts"] {
            std::fs::create_dir_all(home.join(repo)).unwrap();
        }
        let found = candidates(&home);
        assert_eq!(found, [home.join("Codes"), home.join("Documents/GitHub"), home.join("source/repos"), home.join("tool")]);
        std::fs::remove_dir_all(home).unwrap();
    }
}
