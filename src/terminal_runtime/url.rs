/// Extracts a URL from a whitespace-delimited word. Words often carry prose
/// punctuation that is not whitespace-separated, such as `(https://a.b/c)」` or
/// `資料はhttps://a.b。`, so the URL ends at the first character outside RFC 3986
/// and drops trailing sentence punctuation and unbalanced closing brackets.
pub(super) fn normalize_terminal_url(value: &str) -> Option<String> {
    const SCHEMES: [&str; 4] = ["https://", "http://", "file://", "mailto:"];
    let (start, prefix) = SCHEMES
        .iter()
        .filter_map(|scheme| value.find(scheme).map(|start| (start, "")))
        .min()
        .or_else(|| {
            let start = value.find("www.")?;
            let preceded_by_word = value[..start]
                .chars()
                .next_back()
                .is_some_and(|previous| previous.is_ascii_alphanumeric());
            (!preceded_by_word).then_some((start, "https://"))
        })?;
    let candidate = &value[start..];
    let end = candidate
        .find(|value: char| !is_terminal_url_char(value))
        .unwrap_or(candidate.len());
    let url = trim_terminal_url_suffix(&candidate[..end]);
    let has_target = SCHEMES
        .iter()
        .chain(["www."].iter())
        .any(|scheme| url.len() > scheme.len() && url.starts_with(scheme));
    has_target.then(|| format!("{prefix}{url}"))
}

fn is_terminal_url_char(value: char) -> bool {
    value.is_ascii_alphanumeric() || "-._~:/?#[]@!$&'()*+,;=%".contains(value)
}

fn trim_terminal_url_suffix(mut url: &str) -> &str {
    loop {
        let Some(last) = url.chars().next_back() else {
            return url;
        };
        let unbalanced = match last {
            ')' => url.matches('(').count() < url.matches(')').count(),
            ']' => url.matches('[').count() < url.matches(']').count(),
            '.' | ',' | ';' | ':' | '!' | '?' | '\'' => true,
            _ => false,
        };
        if !unbalanced {
            return url;
        }
        url = &url[..url.len() - last.len_utf8()];
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::terminal_runtime::{NativeTerminalRuntime, TerminalGridSize, TerminalPoint};

    #[test]
    fn terminal_url_detection_strips_surrounding_prose() {
        let artifact = "https://example.com/docs/83ba-4939";
        for (word, expected) in [
            (format!("({artifact})」"), Some(artifact.to_owned())),
            (format!("資料は{artifact}。"), Some(artifact.to_owned())),
            (format!("<{artifact}>,"), Some(artifact.to_owned())),
            (format!("\"{artifact}\"."), Some(artifact.to_owned())),
            (
                "https://en.wikipedia.org/wiki/Rust_(language)".to_owned(),
                Some("https://en.wikipedia.org/wiki/Rust_(language)".to_owned()),
            ),
            (
                "(https://example.com/a?b=1&c=[2]).".to_owned(),
                Some("https://example.com/a?b=1&c=[2]".to_owned()),
            ),
            (
                "「www.example.com」".to_owned(),
                Some("https://www.example.com".to_owned()),
            ),
            (
                "mailto:alice@example.com,".to_owned(),
                Some("mailto:alice@example.com".to_owned()),
            ),
            (
                "file:///tmp/a.txt".to_owned(),
                Some("file:///tmp/a.txt".to_owned()),
            ),
            ("https://".to_owned(), None),
            ("(https://)".to_owned(), None),
            ("awww.example.com".to_owned(), None),
            ("plain".to_owned(), None),
        ] {
            assert_eq!(normalize_terminal_url(&word), expected, "word: {word}");
        }
    }

    #[test]
    fn soft_wrapped_url_opens_from_every_row_without_prose_punctuation() {
        let mut runtime = NativeTerminalRuntime::external(TerminalGridSize {
            rows: 6,
            cols: 20,
            pixel_width: 200,
            pixel_height: 120,
        })
        .unwrap();
        runtime
            .feed_external("資料 (https://example.com/abcdefghijklmnop)」".as_bytes())
            .unwrap();
        for (row, col) in [(0, 8), (1, 2), (2, 0)] {
            assert_eq!(
                runtime
                    .hyperlink_at(TerminalPoint { row, col })
                    .unwrap()
                    .as_deref(),
                Some("https://example.com/abcdefghijklmnop"),
                "row {row} col {col}"
            );
        }
    }
}
