pub mod signals;

use rinf::{dart_shutdown, write_interface};
use signals::{AudioChunk, ClientCommand, NativeEvent, RuntimePhase, RuntimeStatus};
use tokio::spawn;

write_interface!();

#[tokio::main(flavor = "current_thread")]
async fn main() {
    NativeEvent::RuntimeStatus(RuntimeStatus {
        phase: RuntimePhase::Ready,
        detail: None,
        computer_use_available: false,
        local_ai_available: false,
    })
    .send();

    spawn(ClientCommand::listen());
    spawn(AudioChunk::listen());
    dart_shutdown().await;
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
