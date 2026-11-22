//! Status icons in the top bar and quick settings, from cali-statusd's values.

use std::ffi::CStr;

/// What cali-statusd reports. Levels are 0-1, or negative when unavailable.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CaliStatus {
    /// 0 unknown, 1 offline, 2 wired, 3 Wi-Fi, 4 connecting.
    pub network: u32,
    pub wifi_available: bool,
    pub wifi_enabled: bool,
    pub bluetooth_available: bool,
    pub bluetooth_enabled: bool,
    pub volume: f32,
    pub muted: bool,
    pub battery: f32,
    pub charging: bool,
    pub brightness: f32,
}

impl Default for CaliStatus {
    fn default() -> Self {
        CaliStatus {
            network: 0,
            wifi_available: false,
            wifi_enabled: false,
            bluetooth_available: false,
            bluetooth_enabled: false,
            volume: -1.0,
            muted: false,
            battery: -1.0,
            charging: false,
            brightness: -1.0,
        }
    }
}

pub fn volume_icon(volume: f32, muted: bool) -> &'static CStr {
    if muted || volume <= 0.0 {
        c"audio-volume-muted-symbolic"
    } else if volume < 0.34 {
        c"audio-volume-low-symbolic"
    } else if volume < 0.67 {
        c"audio-volume-medium-symbolic"
    } else {
        c"audio-volume-high-symbolic"
    }
}

const BATTERY: [&CStr; 11] = [
    c"battery-level-0-symbolic", c"battery-level-10-symbolic", c"battery-level-20-symbolic",
    c"battery-level-30-symbolic", c"battery-level-40-symbolic", c"battery-level-50-symbolic",
    c"battery-level-60-symbolic", c"battery-level-70-symbolic", c"battery-level-80-symbolic",
    c"battery-level-90-symbolic", c"battery-level-100-symbolic",
];
const BATTERY_CHARGING: [&CStr; 11] = [
    c"battery-level-0-charging-symbolic", c"battery-level-10-charging-symbolic",
    c"battery-level-20-charging-symbolic", c"battery-level-30-charging-symbolic",
    c"battery-level-40-charging-symbolic", c"battery-level-50-charging-symbolic",
    c"battery-level-60-charging-symbolic", c"battery-level-70-charging-symbolic",
    c"battery-level-80-charging-symbolic", c"battery-level-90-charging-symbolic",
    c"battery-level-100-charged-symbolic",
];

/// Battery icon in steps of 10%.
pub fn battery_icon(level: f32, charging: bool) -> &'static CStr {
    let step = ((level.clamp(0.0, 1.0) * 10.0).round()) as usize;
    if charging { BATTERY_CHARGING[step] } else { BATTERY[step] }
}

pub fn network_icon(s: &CaliStatus) -> Option<&'static CStr> {
    Some(match s.network {
        1 if s.wifi_available && !s.wifi_enabled => c"network-wireless-disabled-symbolic",
        1 => c"network-offline-symbolic",
        2 => c"network-wired-symbolic",
        3 => c"network-wireless-signal-excellent-symbolic",
        4 if s.wifi_available => c"network-wireless-acquiring-symbolic",
        4 => c"network-wired-acquiring-symbolic",
        _ => return None,
    })
}

/// The top bar's status icons, left to right.
pub fn icons(s: &CaliStatus) -> Vec<&'static CStr> {
    let mut out = Vec::new();
    out.extend(network_icon(s));
    if s.bluetooth_available && s.bluetooth_enabled {
        out.push(c"bluetooth-active-symbolic");
    }
    if s.volume >= 0.0 {
        out.push(volume_icon(s.volume, s.muted));
    }
    if s.battery >= 0.0 {
        out.push(battery_icon(s.battery, s.charging));
    }
    out.push(c"system-shutdown-symbolic");
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unknown_status_shows_only_power() {
        assert_eq!(icons(&CaliStatus::default()), vec![c"system-shutdown-symbolic"]);
    }

    #[test]
    fn laptop_on_wifi() {
        let s = CaliStatus {
            network: 3,
            wifi_available: true,
            wifi_enabled: true,
            bluetooth_available: true,
            bluetooth_enabled: true,
            volume: 0.5,
            battery: 0.84,
            charging: true,
            ..Default::default()
        };
        assert_eq!(
            icons(&s),
            vec![
                c"network-wireless-signal-excellent-symbolic",
                c"bluetooth-active-symbolic",
                c"audio-volume-medium-symbolic",
                c"battery-level-80-charging-symbolic",
                c"system-shutdown-symbolic",
            ]
        );
    }

    #[test]
    fn volume_levels() {
        assert_eq!(volume_icon(0.0, false), c"audio-volume-muted-symbolic");
        assert_eq!(volume_icon(0.9, true), c"audio-volume-muted-symbolic");
        assert_eq!(volume_icon(0.2, false), c"audio-volume-low-symbolic");
        assert_eq!(volume_icon(0.9, false), c"audio-volume-high-symbolic");
    }

    #[test]
    fn battery_steps() {
        assert_eq!(battery_icon(0.04, false), c"battery-level-0-symbolic");
        assert_eq!(battery_icon(0.46, false), c"battery-level-50-symbolic");
        assert_eq!(battery_icon(1.0, true), c"battery-level-100-charged-symbolic");
        assert_eq!(battery_icon(7.0, false), c"battery-level-100-symbolic");
    }

    #[test]
    fn wifi_switched_off() {
        let s = CaliStatus { network: 1, wifi_available: true, ..Default::default() };
        assert_eq!(network_icon(&s), Some(c"network-wireless-disabled-symbolic"));
    }
}
