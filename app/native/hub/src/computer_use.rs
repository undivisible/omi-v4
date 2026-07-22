use crate::signals::ComputerUseAction;
use std::time::{Duration, Instant};
use tokio_util::sync::CancellationToken;

const MAX_COMPUTER_TYPE_DURATION_MS: u64 = 30_000;

pub(crate) fn valid_type(text: &str, delay_ms: Option<u64>) -> bool {
    if text.is_empty() || text.len() > 16 * 1024 || delay_ms.is_some_and(|delay| delay > 1_000) {
        return false;
    }
    let character_count = u64::try_from(text.chars().count()).unwrap_or(u64::MAX);
    character_count
        .checked_mul(delay_ms.unwrap_or_default())
        .is_some_and(|duration| duration <= MAX_COMPUTER_TYPE_DURATION_MS)
}

#[cfg(all(
    feature = "computer-use",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
pub(crate) fn available() -> bool {
    let permissions = rs_peekaboo::Peekaboo::new().permissions();
    permissions
        .get("accessibility")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false)
        && permissions
            .get("screen_recording")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false)
}

#[cfg(not(all(
    feature = "computer-use",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
)))]
pub(crate) fn available() -> bool {
    false
}

#[cfg(all(
    feature = "computer-use",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
pub(crate) fn execute(
    action: ComputerUseAction,
    cancellation: &CancellationToken,
) -> Result<(), String> {
    if cancellation.is_cancelled() {
        return Err("computer action was cancelled".to_owned());
    }
    let peekaboo = rs_peekaboo::Peekaboo::new();
    let result = match action {
        ComputerUseAction::Click {
            x,
            y,
            button,
            count,
        } => {
            if !(1..=3).contains(&count) {
                return Err("click count must be between 1 and 3".to_owned());
            }
            let button = match button {
                crate::signals::MouseButton::Left => "left",
                crate::signals::MouseButton::Right => "right",
                crate::signals::MouseButton::Middle => "middle",
            };
            peekaboo.click(
                rs_peekaboo::automation::Target::Point(rs_peekaboo::Point { x, y }),
                button,
                count,
            )
        }
        ComputerUseAction::TypeText {
            text,
            clear,
            press_return,
            delay_ms,
        } => {
            if !valid_type(&text, delay_ms) {
                return Err("type action parameters are invalid".to_owned());
            }
            let deadline = Instant::now() + Duration::from_millis(MAX_COMPUTER_TYPE_DURATION_MS);
            if clear {
                peekaboo
                    .type_text("", true, false, None, None)
                    .map_err(|failure| failure.to_string())?;
            }
            let chunk_chars = if delay_ms.is_some() { 1 } else { 64 };
            let mut chunk = String::new();
            for character in text.chars() {
                if cancellation.is_cancelled() || Instant::now() >= deadline {
                    return Err("computer action was cancelled".to_owned());
                }
                chunk.push(character);
                if chunk.chars().count() == chunk_chars {
                    peekaboo
                        .type_text(&chunk, false, false, delay_ms, None)
                        .map_err(|failure| failure.to_string())?;
                    chunk.clear();
                }
            }
            if !chunk.is_empty() {
                peekaboo
                    .type_text(&chunk, false, false, delay_ms, None)
                    .map_err(|failure| failure.to_string())?;
            }
            if cancellation.is_cancelled() || Instant::now() >= deadline {
                return Err("computer action was cancelled".to_owned());
            }
            if press_return {
                peekaboo.type_text("", false, true, None, None)
            } else {
                Ok(serde_json::Value::Null)
            }
        }
    };
    result.map(|_| ()).map_err(|failure| failure.to_string())
}

#[cfg(not(all(
    feature = "computer-use",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
)))]
pub(crate) fn execute(
    _action: ComputerUseAction,
    _cancellation: &CancellationToken,
) -> Result<(), String> {
    Err("computer use is unavailable on this platform".to_owned())
}

#[cfg(test)]
mod tests {
    use super::valid_type;

    #[test]
    fn typing_duration_is_bounded() {
        assert!(valid_type("hello", Some(10)));
        assert!(valid_type("hello", None));
        assert!(!valid_type("", None));
        assert!(!valid_type(&"x".repeat(31), Some(1_000)));
        assert!(!valid_type("x", Some(1_001)));
    }
}
