//! Screenshots: where they go and saving them as PNG.

use std::path::{Path, PathBuf};

use resvg::tiny_skia;

/// The user's Pictures folder: XDG_PICTURES_DIR from user-dirs.dirs, else ~/Pictures.
pub fn pictures_dir(home: &Path, user_dirs: Option<&str>) -> PathBuf {
    if let Some(text) = user_dirs {
        for line in text.lines() {
            let Some(value) = line.trim().strip_prefix("XDG_PICTURES_DIR=") else { continue };
            let value = value.trim().trim_matches('"');
            let path = match value.strip_prefix("$HOME") {
                Some(rest) => home.join(rest.trim_start_matches('/')),
                None => PathBuf::from(value),
            };
            if path.is_absolute() {
                return path;
            }
        }
    }
    home.join("Pictures")
}

/// `<Pictures>/Screenshots/Screenshot From <stamp>.png` (GNOME's naming),
/// creating the folder.
pub fn screenshot_path(stamp: &str) -> Option<PathBuf> {
    let home = PathBuf::from(std::env::var_os("HOME")?);
    let config = std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from).unwrap_or_else(|| home.join(".config"));
    let user_dirs = std::fs::read_to_string(config.join("user-dirs.dirs")).ok();
    let dir = pictures_dir(&home, user_dirs.as_deref()).join("Screenshots");
    std::fs::create_dir_all(&dir).ok()?;
    Some(dir.join(format!("Screenshot From {stamp}.png")))
}

/// Saves premultiplied RGBA pixels (`stride` bytes per row) as a PNG.
pub fn save_png(path: &Path, width: u32, height: u32, stride: usize, data: &[u8]) -> bool {
    let row = width as usize * 4;
    if stride < row || data.len() < stride * height as usize {
        return false;
    }
    let mut packed = Vec::with_capacity(row * height as usize);
    for y in 0..height as usize {
        packed.extend_from_slice(&data[y * stride..y * stride + row]);
    }
    let Some(size) = tiny_skia::IntSize::from_wh(width, height) else { return false };
    let Some(pixmap) = tiny_skia::Pixmap::from_vec(packed, size) else { return false };
    pixmap.save_png(path).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pictures_dir_follows_user_dirs() {
        let home = Path::new("/home/me");
        assert_eq!(pictures_dir(home, None), PathBuf::from("/home/me/Pictures"));
        let dirs = "# comment\nXDG_DESKTOP_DIR=\"$HOME/Desktop\"\nXDG_PICTURES_DIR=\"$HOME/Bilder\"\n";
        assert_eq!(pictures_dir(home, Some(dirs)), PathBuf::from("/home/me/Bilder"));
        assert_eq!(pictures_dir(home, Some("XDG_PICTURES_DIR=\"/data/pics\"")), PathBuf::from("/data/pics"));
    }

    #[test]
    fn saves_a_png_with_padded_rows() {
        let path = std::env::temp_dir().join(format!("cali-shot-{}.png", std::process::id()));
        // 2x2 image, rows padded to 12 bytes.
        let mut data = vec![0u8; 24];
        data[0..4].copy_from_slice(&[255, 0, 0, 255]);
        data[12..16].copy_from_slice(&[0, 0, 255, 255]);
        assert!(save_png(&path, 2, 2, 12, &data));
        let back = tiny_skia::Pixmap::load_png(&path).unwrap();
        assert_eq!((back.width(), back.height()), (2, 2));
        assert_eq!(&back.data()[0..4], &[255, 0, 0, 255]);
        assert_eq!(&back.data()[8..12], &[0, 0, 255, 255]);
        let _ = std::fs::remove_file(path);
        assert!(!save_png(Path::new("/tmp/x.png"), 2, 2, 4, &data)); // stride too small
    }
}
