//! Per-channel reply style: the prompt block that tells the model it is texting
//! rather than writing a document, and the sanitizer that strips markdown from
//! a reply even when the model slips.

const SHARED_MESSAGING_RULES: &str = "You are replying in a personal messaging app, not writing a document. Write like a normal person texting: short sentences, warm and direct. Plain text only — no markdown, no headings, no bullet lists, no numbered lists, no code fences, no backticks, no bold/italic markers, no links formatted as markdown. Keep replies compact (usually 1–4 short sentences). Break long answers into a few messages worth of prose, not a wall of text. Do not mention being an AI unless the user asks. Do not use crepus artifacts or interactive widgets — the channel UI cannot render them.";

pub const TELEGRAM_REPLY_LIMIT: usize = 4096;
pub const IMESSAGE_REPLY_LIMIT: usize = 2000;

pub fn channel_style_prompt(channel: &str) -> String {
    if channel == "telegram" {
        return format!(
            "Delivery channel: Telegram. {SHARED_MESSAGING_RULES} Telegram allows a little structure, but still avoid markdown — use line breaks sparingly instead of bullets."
        );
    }
    format!(
        "Delivery channel: iMessage/SMS. {SHARED_MESSAGING_RULES} iMessage reads best as casual texts — no lists, no tables, no emoji spam unless the user uses them first."
    )
}

pub fn reply_limit(channel: &str) -> usize {
    if channel == "telegram" {
        TELEGRAM_REPLY_LIMIT
    } else {
        IMESSAGE_REPLY_LIMIT
    }
}

/// Strip common markdown so channel replies stay plain even if the model slips.
pub fn sanitize_channel_reply(channel: &str, text: &str) -> String {
    let mut value = text.trim().to_string();
    if value.is_empty() {
        return value;
    }
    value = drop_fenced_blocks(&value).trim().to_string();
    value = unwrap_markdown_links(&value);
    value = strip_line_prefixes(&value);
    for marker in ["**", "*", "__", "_", "`"] {
        value = unwrap_emphasis(&value, marker);
    }
    value = collapse_blank_lines(&value).trim().to_string();
    let limit = reply_limit(channel);
    if value.chars().count() > limit {
        let head: String = value.chars().take(limit - 1).collect();
        value = format!("{head}…");
    }
    value
}

fn drop_fenced_blocks(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    let mut rest = value;
    while let Some(open) = rest.find("```") {
        let after = &rest[open + 3..];
        let Some(close) = after.find("```") else {
            out.push_str(rest);
            return out;
        };
        out.push_str(&rest[..open]);
        rest = &after[close + 3..];
    }
    out.push_str(rest);
    out
}

fn unwrap_markdown_links(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    let bytes = value.as_bytes();
    let mut index = 0usize;
    while index < bytes.len() {
        if bytes[index] == b'[' {
            if let Some(label_end) = value[index + 1..].find(']').map(|at| index + 1 + at) {
                if label_end + 1 < bytes.len() && bytes[label_end + 1] == b'(' {
                    if let Some(url_end) = value[label_end + 2..]
                        .find(')')
                        .map(|at| label_end + 2 + at)
                    {
                        let label = &value[index + 1..label_end];
                        let url = &value[label_end + 2..url_end];
                        if !label.is_empty() && !url.is_empty() {
                            out.push_str(label);
                            out.push_str(" (");
                            out.push_str(url);
                            out.push(')');
                            index = url_end + 1;
                            continue;
                        }
                    }
                }
            }
        }
        let ch = value[index..].chars().next().unwrap_or('\0');
        out.push(ch);
        index += ch.len_utf8();
    }
    out
}

/// Drop leading `#` headings and `-`/`*`/`+`/`1.` list markers per line.
fn strip_line_prefixes(value: &str) -> String {
    value
        .split('\n')
        .map(|line| {
            let heading = line.trim_start_matches('#');
            let hashes = line.len() - heading.len();
            let line = if (1..=6).contains(&hashes) && heading.starts_with(char::is_whitespace) {
                heading.trim_start()
            } else {
                line
            };
            let body = line.trim_start();
            if let Some(rest) = body
                .strip_prefix('-')
                .or_else(|| body.strip_prefix('*'))
                .or_else(|| body.strip_prefix('+'))
            {
                if rest.starts_with(char::is_whitespace) {
                    return rest.trim_start().to_string();
                }
            }
            let digits: String = body.chars().take_while(char::is_ascii_digit).collect();
            if !digits.is_empty() {
                if let Some(rest) = body[digits.len()..].strip_prefix('.') {
                    if rest.starts_with(char::is_whitespace) {
                        return rest.trim_start().to_string();
                    }
                }
            }
            line.to_string()
        })
        .collect::<Vec<String>>()
        .join("\n")
}

/// Remove a paired inline marker, keeping the text between it. Mirrors the
/// non-greedy `marker([^marker]+)marker` replacements.
fn unwrap_emphasis(value: &str, marker: &str) -> String {
    let inner = marker.chars().next().unwrap_or('`');
    let mut out = String::with_capacity(value.len());
    let mut rest = value;
    while let Some(open) = rest.find(marker) {
        let after = &rest[open + marker.len()..];
        let body_end = match after.find(inner) {
            Some(index) if index > 0 => index,
            _ => {
                out.push_str(&rest[..open + marker.len()]);
                rest = after;
                continue;
            }
        };
        if !after[body_end..].starts_with(marker) {
            out.push_str(&rest[..open + marker.len()]);
            rest = after;
            continue;
        }
        out.push_str(&rest[..open]);
        out.push_str(&after[..body_end]);
        rest = &after[body_end + marker.len()..];
    }
    out.push_str(rest);
    out
}

fn collapse_blank_lines(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    let mut newlines = 0usize;
    for ch in value.chars() {
        if ch == '\n' {
            newlines += 1;
            if newlines <= 2 {
                out.push(ch);
            }
            continue;
        }
        newlines = 0;
        out.push(ch);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn telegram_and_imessage_each_get_plain_text_rules() {
        let telegram = channel_style_prompt("telegram");
        let imessage = channel_style_prompt("imessage");
        assert!(telegram.contains("Delivery channel: Telegram."));
        assert!(imessage.contains("Delivery channel: iMessage/SMS."));
        for prompt in [&telegram, &imessage] {
            assert!(prompt.contains("no markdown"));
            assert!(prompt.contains("Plain text only"));
            assert!(prompt.contains("crepus"));
        }
        assert_ne!(telegram, imessage);
    }

    #[test]
    fn strips_markdown_markers() {
        assert_eq!(
            sanitize_channel_reply("telegram", "**bold** and *italic* and `code`"),
            "bold and italic and code"
        );
        assert_eq!(
            sanitize_channel_reply("telegram", "__under__ and _one_"),
            "under and one"
        );
        assert_eq!(
            sanitize_channel_reply("imessage", "# Heading\n- first\n- second\n1. third"),
            "Heading\nfirst\nsecond\nthird"
        );
        assert_eq!(
            sanitize_channel_reply("telegram", "see [the docs](https://example.com)"),
            "see the docs (https://example.com)"
        );
    }

    #[test]
    fn removes_fenced_blocks() {
        assert_eq!(
            sanitize_channel_reply("telegram", "before\n```crepus\ntext \"hi\"\n```\nafter"),
            "before\n\nafter"
        );
        // An unterminated fence is left alone rather than swallowing the reply.
        assert!(sanitize_channel_reply("telegram", "before ```oops").contains("before"));
    }

    #[test]
    fn caps_each_channel_at_its_own_limit() {
        let long = "a".repeat(5000);
        let telegram = sanitize_channel_reply("telegram", &long);
        assert_eq!(telegram.chars().count(), TELEGRAM_REPLY_LIMIT);
        assert!(telegram.ends_with('…'));
        let imessage = sanitize_channel_reply("imessage", &long);
        assert_eq!(imessage.chars().count(), IMESSAGE_REPLY_LIMIT);
        assert!(imessage.ends_with('…'));
        let exact = "b".repeat(IMESSAGE_REPLY_LIMIT);
        assert_eq!(sanitize_channel_reply("imessage", &exact), exact);
    }

    #[test]
    fn an_empty_or_blank_reply_stays_empty() {
        assert_eq!(sanitize_channel_reply("telegram", "   \n  "), "");
        assert_eq!(
            sanitize_channel_reply("telegram", "```\nonly code\n```"),
            ""
        );
    }
}
