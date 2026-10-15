//! The tray icon: DigUp's logo (Resources/AppIcon/tray.svg and its tray*.png, as the Mac app's menubar shows it). While
//! the model downloads or files index, the tiles are dimmed and get their color back in a sweep from the top, clockwise,
//! as far as it has come; while indexing is paused, two bars take the D's place. An update waiting puts a red dot at the
//! top right, as on the Mac.

use std::f64::consts::TAU;
use tauri::image::Image;

const LOGO: &[u8] = include_bytes!("../../../Resources/AppIcon/tray.png");
const DIMMED: &[u8] = include_bytes!("../../../Resources/AppIcon/tray-dim.png");
const PAUSED: &[u8] = include_bytes!("../../../Resources/AppIcon/tray-paused.png");

/// What the icon shows: progress (0…1) or none, whether indexing is paused, and whether an update waits.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Look {
    /// In steps of a twenty-fourth of a turn: a tray icon redraws only when the sweep visibly moves.
    pub step: Option<u8>,
    pub paused: bool,
    pub update: bool,
}

impl Look {
    pub fn new(progress: Option<f64>, paused: bool) -> Look {
        Look { step: progress.map(|progress| (progress.clamp(0.0, 1.0) * 24.0).round() as u8), paused, update: false }
    }

    pub fn with_update(self, update: bool) -> Look {
        Look { update, ..self }
    }
}

pub fn image(look: Look) -> Image<'static> {
    let drawn = picture(look);
    if !look.update {
        return drawn;
    }
    // The dot, with a gap cut round it so it reads as a dot on the logo and not part of it (the Mac's StatusIcon, at
    // 18 points: a gap 7 across and a dot 4.5 across, centered 3 points in from the top right).
    let (width, height) = (drawn.width(), drawn.height());
    let scale = f64::from(width) / 18.0;
    let (center_x, center_y) = (15.0 * scale, 3.0 * scale);
    let mut rgba = drawn.rgba().to_vec();
    for (index, pixel) in rgba.chunks_mut(4).enumerate() {
        let x = (index as u32 % width) as f64 + 0.5 - center_x;
        let y = (index as u32 / width) as f64 + 0.5 - center_y;
        let distance = (x * x + y * y).sqrt();
        if distance <= 2.25 * scale {
            pixel.copy_from_slice(&[255, 59, 48, 255]);
        } else if distance <= 3.5 * scale {
            pixel.copy_from_slice(&[0, 0, 0, 0]);
        }
    }
    Image::new_owned(rgba, width, height)
}

fn picture(look: Look) -> Image<'static> {
    let picture = |png: &[u8]| Image::from_bytes(png).expect("the tray's pictures are PNGs");
    if look.paused {
        return picture(PAUSED);
    }
    let Some(step) = look.step else { return picture(LOGO) };
    let (logo, dimmed) = (picture(LOGO), picture(DIMMED));
    let (width, height) = (logo.width(), logo.height());
    let reached = f64::from(step) / 24.0;
    let mut rgba = dimmed.rgba().to_vec();
    for (index, pixel) in rgba.chunks_mut(4).enumerate() {
        let x = (index as u32 % width) as f64 + 0.5 - f64::from(width) / 2.0;
        let y = (index as u32 / width) as f64 + 0.5 - f64::from(height) / 2.0;
        // How far round from the top, clockwise (0…1).
        if (x.atan2(-y) / TAU).rem_euclid(1.0) < reached {
            pixel.copy_from_slice(&logo.rgba()[index * 4..index * 4 + 4]);
        }
    }
    Image::new_owned(rgba, width, height)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn draws_each_look() {
        let pixels = |look: Look| image(look).rgba().to_vec();
        let idle = pixels(Look::new(None, false));
        let none = pixels(Look::new(Some(0.0), false));
        let paused = pixels(Look::new(None, true));
        assert_ne!(idle, none);
        assert_ne!(none, paused);
        assert_eq!(pixels(Look::new(Some(1.0), false)), idle);   // all the way round: the logo
        // Half way: the right half is the logo's, the left half still dimmed.
        let half = pixels(Look::new(Some(0.5), false));
        let width = image(Look::new(None, false)).width() as usize;
        let at = |rgba: &[u8], x: usize, y: usize| rgba[(y * width + x) * 4..(y * width + x) * 4 + 4].to_vec();
        assert_eq!(at(&half, width * 3 / 4, width / 4), at(&idle, width * 3 / 4, width / 4));
        assert_eq!(at(&half, width / 4, width * 3 / 4), at(&none, width / 4, width * 3 / 4));
        assert_eq!(Look::new(Some(0.5), false), Look::new(Some(0.51), false));
        // An update waiting: a red dot at the top right, the rest as it was.
        let dotted = pixels(Look::new(None, false).with_update(true));
        assert_eq!(at(&dotted, width * 15 / 18, width * 3 / 18), vec![255, 59, 48, 255]);
        assert_eq!(at(&dotted, width / 2, width / 2), at(&idle, width / 2, width / 2));
    }
}
