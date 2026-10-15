//! The panel on Wayland, where an app can't place its windows (the desktop puts them: GNOME at the top left). To have
//! it centered (Settings), its window fills the screen's work area instead (maximized and transparent), the page draws
//! the panel where the Mac app puts it, and the window takes the pointer only over the panel, so a click beside it
//! reaches the app below. That costs memory with the screen's size (screen-sized frames), so it's the person's choice.

#[cfg(target_os = "linux")]
use gtk::prelude::*;
#[cfg(target_os = "linux")]
use std::sync::Mutex;

/// GTK runs on Wayland here: the desktop places DigUp's windows.
pub fn active() -> bool {
    #[cfg(target_os = "linux")]
    return gtk::gdk::Display::default().is_some_and(|display| display.backend().is_wayland());
    #[cfg(not(target_os = "linux"))]
    false
}

/// The panel in its window (x, y, width, height): the part that takes the pointer.
#[cfg(target_os = "linux")]
static AREA: Mutex<Option<(i32, i32, i32, i32)>> = Mutex::new(None);

/// Keeps the pointer to the panel's area. GTK gives the whole window the pointer again each time it lays the window
/// out, so the area goes back on after it.
#[cfg(target_os = "linux")]
pub fn track(panel: &tauri::WebviewWindow) {
    if let Ok(window) = panel.gtk_window() {
        window.connect_size_allocate(|window, _| apply(window));
    }
}

/// Where the panel is now (the page measures it).
#[cfg(target_os = "linux")]
pub fn set_area(panel: &tauri::WebviewWindow, area: (i32, i32, i32, i32)) {
    *AREA.lock().unwrap() = Some(area);
    let window = panel.clone();
    let _ = panel.run_on_main_thread(move || {
        if let Ok(window) = window.gtk_window() {
            apply(&window);
        }
    });
}

#[cfg(target_os = "linux")]
fn apply(window: &impl IsA<gtk::Widget>) {
    let Some((x, y, width, height)) = *AREA.lock().unwrap() else { return };
    let region = gtk::cairo::Region::create_rectangle(&gtk::cairo::RectangleInt::new(x, y, width, height));
    window.input_shape_combine_region(Some(&region));
}
