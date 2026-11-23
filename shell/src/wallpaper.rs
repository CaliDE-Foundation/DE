//! Wallpapers: Cali's gradients and loading images.

use resvg::tiny_skia;

/// Built-in gradients: (setting name, label, top 0xRRGGBBAA, bottom).
pub const PRESETS: [(&str, &str, u32, u32); 4] = [
    ("cali-dusk", "Dusk", 0x2c4a86ff, 0xe27d60ff),
    ("cali-day", "Day", 0x4f8fd6ff, 0xf3d7a6ff),
    ("cali-night", "Night", 0x0d1b2aff, 0x3a3f6bff),
    ("cali-forest", "Forest", 0x1f4037ff, 0x7fb59aff),
];

pub fn gradient(name: &str) -> Option<(u32, u32)> {
    PRESETS.iter().find(|p| p.0 == name).map(|p| (p.2, p.3))
}

/// The largest image side we keep (bigger images are scaled down).
pub const MAX_SIDE: u32 = 4096;

/// Loads a PNG or JPEG as premultiplied RGBA: (width, height, pixels).
pub fn load(path: &std::path::Path) -> Option<(u32, u32, Vec<u8>)> {
    let data = std::fs::read(path).ok()?;
    let image = if data.starts_with(b"\x89PNG") {
        tiny_skia::Pixmap::decode_png(&data).ok()?
    } else {
        decode_jpeg(&data)?
    };
    let image = shrink(image, MAX_SIDE);
    Some((image.width(), image.height(), image.take()))
}

fn decode_jpeg(data: &[u8]) -> Option<tiny_skia::Pixmap> {
    let mut decoder = jpeg_decoder::Decoder::new(data);
    let pixels = decoder.decode().ok()?;
    let info = decoder.info()?;
    let (w, h) = (info.width as u32, info.height as u32);
    let mut rgba = Vec::with_capacity(w as usize * h as usize * 4);
    match info.pixel_format {
        jpeg_decoder::PixelFormat::RGB24 => {
            for px in pixels.chunks_exact(3) {
                rgba.extend_from_slice(&[px[0], px[1], px[2], 255]);
            }
        }
        jpeg_decoder::PixelFormat::L8 => {
            for &l in &pixels {
                rgba.extend_from_slice(&[l, l, l, 255]);
            }
        }
        _ => return None, // CMYK and 16-bit are rare for wallpapers
    }
    tiny_skia::Pixmap::from_vec(rgba, tiny_skia::IntSize::from_wh(w, h)?)
}

fn shrink(image: tiny_skia::Pixmap, max: u32) -> tiny_skia::Pixmap {
    let (w, h) = (image.width(), image.height());
    if w <= max && h <= max {
        return image;
    }
    let scale = max as f32 / w.max(h) as f32;
    let (nw, nh) = (((w as f32 * scale) as u32).max(1), ((h as f32 * scale) as u32).max(1));
    let Some(mut out) = tiny_skia::Pixmap::new(nw, nh) else { return image };
    let paint = tiny_skia::PixmapPaint { quality: tiny_skia::FilterQuality::Bicubic, ..Default::default() };
    out.draw_pixmap(0, 0, image.as_ref(), &paint, tiny_skia::Transform::from_scale(scale, scale), None);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn presets() {
        assert_eq!(gradient("cali-dusk"), Some((0x2c4a86ff, 0xe27d60ff)));
        assert_eq!(gradient("/home/me/beach.jpg"), None);
    }

    #[test]
    fn loads_png_and_shrinks_huge_images() {
        let path = std::env::temp_dir().join(format!("cali-wall-{}.png", std::process::id()));
        let mut big = tiny_skia::Pixmap::new(5000, 100).unwrap();
        big.fill(tiny_skia::Color::from_rgba8(10, 20, 30, 255));
        big.save_png(&path).unwrap();
        let (w, h, px) = load(&path).unwrap();
        assert_eq!((w, h), (4096, 81));
        assert_eq!(&px[0..4], &[10, 20, 30, 255]);
        let _ = std::fs::remove_file(path);
        assert!(load(std::path::Path::new("/nonexistent.jpg")).is_none());
    }
}
