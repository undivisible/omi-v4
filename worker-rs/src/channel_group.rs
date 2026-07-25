//! A linked channel must be a one-to-one chat. Telegram groups use negative
//! chat ids; Sendblue/iMessage group threads use a `group_id` distinct from the
//! sender, which becomes the stored `channel_chat_id`.

use crate::jsnum::{is_safe_integer, number_from_str};

pub const GROUP_CHANNEL_LINK_ERROR: &str =
    "Group chats cannot be linked as your Omi channel. Message me in a direct chat to link.";

pub fn is_group_channel_chat(channel: &str, channel_user_id: &str, channel_chat_id: &str) -> bool {
    if channel == "telegram" {
        let value = number_from_str(channel_chat_id);
        return is_safe_integer(value) && value < 0.0;
    }
    channel_chat_id != channel_user_id
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_telegram_supergroups_by_negative_chat_id() {
        assert!(is_group_channel_chat("telegram", "42", "-1001234567890"));
        assert!(!is_group_channel_chat("telegram", "42", "42"));
        assert!(!is_group_channel_chat("telegram", "42", "1001234567890"));
    }

    #[test]
    fn a_non_integer_telegram_chat_id_is_not_a_group() {
        assert!(!is_group_channel_chat("telegram", "42", ""));
        assert!(!is_group_channel_chat("telegram", "42", "not-a-number"));
        assert!(!is_group_channel_chat("telegram", "42", "-1.5"));
    }

    #[test]
    fn detects_imessage_groups_by_chat_id() {
        assert!(is_group_channel_chat("imessage", "+15551234567", "group-abc"));
        assert!(!is_group_channel_chat(
            "imessage",
            "+15551234567",
            "+15551234567"
        ));
    }
}
