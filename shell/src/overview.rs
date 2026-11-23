//! Activities overview: where each window goes in the zoomed-out grid.

/// A rectangle in logical pixels. Shared with the compositor through the C ABI.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CaliRect {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

/// Space between windows in the grid.
pub const GAP: f32 = 32.0;

/// Places `windows` (their current sizes) in a grid inside `area`, keeping
/// each window's aspect ratio and never enlarging it. Tries every row count
/// and keeps the one that shows the windows biggest, like GNOME's overview.
pub fn layout(area: CaliRect, windows: &[CaliRect]) -> Vec<CaliRect> {
    layout_with_gap(area, windows, GAP)
}

/// Like `layout`, with a custom space between windows.
pub fn layout_with_gap(area: CaliRect, windows: &[CaliRect], gap: f32) -> Vec<CaliRect> {
    let n = windows.len();
    if n == 0 || area.width <= 0.0 || area.height <= 0.0 {
        return Vec::new();
    }

    let size = |w: &CaliRect| (w.width.max(1.0), w.height.max(1.0));
    let mut best: Option<(f32, usize, usize)> = None; // (shown area, rows, cols)

    for rows in 1..=n {
        let cols = n.div_ceil(rows);
        if (rows - 1) * cols >= n {
            continue; // would leave an empty row
        }
        let (slot_w, slot_h) = slot_size(area, rows, cols, gap);
        if slot_w <= 0.0 || slot_h <= 0.0 {
            continue;
        }
        let shown: f32 = windows
            .iter()
            .map(|w| {
                let (ww, wh) = size(w);
                let s = (slot_w / ww).min(slot_h / wh).min(1.0);
                ww * s * wh * s
            })
            .sum();
        if best.is_none_or(|(b, _, _)| shown > b) {
            best = Some((shown, rows, cols));
        }
    }

    let Some((_, rows, cols)) = best else {
        return Vec::new();
    };
    let (slot_w, slot_h) = slot_size(area, rows, cols, gap);
    let grid_h = rows as f32 * slot_h + (rows - 1) as f32 * gap;
    let top = area.y + (area.height - grid_h) / 2.0;

    windows
        .iter()
        .enumerate()
        .map(|(i, w)| {
            let (row, col) = (i / cols, i % cols);
            let in_row = cols.min(n - row * cols);
            let row_w = in_row as f32 * slot_w + (in_row - 1) as f32 * gap;
            let left = area.x + (area.width - row_w) / 2.0;

            let (ww, wh) = size(w);
            let s = (slot_w / ww).min(slot_h / wh).min(1.0);
            let (width, height) = (ww * s, wh * s);
            let slot_x = left + col as f32 * (slot_w + gap);
            let slot_y = top + row as f32 * (slot_h + gap);
            CaliRect {
                x: slot_x + (slot_w - width) / 2.0,
                y: slot_y + (slot_h - height) / 2.0,
                width,
                height,
            }
        })
        .collect()
}

fn slot_size(area: CaliRect, rows: usize, cols: usize, gap: f32) -> (f32, f32) {
    (
        (area.width - (cols - 1) as f32 * gap) / cols as f32,
        (area.height - (rows - 1) as f32 * gap) / rows as f32,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rect(x: f32, y: f32, width: f32, height: f32) -> CaliRect {
        CaliRect { x, y, width, height }
    }

    fn inside(r: &CaliRect, area: &CaliRect) -> bool {
        r.x >= area.x - 0.01
            && r.y >= area.y - 0.01
            && r.x + r.width <= area.x + area.width + 0.01
            && r.y + r.height <= area.y + area.height + 0.01
    }

    fn overlap(a: &CaliRect, b: &CaliRect) -> bool {
        a.x < b.x + b.width - 0.01
            && b.x < a.x + a.width - 0.01
            && a.y < b.y + b.height - 0.01
            && b.y < a.y + a.height - 0.01
    }

    #[test]
    fn empty() {
        assert!(layout(rect(0.0, 0.0, 100.0, 100.0), &[]).is_empty());
    }

    #[test]
    fn single_small_window_is_centered_and_not_enlarged() {
        let area = rect(0.0, 0.0, 1000.0, 800.0);
        let out = layout(area, &[rect(50.0, 50.0, 200.0, 100.0)]);
        assert_eq!(out, vec![rect(400.0, 350.0, 200.0, 100.0)]);
    }

    #[test]
    fn many_windows_fit_without_overlap_and_keep_aspect() {
        let area = rect(48.0, 64.0, 1824.0, 950.0);
        let windows: Vec<CaliRect> = (0..7)
            .map(|i| rect(0.0, 0.0, 800.0 + i as f32 * 60.0, 600.0 - i as f32 * 20.0))
            .collect();
        let out = layout(area, &windows);
        assert_eq!(out.len(), windows.len());
        for (i, r) in out.iter().enumerate() {
            assert!(inside(r, &area), "window {i} outside: {r:?}");
            let before = windows[i].width / windows[i].height;
            assert!((r.width / r.height - before).abs() < 0.01);
            assert!(r.width <= windows[i].width + 0.01);
            for other in &out[i + 1..] {
                assert!(!overlap(r, other), "{r:?} overlaps {other:?}");
            }
        }
    }

    #[test]
    fn wide_area_prefers_one_row_for_two_windows() {
        let area = rect(0.0, 0.0, 1920.0, 900.0);
        let out = layout(area, &[rect(0.0, 0.0, 800.0, 600.0); 2]);
        assert!((out[0].y - out[1].y).abs() < 0.01);
    }
}
