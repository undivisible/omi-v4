mod approval;
mod assistant_tools;
pub mod brief;
mod byok_tier;
#[cfg(feature = "facetime")]
mod call_bridge;
mod capture_gap_log;
pub mod capture_policy;
mod capture_service;
mod capture_upload;
mod capture_wal;
mod capture_wal_uploader;
mod chat_router;
mod computer_use;
mod computer_use_tools;
mod daily_review;
mod dev_gemini;
mod evidence;
mod extraction;
#[cfg(feature = "facetime")]
mod facetime_bridge;
#[cfg(feature = "facetime")]
mod facetime_page;
mod hosted_search;
mod live_voice;
mod local_ai;
#[cfg(feature = "facetime")]
mod mark_video;
pub mod meeting;
mod meeting_capture;
pub mod meeting_detector;
mod model_tier;
mod personality;
mod proactive_binds;
// Rewind is continuous screen history, which only exists on a desktop with a
// framebuffer to read. Gating the module out keeps its policy, its store and
// its retention arithmetic from linking into the iOS and Android builds at
// all, rather than shipping code those platforms can never reach.
#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
pub mod rewind;
mod runtime;
mod runtime_capture;
mod scan;
mod security;
mod self_improve;
pub mod signals;
pub mod speech_embedding;
pub mod speech_profiles;
pub mod speech_recognition;
pub mod speech_segments;
mod stt;
mod transcription;
mod user_profile;
mod vad;

use rinf::{dart_shutdown, write_interface};
use runtime::{CommandDispatcher, runtime_status};
use signals::{AudioChunk, ClientCommand, NativeEvent};
use tokio::spawn;
use transcription::AudioDispatcher;

write_interface!();

#[tokio::main(flavor = "multi_thread", worker_threads = 4)]
async fn main() {
    NativeEvent::RuntimeStatus(runtime_status(false)).send();

    let (audio_sender, transcription_sender, live_tool_calls, audio_dispatcher) =
        AudioDispatcher::channel_with_live_tools();
    let (command_sender, dispatcher) = CommandDispatcher::channel_with_transcription_and_live_tools(
        transcription_sender,
        live_tool_calls,
        capture_service::spawn(),
    );
    let (meeting_sender, meeting_runtime) = meeting::channel(command_sender.clone());
    meeting::install(meeting_sender);
    let meeting_runtime = spawn(meeting_runtime.run());
    let dispatcher = spawn(dispatcher.run());
    let audio_dispatcher = spawn(audio_dispatcher.run());
    let command_listener = spawn(ClientCommand::listen(command_sender));
    let audio_listener = spawn(AudioChunk::listen(audio_sender));
    #[cfg(any(target_os = "macos", target_os = "windows"))]
    let meeting_poll = spawn(meeting_detector::run_meeting_poll());
    dart_shutdown().await;
    command_listener.abort();
    audio_listener.abort();
    meeting_runtime.abort();
    #[cfg(any(target_os = "macos", target_os = "windows"))]
    meeting_poll.abort();
    let _ = command_listener.await;
    let _ = audio_listener.await;
    let _ = dispatcher.await;
    let _ = audio_dispatcher.await;
}

#[cfg(test)]
mod tests {
    use super::signals::{AudioChunk, AudioEncoding, MAX_AUDIO_CHUNK_BYTES, ValidationError};

    fn chunk(bytes: usize) -> AudioChunk {
        AudioChunk {
            request_id: "voice-1".into(),
            sequence: 0,
            sample_rate_hz: 16_000,
            channels: 1,
            encoding: AudioEncoding::PcmS16Le,
            end_of_stream: false,
            bytes: vec![0; bytes],
        }
    }

    #[test]
    fn audio_chunks_are_bounded() {
        assert_eq!(chunk(1).validate(), Ok(()));
        assert_eq!(chunk(0).validate(), Err(ValidationError::EmptyAudio));
        let mut ended = chunk(0);
        ended.end_of_stream = true;
        assert_eq!(ended.validate(), Ok(()));
        assert_eq!(
            chunk(MAX_AUDIO_CHUNK_BYTES + 1).validate(),
            Err(ValidationError::AudioChunkTooLarge)
        );
    }

    #[test]
    fn audio_metadata_is_checked() {
        let mut invalid = chunk(2);
        invalid.channels = 3;
        assert_eq!(invalid.validate(), Err(ValidationError::InvalidChannels));

        invalid.channels = 1;
        invalid.sample_rate_hz = 4_000;
        assert_eq!(invalid.validate(), Err(ValidationError::InvalidSampleRate));
    }
}
