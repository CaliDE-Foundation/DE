//! The dock at the bottom of the overview: which apps it shows and its look.

use std::ffi::CString;
use std::sync::Mutex;

/// Look of the dock.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CaliDockStyle {
    pub icon_size: f32,
    /// Space around the icons inside the dock.
    pub padding: f32,
    pub spacing: f32,
    pub corner_radius: f32,
    /// Background, 0xRRGGBBAA.
    pub background: u32,
    /// Diameter of the "app is running" dot under an icon.
    pub running_dot: f32,
    /// Gap between the dock and the bottom of the screen.
    pub bottom_margin: f32,
}

pub const STYLE: CaliDockStyle = CaliDockStyle {
    icon_size: 48.0,
    padding: 10.0,
    spacing: 10.0,
    corner_radius: 20.0,
    background: 0x2a2a2ad0,
    running_dot: 5.0,
    bottom_margin: 16.0,
};

/// Default favorites, like GNOME's: files, web, text, terminal, software, settings.
pub const DEFAULT_FAVORITES: &[&str] = &[
    "org.gnome.Nautilus.desktop",
    "firefox.desktop",
    "org.gnome.TextEditor.desktop",
    "org.gnome.Console.desktop",
    "org.gnome.Software.desktop",
    "org.gnome.Settings.desktop",
];

/// Parses a favorites list: desktop file IDs separated by commas or spaces.
/// Entries that aren't `*.desktop` are skipped, duplicates removed.
pub fn parse_favorites(list: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for id in list.split(|c: char| c == ',' || c.is_whitespace()) {
        let id = id.trim();
        if id.ends_with(".desktop") && !id.contains('/') && !out.iter().any(|o| o == id) {
            out.push(id.to_string());
        }
    }
    out
}

static FAVORITES: Mutex<Option<Vec<CString>>> = Mutex::new(None);

fn to_c(ids: Vec<String>) -> Vec<CString> {
    ids.into_iter().filter_map(|id| CString::new(id).ok()).collect()
}

/// Replaces the favorites (from the dock-favorites setting).
pub fn set_favorites(list: &str) {
    *FAVORITES.lock().unwrap() = Some(to_c(parse_favorites(list)));
}

/// The `i`th favorite: from the setting, else `$CALI_DOCK_FAVORITES`, else
/// the defaults. The pointer stays valid until the favorites change.
pub fn favorite(i: usize) -> Option<*const std::ffi::c_char> {
    let mut guard = FAVORITES.lock().unwrap();
    let list = guard.get_or_insert_with(|| {
        to_c(match std::env::var("CALI_DOCK_FAVORITES") {
            Ok(list) if !list.trim().is_empty() => parse_favorites(&list),
            _ => DEFAULT_FAVORITES.iter().map(|s| s.to_string()).collect(),
        })
    });
    list.get(i).map(|id| id.as_ptr())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_and_cleans_favorites() {
        assert_eq!(
            parse_favorites("a.desktop, b.desktop  a.desktop,notes.txt,../x.desktop,"),
            vec!["a.desktop", "b.desktop"]
        );
        assert!(parse_favorites("  ").is_empty());
    }

    #[test]
    fn defaults_are_valid_ids() {
        let joined = DEFAULT_FAVORITES.join(",");
        assert_eq!(parse_favorites(&joined).len(), DEFAULT_FAVORITES.len());
    }
}
