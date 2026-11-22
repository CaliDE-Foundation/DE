//! Icons: find them in the icon themes and rasterize them to premultiplied
//! RGBA, so the compositor only has to upload pixels.

use std::path::{Path, PathBuf};

use resvg::{tiny_skia, usvg};

/// Used when an app has no icon of its own.
pub const FALLBACK: &str = "application-x-executable";
/// Last resort: newer Adwaita only ships the symbolic version.
pub const FALLBACK_SYMBOLIC: &str = "application-x-executable-symbolic";
/// Color for the symbolic fallback, so it shows on dark backgrounds.
const FALLBACK_SYMBOLIC_RGB: [u8; 3] = [0xde, 0xdd, 0xda];

const THEMES: [&str; 2] = ["hicolor", "Adwaita"];
const PNG_SIZES: [u32; 10] = [16, 22, 24, 32, 48, 64, 96, 128, 256, 512];

/// `$XDG_DATA_HOME` and `$XDG_DATA_DIRS`, in lookup order.
pub fn data_dirs() -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    match std::env::var_os("XDG_DATA_HOME") {
        Some(home) if !home.is_empty() => dirs.push(PathBuf::from(home)),
        _ => {
            if let Some(home) = std::env::var_os("HOME") {
                dirs.push(PathBuf::from(home).join(".local/share"));
            }
        }
    }
    let system = std::env::var("XDG_DATA_DIRS")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "/usr/local/share:/usr/share".into());
    dirs.extend(system.split(':').filter(|s| !s.is_empty()).map(PathBuf::from));
    dirs
}

/// Finds the best file for icon `name` at `size` pixels: PNGs at least that
/// big (smallest first), then SVG, then smaller PNGs, across the hicolor and
/// Adwaita themes (including Adwaita's symbolic folders), then pixmaps.
pub fn find(name: &str, size: u32, dirs: &[PathBuf]) -> Option<PathBuf> {
    if name.is_empty() || name.contains("..") {
        return None;
    }
    if name.starts_with('/') {
        let path = PathBuf::from(name);
        return path.is_file().then_some(path);
    }

    let mut bigger: Vec<u32> = PNG_SIZES.iter().copied().filter(|&s| s >= size).collect();
    bigger.sort_unstable();
    let mut smaller: Vec<u32> = PNG_SIZES.iter().copied().filter(|&s| s < size).collect();
    smaller.sort_unstable_by(|a, b| b.cmp(a));

    for dir in dirs {
        for theme in THEMES {
            let base = dir.join("icons").join(theme);
            let png = |s: u32| base.join(format!("{s}x{s}/apps/{name}.png"));

            let mut candidates: Vec<PathBuf> = bigger.iter().map(|&s| png(s)).collect();
            candidates.push(base.join(format!("scalable/apps/{name}.svg")));
            candidates.extend(smaller.iter().map(|&s| png(s)));
            if let Some(found) = candidates.into_iter().find(|p| p.is_file()) {
                return Some(found);
            }

            // Symbolic icons are sorted by category (status, devices, ...).
            if let Ok(categories) = std::fs::read_dir(base.join("symbolic")) {
                for category in categories.flatten() {
                    let path = category.path().join(format!("{name}.svg"));
                    if path.is_file() {
                        return Some(path);
                    }
                }
            }
        }
        for ext in ["png", "svg"] {
            let path = dir.join(format!("pixmaps/{name}.{ext}"));
            if path.is_file() {
                return Some(path);
            }
        }
    }
    None
}

/// Loads an icon file into a `size` x `size` premultiplied RGBA image,
/// scaled to fit and centered.
pub fn load(path: &Path, size: u32) -> Option<Vec<u8>> {
    let data = std::fs::read(path).ok()?;
    let mut canvas = tiny_skia::Pixmap::new(size, size)?;
    let is_svg = path.extension().is_some_and(|e| e == "svg");

    if is_svg {
        let tree = usvg::Tree::from_data(&data, &usvg::Options::default()).ok()?;
        let (w, h) = (tree.size().width(), tree.size().height());
        let scale = size as f32 / w.max(h);
        let dx = (size as f32 - w * scale) / 2.0;
        let dy = (size as f32 - h * scale) / 2.0;
        let transform = tiny_skia::Transform::from_row(scale, 0.0, 0.0, scale, dx, dy);
        resvg::render(&tree, transform, &mut canvas.as_mut());
    } else {
        let image = tiny_skia::Pixmap::decode_png(&data).ok()?;
        let (w, h) = (image.width() as f32, image.height() as f32);
        let scale = size as f32 / w.max(h);
        let dx = (size as f32 - w * scale) / 2.0;
        let dy = (size as f32 - h * scale) / 2.0;
        let paint = tiny_skia::PixmapPaint {
            quality: tiny_skia::FilterQuality::Bicubic,
            ..Default::default()
        };
        let transform = tiny_skia::Transform::from_row(scale, 0.0, 0.0, scale, dx, dy);
        canvas.draw_pixmap(0, 0, image.as_ref(), &paint, transform, None);
    }
    Some(canvas.take())
}

/// Finds and loads `name`, falling back to the generic app icon.
pub fn load_named(name: &str, size: u32) -> Option<Vec<u8>> {
    let dirs = data_dirs();
    if let Some(pixels) = [name, FALLBACK]
        .iter()
        .find_map(|n| find(n, size, &dirs).and_then(|p| load(&p, size)))
    {
        return Some(pixels);
    }
    let mut pixels = find(FALLBACK_SYMBOLIC, size, &dirs).and_then(|p| load(&p, size))?;
    recolor(&mut pixels, FALLBACK_SYMBOLIC_RGB);
    Some(pixels)
}

/// Paints every pixel `rgb`, keeping its coverage: how symbolic icons are
/// colored to match the text around them. Input and output are premultiplied.
pub fn recolor(pixels: &mut [u8], rgb: [u8; 3]) {
    for px in pixels.chunks_exact_mut(4) {
        let a = px[3] as u32;
        for c in 0..3 {
            px[c] = ((rgb[c] as u32 * a + 127) / 255) as u8;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SVG: &str = r##"<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><rect x="4" y="4" width="8" height="8" fill="#ff0000"/></svg>"##;

    fn temp_theme(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("cali-icons-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    fn write(path: &Path, data: &[u8]) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, data).unwrap();
    }

    #[test]
    fn finds_scalable_then_symbolic_then_nothing() {
        let dir = temp_theme("find");
        write(&dir.join("icons/hicolor/scalable/apps/my.app.svg"), SVG.as_bytes());
        write(&dir.join("icons/Adwaita/symbolic/status/battery-symbolic.svg"), SVG.as_bytes());
        let dirs = vec![dir.clone()];

        assert_eq!(find("my.app", 48, &dirs), Some(dir.join("icons/hicolor/scalable/apps/my.app.svg")));
        assert_eq!(
            find("battery-symbolic", 16, &dirs),
            Some(dir.join("icons/Adwaita/symbolic/status/battery-symbolic.svg"))
        );
        assert_eq!(find("missing", 48, &dirs), None);
        assert_eq!(find("../etc/passwd", 48, &dirs), None);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn prefers_a_big_enough_png() {
        let dir = temp_theme("png");
        let mut tiny = tiny_skia::Pixmap::new(1, 1).unwrap();
        tiny.fill(tiny_skia::Color::WHITE);
        let png = tiny.encode_png().unwrap();
        for s in [32, 64, 256] {
            write(&dir.join(format!("icons/hicolor/{s}x{s}/apps/app.png")), &png);
        }
        let dirs = vec![dir.clone()];
        assert_eq!(find("app", 48, &dirs), Some(dir.join("icons/hicolor/64x64/apps/app.png")));
        assert_eq!(find("app", 512, &dirs), Some(dir.join("icons/hicolor/256x256/apps/app.png")));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn renders_svg_scaled_and_centered() {
        let dir = temp_theme("load");
        let path = dir.join("icon.svg");
        write(&path, SVG.as_bytes());
        let pixels = load(&path, 32).unwrap();
        assert_eq!(pixels.len(), 32 * 32 * 4);
        let at = |x: usize, y: usize| &pixels[(y * 32 + x) * 4..(y * 32 + x) * 4 + 4];
        assert_eq!(at(16, 16), &[255, 0, 0, 255]); // red square in the middle
        assert_eq!(at(1, 1)[3], 0); // transparent margin
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn recolor_keeps_coverage() {
        let mut px = vec![10, 20, 30, 128, 0, 0, 0, 0];
        recolor(&mut px, [255, 255, 255]);
        assert_eq!(px, vec![128, 128, 128, 128, 0, 0, 0, 0]);
    }
}
