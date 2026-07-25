use crate::capture_service::CaptureControl;
use crate::signals::Command;

pub(crate) fn capture_control(request_id: &str, command: &Command) -> Option<CaptureControl> {
    match command {
        Command::OpenCaptureWal {
            directory,
            max_bytes,
            max_age_ms,
            max_segment_bytes,
        } => Some(CaptureControl::Open {
            request_id: request_id.to_owned(),
            directory: directory.clone(),
            max_bytes: *max_bytes,
            max_age_ms: *max_age_ms,
            max_segment_bytes: *max_segment_bytes,
        }),
        Command::ConfigureCaptureUpload {
            endpoint,
            firebase_token,
        } => Some(CaptureControl::ConfigureUpload {
            endpoint: endpoint.clone(),
            firebase_token: firebase_token.clone(),
        }),
        Command::BeginCaptureSegment {
            device_id,
            audio_stream_id,
            encoding,
            sample_rate_hz,
            channels,
            gap_before,
        } => Some(CaptureControl::BeginSegment {
            request_id: request_id.to_owned(),
            device_id: device_id.clone(),
            audio_stream_id: audio_stream_id.clone(),
            encoding: *encoding,
            sample_rate_hz: *sample_rate_hz,
            channels: *channels,
            gap_before: *gap_before,
        }),
        Command::AppendCaptureAudio { bytes } => Some(CaptureControl::Append {
            request_id: request_id.to_owned(),
            bytes: bytes.clone(),
        }),
        Command::SealCaptureSegment => Some(CaptureControl::Seal {
            request_id: request_id.to_owned(),
        }),
        Command::DrainCaptureWal => Some(CaptureControl::Drain {
            request_id: request_id.to_owned(),
        }),
        Command::ReadCaptureWalState => Some(CaptureControl::ReadState {
            request_id: request_id.to_owned(),
        }),
        Command::CloseCaptureWal => Some(CaptureControl::Close {
            request_id: request_id.to_owned(),
        }),
        Command::RecordCaptureGap {
            device_id,
            reason,
            ended_at_ms,
            ended_stream_id,
        } => Some(CaptureControl::RecordGap {
            device_id: device_id.clone(),
            reason: reason.clone(),
            ended_at_ms: *ended_at_ms,
            ended_stream_id: ended_stream_id.clone(),
        }),
        Command::RecordCaptureResume {
            device_id,
            at_ms,
            stream_id,
        } => Some(CaptureControl::RecordResume {
            device_id: device_id.clone(),
            at_ms: *at_ms,
            stream_id: stream_id.clone(),
        }),
        Command::ReadCaptureGaps => Some(CaptureControl::ReadGaps {
            request_id: request_id.to_owned(),
        }),
        _ => None,
    }
}
