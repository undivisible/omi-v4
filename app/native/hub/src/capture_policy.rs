use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SystemAudioCaptureMode {
    Always,
    #[default]
    OnlyDuringMeetings,
    Never,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CapturePlan {
    pub microphone: bool,
    pub system_audio: bool,
}

pub fn capture_plan(
    mode: SystemAudioCaptureMode,
    meeting_state_ready: bool,
    meeting_active: bool,
) -> CapturePlan {
    let microphone = mode != SystemAudioCaptureMode::OnlyDuringMeetings
        || (meeting_state_ready && meeting_active);
    CapturePlan {
        microphone,
        system_audio: microphone && mode != SystemAudioCaptureMode::Never,
    }
}

#[cfg(test)]
mod tests {
    use super::{CapturePlan, SystemAudioCaptureMode, capture_plan};

    #[test]
    fn only_during_meetings_waits_for_a_confirmed_meeting() {
        assert_eq!(
            capture_plan(SystemAudioCaptureMode::OnlyDuringMeetings, false, true),
            CapturePlan {
                microphone: false,
                system_audio: false
            }
        );
        assert_eq!(
            capture_plan(SystemAudioCaptureMode::OnlyDuringMeetings, true, false),
            CapturePlan {
                microphone: false,
                system_audio: false
            }
        );
        assert_eq!(
            capture_plan(SystemAudioCaptureMode::OnlyDuringMeetings, true, true),
            CapturePlan {
                microphone: true,
                system_audio: true
            }
        );
    }

    #[test]
    fn never_keeps_microphone_without_requesting_system_audio() {
        assert_eq!(
            capture_plan(SystemAudioCaptureMode::Never, true, true),
            CapturePlan {
                microphone: true,
                system_audio: false
            }
        );
    }
}
