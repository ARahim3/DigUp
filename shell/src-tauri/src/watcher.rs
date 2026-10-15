//! Watching the chosen folders: a change anywhere in them asks the index helper to sync, two seconds after the last one
//! (a camera import or an unzip is a burst of events). `notify` uses ReadDirectoryChangesW on Windows, inotify on Linux,
//! FSEvents on a Mac. Changes in DigUp's own index folder are passed over.

use notify::{RecursiveMode, Watcher};
use std::path::PathBuf;
use std::sync::mpsc;
use std::time::Duration;

pub struct FolderWatcher {
    _watcher: Option<notify::RecommendedWatcher>,
}

impl FolderWatcher {
    /// Watches `folders`; `changed` runs on the watcher's own thread after each burst of changes. Dropping it stops.
    pub fn start(folders: &[PathBuf], ignore: Option<PathBuf>, changed: impl Fn() + Send + 'static) -> FolderWatcher {
        let (sender, receiver) = mpsc::channel::<()>();
        let watcher = notify::recommended_watcher(move |result: notify::Result<notify::Event>| {
            let Ok(event) = result else { return };
            if event.kind.is_access() {
                return;
            }
            let ours = |path: &PathBuf| ignore.as_ref().is_some_and(|folder| path.starts_with(folder));
            if event.paths.is_empty() || !event.paths.iter().all(ours) {
                let _ = sender.send(());
            }
        });
        let mut watcher = match watcher {
            Ok(watcher) => watcher,
            Err(error) => {
                eprintln!("digup-shell: can't watch folders: {error}");
                return FolderWatcher { _watcher: None };
            }
        };
        for folder in folders {
            if let Err(error) = watcher.watch(folder, RecursiveMode::Recursive) {
                eprintln!("digup-shell: can't watch {}: {error}", folder.display());
            }
        }
        std::thread::spawn(move || {
            while receiver.recv().is_ok() {
                while receiver.recv_timeout(Duration::from_secs(2)).is_ok() {}
                changed();
            }
        });
        FolderWatcher { _watcher: Some(watcher) }
    }
}
