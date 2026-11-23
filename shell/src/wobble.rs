//! Wobbly windows: a small spring model. While a window is dragged, the parts
//! far from the pointer lag behind; when it stops, they spring back with a
//! few wobbles.

/// Spring state for one window: how far its far corners lag behind, and how
/// fast that lag is changing.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CaliWobble {
    pub lag_x: f32,
    pub lag_y: f32,
    pub vel_x: f32,
    pub vel_y: f32,
}

const STIFFNESS: f32 = 260.0;
const MAX_LAG: f32 = 160.0;
/// How much of the window's motion (in seconds) the far corners trail by.
const TRAIL_SECONDS: f32 = 0.15;

/// Advances the springs by `dt` seconds after the window moved by (dx, dy).
/// `strength` (0-1) is how much the window bends; `friction` (0-1) how
/// quickly the wobble settles.
pub fn step(w: &mut CaliWobble, dx: f32, dy: f32, dt: f32, strength: f32, friction: f32) {
    let dt = dt.clamp(0.001, 0.05);
    // While moving, the far parts trail behind in proportion to the speed;
    // when the window stops the target is zero and they spring back,
    // overshooting a few times (the wobble).
    let trail = TRAIL_SECONDS * 2.0 * strength.clamp(0.0, 1.0);
    let target_x = -(dx / dt) * trail;
    let target_y = -(dy / dt) * trail;
    let damping = 2.0 * STIFFNESS.sqrt() * friction.clamp(0.02, 1.0);
    let ax = STIFFNESS * (target_x - w.lag_x) - damping * w.vel_x;
    let ay = STIFFNESS * (target_y - w.lag_y) - damping * w.vel_y;
    w.vel_x += ax * dt;
    w.vel_y += ay * dt;
    w.lag_x = (w.lag_x + w.vel_x * dt).clamp(-MAX_LAG, MAX_LAG);
    w.lag_y = (w.lag_y + w.vel_y * dt).clamp(-MAX_LAG, MAX_LAG);
}

pub fn settled(w: &CaliWobble) -> bool {
    w.lag_x.abs() < 0.3 && w.lag_y.abs() < 0.3 && w.vel_x.abs() < 2.0 && w.vel_y.abs() < 2.0
}

/// How far to move the point (x, y) of a `width` x `height` window grabbed at
/// (gx, gy): nothing at the grab point, the full lag at the farthest corner.
pub fn offset(w: &CaliWobble, x: f32, y: f32, gx: f32, gy: f32, width: f32, height: f32) -> (f32, f32) {
    // Normalise by the farthest corner from the grab point, so that corner
    // trails by the whole lag wherever the window was grabbed.
    let reach = |cx: f32, cy: f32| ((cx - gx).powi(2) + (cy - gy).powi(2)).sqrt();
    let far = reach(0.0, 0.0).max(reach(width, 0.0)).max(reach(0.0, height)).max(reach(width, height)).max(1.0);
    let dist = ((x - gx).powi(2) + (y - gy).powi(2)).sqrt();
    let weight = (dist / far).clamp(0.0, 1.0).powf(1.5);
    (w.lag_x * weight, w.lag_y * weight)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn moving_right_leaves_the_far_side_behind() {
        let mut w = CaliWobble::default();
        for _ in 0..20 {
            step(&mut w, 9.0, 0.0, 0.016, 0.5, 0.25); // ~560 px/s
        }
        assert!(w.lag_x < -20.0 && w.lag_y == 0.0, "should trail visibly: {w:?}");
    }

    #[test]
    fn it_wobbles_then_settles() {
        let mut w = CaliWobble::default();
        for _ in 0..20 {
            step(&mut w, 9.0, 0.0, 0.016, 0.5, 0.25);
        }
        let mut crossed = false;
        let start = w.lag_x;
        for _ in 0..600 {
            step(&mut w, 0.0, 0.0, 0.016, 0.5, 0.25);
            if w.lag_x.signum() != start.signum() && w.lag_x.abs() > 0.5 {
                crossed = true; // overshot: that's the wobble
            }
        }
        assert!(crossed, "should overshoot at least once");
        assert!(settled(&w), "should settle: {w:?}");
    }

    #[test]
    fn grab_point_stays_put() {
        let w = CaliWobble { lag_x: -40.0, lag_y: 10.0, ..Default::default() };
        assert_eq!(offset(&w, 100.0, 20.0, 100.0, 20.0, 800.0, 600.0), (0.0, 0.0));
        let (fx, fy) = offset(&w, 800.0, 600.0, 0.0, 0.0, 800.0, 600.0);
        assert!((fx + 40.0).abs() < 0.01 && (fy - 10.0).abs() < 0.01);
    }
}
