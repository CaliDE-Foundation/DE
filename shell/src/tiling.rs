//! Tiling layouts: Hyprland-style dwindle and niri-style scrolling columns.

use crate::overview::CaliRect;

fn rect(x: f32, y: f32, width: f32, height: f32) -> CaliRect {
    CaliRect { x, y, width, height }
}

/// Dwindle: the first window takes `ratio` of the area, split along its
/// longer side; the rest go in the remainder the same way, so each new
/// window halves the space of the one before it.
pub fn dwindle(area: CaliRect, n: usize, gap: f32, ratio: f32) -> Vec<CaliRect> {
    let ratio = ratio.clamp(0.1, 0.9);
    let mut out = Vec::with_capacity(n);
    let mut r = area;
    for i in 0..n {
        if i == n - 1 {
            out.push(r);
            break;
        }
        if r.width >= r.height {
            let w = (r.width - gap) * ratio;
            out.push(rect(r.x, r.y, w, r.height));
            r = rect(r.x + w + gap, r.y, r.width - w - gap, r.height);
        } else {
            let h = (r.height - gap) * ratio;
            out.push(rect(r.x, r.y, r.width, h));
            r = rect(r.x, r.y + h + gap, r.width, r.height - h - gap);
        }
    }
    out
}

/// Scrolling columns: windows sit side by side in a strip of columns
/// (`column_width` is a share of the area). The strip scrolls so the
/// focused column is centered, but never past either end. Columns outside
/// the view get positions outside the area.
pub fn scrolling(area: CaliRect, n: usize, focused: usize, column_width: f32, gap: f32) -> Vec<CaliRect> {
    if n == 0 {
        return Vec::new();
    }
    let w = (area.width * column_width.clamp(0.1, 1.0)).max(1.0);
    let strip = n as f32 * w + (n - 1) as f32 * gap;
    let focused = focused.min(n - 1);
    let center = focused as f32 * (w + gap) + w / 2.0;
    let max_scroll = (strip - area.width).max(0.0);
    let scroll = (center - area.width / 2.0).clamp(0.0, max_scroll);
    // A short strip is centered on screen.
    let lead = if strip < area.width { (area.width - strip) / 2.0 } else { 0.0 };
    (0..n)
        .map(|i| rect(area.x + lead + i as f32 * (w + gap) - scroll, area.y, w, area.height))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn area() -> CaliRect {
        rect(0.0, 0.0, 1000.0, 600.0)
    }

    #[test]
    fn dwindle_one_two_three() {
        assert_eq!(dwindle(area(), 1, 10.0, 0.5), vec![area()]);
        let two = dwindle(area(), 2, 10.0, 0.5);
        assert_eq!(two, vec![rect(0.0, 0.0, 495.0, 600.0), rect(505.0, 0.0, 495.0, 600.0)]);
        let three = dwindle(area(), 3, 10.0, 0.5);
        // The right half is taller than wide, so it splits top/bottom.
        assert_eq!(three[1], rect(505.0, 0.0, 495.0, 295.0));
        assert_eq!(three[2], rect(505.0, 305.0, 495.0, 295.0));
    }

    #[test]
    fn dwindle_fills_without_overlap() {
        let rects = dwindle(area(), 6, 8.0, 0.5);
        let total: f32 = rects.iter().map(|r| r.width * r.height).sum();
        assert!(total < 1000.0 * 600.0 && total > 0.9 * 1000.0 * 600.0);
        for (i, a) in rects.iter().enumerate() {
            for b in &rects[i + 1..] {
                let overlap = a.x < b.x + b.width - 0.5 && b.x < a.x + a.width - 0.5 && a.y < b.y + b.height - 0.5 && b.y < a.y + a.height - 0.5;
                assert!(!overlap, "{a:?} overlaps {b:?}");
            }
        }
    }

    #[test]
    fn scrolling_keeps_the_focused_column_in_view() {
        let a = area();
        let cols = scrolling(a, 5, 0, 0.5, 10.0);
        assert_eq!(cols[0].x, 0.0); // at the start, no scrolling back
        let cols = scrolling(a, 5, 2, 0.5, 10.0);
        let f = cols[2];
        assert!((f.x + f.width / 2.0 - 500.0).abs() < 0.01, "focused column centered: {f:?}");
        let cols = scrolling(a, 5, 4, 0.5, 10.0);
        assert!((cols[4].x + cols[4].width - 1000.0).abs() < 0.01, "last column ends at the edge");
        assert!(cols[0].x < 0.0, "earlier columns scroll off to the left");
    }

    #[test]
    fn scrolling_centers_a_short_strip() {
        let cols = scrolling(area(), 1, 0, 0.5, 10.0);
        assert_eq!(cols, vec![rect(250.0, 0.0, 500.0, 600.0)]);
    }
}
