//! The system menu on the right of the top bar.

use std::ffi::CStr;

/// What a menu entry does. The compositor carries it out.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CaliMenuAction {
    Settings = 1,
    LogOut = 2,
    Restart = 3,
    PowerOff = 4,
}

pub struct Entry {
    pub label: &'static CStr,
    pub action: CaliMenuAction,
}

pub const ENTRIES: &[Entry] = &[
    Entry { label: c"Settings", action: CaliMenuAction::Settings },
    Entry { label: c"Log Out\u{2026}", action: CaliMenuAction::LogOut },
    Entry { label: c"Restart\u{2026}", action: CaliMenuAction::Restart },
    Entry { label: c"Power Off\u{2026}", action: CaliMenuAction::PowerOff },
];

/// Symbolic icons shown in the top bar's status area, left to right.
pub const STATUS_ICONS: &[&CStr] = &[
    c"network-wired-symbolic",
    c"audio-volume-high-symbolic",
    c"system-shutdown-symbolic",
];

/// Look of the menu popup.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CaliMenuStyle {
    pub width: f32,
    pub padding: f32,
    pub row_height: f32,
    pub corner_radius: f32,
    /// 0xRRGGBBAA
    pub background: u32,
    pub hover: u32,
    pub status_icon_size: f32,
}

pub const STYLE: CaliMenuStyle = CaliMenuStyle {
    width: 340.0,
    padding: 10.0,
    row_height: 40.0,
    corner_radius: 18.0,
    background: 0x2e2e32f8,
    hover: 0xffffff1f,
    status_icon_size: 16.0,
};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_entry_has_a_label_and_unique_action() {
        for (i, e) in ENTRIES.iter().enumerate() {
            assert!(!e.label.to_bytes().is_empty());
            assert!(ENTRIES[i + 1..].iter().all(|o| o.action != e.action));
        }
    }
}
