//! Tiny software drawing for shell shapes that Clutter can't draw itself.

/// Renders an anti-aliased rounded rectangle filling a `width` x `height`
/// image, as premultiplied RGBA (4 bytes per pixel, rows packed).
pub fn rounded_rect(width: usize, height: usize, radius: f32, rgba: [u8; 4]) -> Vec<u8> {
    let mut out = vec![0u8; width * height * 4];
    let (hw, hh) = (width as f32 / 2.0, height as f32 / 2.0);
    let r = radius.clamp(0.0, hw.min(hh));
    let alpha = rgba[3] as f32 / 255.0;

    for y in 0..height {
        for x in 0..width {
            // Signed distance from the pixel center to the rounded rect edge.
            let px = (x as f32 + 0.5 - hw).abs() - (hw - r);
            let py = (y as f32 + 0.5 - hh).abs() - (hh - r);
            let outside = (px.max(0.0).powi(2) + py.max(0.0).powi(2)).sqrt();
            let d = outside + px.max(py).min(0.0) - r;
            let coverage = (0.5 - d).clamp(0.0, 1.0) * alpha;

            let i = (y * width + x) * 4;
            for c in 0..3 {
                out[i + c] = (rgba[c] as f32 * coverage).round() as u8;
            }
            out[i + 3] = (255.0 * coverage).round() as u8;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn alpha(img: &[u8], width: usize, x: usize, y: usize) -> u8 {
        img[(y * width + x) * 4 + 3]
    }

    #[test]
    fn circle_is_solid_inside_and_clear_in_corners() {
        let img = rounded_rect(14, 14, 7.0, [255, 255, 255, 255]);
        assert_eq!(alpha(&img, 14, 7, 7), 255);
        assert_eq!(alpha(&img, 14, 0, 0), 0);
        assert_eq!(alpha(&img, 14, 13, 13), 0);
        let edge = alpha(&img, 14, 0, 7);
        assert!(edge > 0 && edge < 255, "edge should be anti-aliased, got {edge}");
    }

    #[test]
    fn is_symmetric() {
        let (w, h) = (20, 10);
        let img = rounded_rect(w, h, 5.0, [255, 0, 0, 255]);
        for y in 0..h {
            for x in 0..w {
                assert_eq!(alpha(&img, w, x, y), alpha(&img, w, w - 1 - x, y));
                assert_eq!(alpha(&img, w, x, y), alpha(&img, w, x, h - 1 - y));
            }
        }
    }

    #[test]
    fn output_is_premultiplied() {
        let img = rounded_rect(8, 8, 4.0, [200, 100, 50, 128]);
        for px in img.chunks(4) {
            assert!(px[0] <= px[3] && px[1] <= px[3] && px[2] <= px[3]);
        }
    }
}
