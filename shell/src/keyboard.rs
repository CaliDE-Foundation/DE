//! Keyboard layouts and app folders: small lookups for the shell.

/// The short name shown in the top bar for an xkb layout ("us" -> "en",
/// "de" -> "de", "us+dvorak" -> "en"), like GNOME.
pub fn short_name(layout: &str) -> String {
    let base = layout.split(['+', '(']).next().unwrap_or(layout).trim();
    let short = match base {
        "us" | "gb" | "au" | "ca" | "ie" | "nz" | "za" => "en",
        "jp" => "ja",
        "kr" => "ko",
        "cn" => "zh",
        "se" => "sv",
        "dk" => "da",
        "ua" => "uk",
        "gr" => "el",
        "il" => "he",
        "ir" => "fa",
        "br" => "pt",
        other => other,
    };
    short.chars().take(3).collect()
}

/// The app grid folder an app goes in, from its desktop Categories, like
/// GNOME's default Utilities and System folders. None = top level.
pub fn folder(categories: &str) -> Option<&'static str> {
    let has = |c: &str| categories.split(';').any(|x| x == c);
    if has("Settings") || has("System") || has("Monitor") || has("PackageManager") {
        Some("System")
    } else if has("Utility") || has("Accessibility") || has("Archiving") {
        Some("Utilities")
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layout_names() {
        assert_eq!(short_name("us"), "en");
        assert_eq!(short_name("de"), "de");
        assert_eq!(short_name("us+dvorak"), "en");
        assert_eq!(short_name("fr(azerty)"), "fr");
        assert_eq!(short_name("latam"), "lat");
    }

    #[test]
    fn folders() {
        assert_eq!(folder("GNOME;GTK;Utility;TextEditor;"), Some("Utilities"));
        assert_eq!(folder("GTK;System;Monitor;"), Some("System"));
        assert_eq!(folder("Network;WebBrowser;"), None);
        assert_eq!(folder("Utilitarian;"), None);
    }
}
