//! Search in the overview: how well a query matches an app's name or keywords.

/// Scores `query` against `text`, ignoring case. Higher is better:
/// exact match 100, start of the text 80, start of a word 60, anywhere 40,
/// letters in order (e.g. "txed" in "Text Editor") 10. `None` if no match.
pub fn score(query: &str, text: &str) -> Option<u32> {
    let q = query.trim().to_lowercase();
    if q.is_empty() {
        return None;
    }
    let t = text.to_lowercase();
    if t == q {
        return Some(100);
    }
    if t.starts_with(&q) {
        return Some(80);
    }
    let word_start = t
        .match_indices(&q)
        .any(|(i, _)| t[..i].chars().last().is_some_and(|c| !c.is_alphanumeric()));
    if word_start {
        return Some(60);
    }
    if t.contains(&q) {
        return Some(40);
    }
    let mut chars = t.chars();
    q.chars()
        .filter(|c| !c.is_whitespace())
        .all(|qc| chars.any(|tc| tc == qc))
        .then_some(10)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ranks_matches() {
        assert_eq!(score("text editor", "Text Editor"), Some(100));
        assert_eq!(score("tex", "Text Editor"), Some(80));
        assert_eq!(score("edit", "Text Editor"), Some(60));
        assert_eq!(score("gnome", "org.gnome.TextEditor"), Some(60));
        assert_eq!(score("xt", "Text Editor"), Some(40));
        assert_eq!(score("txed", "Text Editor"), Some(10));
        assert_eq!(score("zzz", "Text Editor"), None);
        assert_eq!(score("  ", "Text Editor"), None);
    }

    #[test]
    fn ignores_case_and_handles_unicode() {
        assert_eq!(score("ÉCRAN", "écran"), Some(100));
        assert_eq!(score("fi", "Files"), Some(80));
    }
}
