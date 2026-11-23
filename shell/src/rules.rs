//! Window rules: "MATCH -> ACTION ACTION ...", one per line.
//!
//! MATCH is an app (desktop file name, with or without ".desktop", or the
//! window class), compared without case, or `title:TEXT` for windows whose
//! title contains TEXT. Actions:
//!   workspace=N   open on workspace N        float / tile   tiling layout
//!   maximize      fullscreen                 center         above (on top)
//!   sticky        on every workspace         opacity=0.9    size=1200x800
//! Later rules add to (and override) earlier ones.

use std::sync::Mutex;

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CaliRuleActions {
    pub workspace: i32, // 1-based, 0 = no rule
    pub floating: i8,   // -1 no rule, 0 tile, 1 float
    pub maximize: bool,
    pub fullscreen: bool,
    pub center: bool,
    pub above: bool,
    pub sticky: bool,
    pub opacity: f32, // < 0 = no rule
    pub width: i32,   // 0 = no rule
    pub height: i32,
}

impl Default for CaliRuleActions {
    fn default() -> Self {
        CaliRuleActions { workspace: 0, floating: -1, maximize: false, fullscreen: false, center: false, above: false, sticky: false, opacity: -1.0, width: 0, height: 0 }
    }
}

#[derive(Clone, Debug, PartialEq)]
enum Matcher {
    App(String),
    Title(String),
}

#[derive(Clone, Debug, PartialEq)]
pub struct Rule {
    matcher: Matcher,
    actions: CaliRuleActions,
}

/// Parses one rule; None if it isn't one (blank, comment, no actions).
pub fn parse(line: &str) -> Option<Rule> {
    let line = line.trim();
    if line.is_empty() || line.starts_with('#') {
        return None;
    }
    let (left, right) = line.split_once("->")?;
    let left = left.trim();
    let matcher = match left.strip_prefix("title:") {
        Some(t) if !t.trim().is_empty() => Matcher::Title(t.trim().to_lowercase()),
        Some(_) => return None,
        None if !left.is_empty() => Matcher::App(left.trim_end_matches(".desktop").to_lowercase()),
        None => return None,
    };
    let mut a = CaliRuleActions::default();
    let mut any = false;
    for word in right.split_whitespace() {
        let (key, value) = word.split_once('=').unwrap_or((word, ""));
        let ok = match key.to_lowercase().as_str() {
            "workspace" => value.parse::<i32>().ok().filter(|n| (1..=36).contains(n)).map(|n| a.workspace = n).is_some(),
            "float" | "floating" => {
                a.floating = 1;
                true
            }
            "tile" | "tiled" => {
                a.floating = 0;
                true
            }
            "maximize" | "maximized" => {
                a.maximize = true;
                true
            }
            "fullscreen" => {
                a.fullscreen = true;
                true
            }
            "center" | "centered" => {
                a.center = true;
                true
            }
            "above" | "ontop" => {
                a.above = true;
                true
            }
            "sticky" => {
                a.sticky = true;
                true
            }
            "opacity" => value.parse::<f32>().ok().filter(|o| (0.1..=1.0).contains(o)).map(|o| a.opacity = o).is_some(),
            "size" => value
                .split_once('x')
                .and_then(|(w, h)| Some((w.parse::<i32>().ok()?, h.parse::<i32>().ok()?)))
                .filter(|(w, h)| *w >= 100 && *h >= 100)
                .map(|(w, h)| {
                    a.width = w;
                    a.height = h;
                })
                .is_some(),
            _ => false,
        };
        any |= ok;
    }
    any.then_some(Rule { matcher, actions: a })
}

impl Rule {
    fn matches(&self, app: &str, class: &str, title: &str) -> bool {
        match &self.matcher {
            Matcher::App(m) => {
                let app = app.trim_end_matches(".desktop").to_lowercase();
                (!app.is_empty() && app == *m) || (!class.is_empty() && class.to_lowercase() == *m)
            }
            Matcher::Title(t) => title.to_lowercase().contains(t.as_str()),
        }
    }
}

/// Merges every matching rule, in order.
pub fn resolve(rules: &[Rule], app: &str, class: &str, title: &str) -> Option<CaliRuleActions> {
    let mut out = CaliRuleActions::default();
    let mut hit = false;
    for r in rules.iter().filter(|r| r.matches(app, class, title)) {
        hit = true;
        let a = r.actions;
        if a.workspace != 0 {
            out.workspace = a.workspace;
        }
        if a.floating >= 0 {
            out.floating = a.floating;
        }
        out.maximize |= a.maximize;
        out.fullscreen |= a.fullscreen;
        out.center |= a.center;
        out.above |= a.above;
        out.sticky |= a.sticky;
        if a.opacity >= 0.0 {
            out.opacity = a.opacity;
        }
        if a.width > 0 {
            out.width = a.width;
            out.height = a.height;
        }
    }
    hit.then_some(out)
}

static RULES: Mutex<Vec<Rule>> = Mutex::new(Vec::new());

pub fn set(text: &str) {
    *RULES.lock().unwrap() = text.lines().filter_map(parse).collect();
}

pub fn lookup(app: &str, class: &str, title: &str) -> Option<CaliRuleActions> {
    resolve(&RULES.lock().unwrap(), app, class, title)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_actions() {
        let r = parse("org.gnome.Calculator.desktop -> float above center size=400x600 opacity=0.9").unwrap();
        assert_eq!(r.matcher, Matcher::App("org.gnome.calculator".into()));
        assert_eq!(r.actions.floating, 1);
        assert!(r.actions.above && r.actions.center);
        assert_eq!((r.actions.width, r.actions.height), (400, 600));
        assert!((r.actions.opacity - 0.9).abs() < 1e-6);
    }

    #[test]
    fn rejects_junk() {
        assert!(parse("").is_none());
        assert!(parse("# comment -> float").is_none());
        assert!(parse("firefox").is_none());
        assert!(parse("firefox -> fly").is_none());
        assert!(parse("firefox -> workspace=0 opacity=7").is_none());
        assert!(parse(" -> float").is_none());
    }

    #[test]
    fn matches_app_class_and_title_and_merges() {
        let rules: Vec<Rule> = ["firefox -> workspace=2", "title:Picture-in-Picture -> float above sticky", "firefox -> maximize"]
            .iter()
            .filter_map(|l| parse(l))
            .collect();
        let a = resolve(&rules, "firefox.desktop", "firefox", "Mozilla Firefox").unwrap();
        assert_eq!(a.workspace, 2);
        assert!(a.maximize && !a.above);
        let pip = resolve(&rules, "", "firefox", "Picture-in-Picture").unwrap();
        assert!(pip.above && pip.sticky && pip.floating == 1 && pip.workspace == 2);
        assert!(resolve(&rules, "org.gnome.Nautilus.desktop", "nautilus", "Home").is_none());
    }
}
