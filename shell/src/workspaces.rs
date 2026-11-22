//! Workspaces: dynamic workspace rules and the top bar's workspace dots.

/// Look of the workspace dots in the top bar.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CaliDotStyle {
    /// Diameter of a dot (and height of the active pill).
    pub size: f32,
    /// Width of the active workspace's pill.
    pub active_width: f32,
    /// Space between dots.
    pub spacing: f32,
    /// Opacity of inactive dots (0-255).
    pub inactive_opacity: u8,
}

pub const DOTS: CaliDotStyle = CaliDotStyle {
    size: 7.0,
    active_width: 28.0,
    spacing: 6.0,
    inactive_opacity: 128,
};

/// What to change so the workspaces follow GNOME's dynamic rules.
#[derive(Debug, Default, PartialEq)]
pub struct Plan {
    /// Workspaces to remove, highest index first (so indices stay valid).
    pub remove: Vec<usize>,
    /// Add an empty workspace at the end.
    pub append: bool,
}

/// GNOME's dynamic workspaces: there is always exactly one empty workspace
/// at the end, and empty workspaces in between go away, except the one
/// you're on (it goes once you leave).
///
/// `occupied[i]` says whether workspace `i` has windows.
pub fn plan(occupied: &[bool], active: usize) -> Plan {
    let n = occupied.len();
    if n == 0 {
        return Plan { remove: Vec::new(), append: true };
    }
    let remove = (0..n - 1)
        .rev()
        .filter(|&i| !occupied[i] && i != active)
        .collect();
    Plan { remove, append: occupied[n - 1] }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn single_empty_workspace_is_left_alone() {
        assert_eq!(plan(&[false], 0), Plan::default());
    }

    #[test]
    fn filling_the_last_workspace_adds_a_new_one() {
        assert_eq!(plan(&[true], 0), Plan { remove: vec![], append: true });
    }

    #[test]
    fn empty_middle_workspaces_are_removed_highest_first() {
        let p = plan(&[true, false, true, false, false], 2);
        assert_eq!(p, Plan { remove: vec![3, 1], append: false });
    }

    #[test]
    fn the_active_workspace_is_kept_even_if_empty() {
        let p = plan(&[false, true, false], 0);
        assert_eq!(p, Plan { remove: vec![], append: false });
    }

    #[test]
    fn nothing_to_do_when_already_tidy() {
        assert_eq!(plan(&[true, true, false], 1), Plan::default());
    }
}
