mod approval;
mod computer_use;
mod extraction;
mod live_voice;
mod local_ai;
mod runtime;
mod scan;
pub mod signals;
mod stt;
mod transcription;

use rinf::{dart_shutdown, write_interface};
use runtime::{CommandDispatcher, runtime_status};
use signals::{AudioChunk, ClientCommand, NativeEvent};
use tokio::spawn;
use transcription::AudioDispatcher;

write_interface!();

#[tokio::main(flavor = "current_thread")]
async fn main() {
    NativeEvent::RuntimeStatus(runtime_status(false)).send();

    let (audio_sender, transcription_sender, audio_dispatcher) = AudioDispatcher::channel();
    let (command_sender, dispatcher) =
        CommandDispatcher::channel_with_transcription(transcription_sender);
    let dispatcher = spawn(dispatcher.run());
    let audio_dispatcher = spawn(audio_dispatcher.run());
    let command_listener = spawn(ClientCommand::listen(command_sender));
    let audio_listener = spawn(AudioChunk::listen(audio_sender));
    dart_shutdown().await;
    command_listener.abort();
    audio_listener.abort();
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
