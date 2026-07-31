//! Recent capture audio, kept just long enough to cut a voiceprint out of it.
//!
//! Nothing else in the hub retains PCM: `meeting_capture` mixes it to mono and
//! the transcription stream sends it away. A diarized segment therefore names a
//! voice the hub can no longer hear. This buffer closes that gap by holding the
//! last few seconds of the mono capture stream so a finalized segment's own
//! `[start_ms, end_ms)` can be cut back out and handed to `speech_profiles`.
//!
//! # The clock
//!
//! The timestamps here are **milliseconds of audio sent to the current STT
//! connection**, counted from the first sample of that connection — not wall
//! clock, and not milliseconds since the meeting began.
//!
//! That is the clock `stt.rs` reports. A finalized segment's `start_ms` /
//! `end_ms` come from `seconds_to_millis(word.start / word.end)`, and the
//! provider's word offsets are relative to the audio *it* has received, which
//! begins at the websocket connection. Two consequences follow, and both are
//! encoded in the API rather than left to the caller to remember:
//!
//! * The clock **restarts at zero on every reconnect**. `stt.rs` marks that by
//!   bumping `stt_epoch` in `reconnect_gap`. [`SpeechSegmentBuffer`] therefore
//!   carries an epoch of its own: [`SpeechSegmentBuffer::begin_epoch`] clears
//!   the audio, and [`SpeechSegmentBuffer::slice_for_epoch`] refuses a window
//!   stamped by a different connection instead of cutting the same offsets out
//!   of the new stream's audio — which would be a different person entirely.
//! * A segment whose provider response carried **no word list** falls back to
//!   `occurred_at_ms` in `stt.rs`, which is a wall-clock
//!   `Utc::now().timestamp_millis()`. Those two clocks are not comparable, and
//!   such a window must never be handed to this buffer. Nothing here accepts a
//!   bare `i64`: an offset must be wrapped in [`StreamMillis`], whose only
//!   constructor, [`StreamMillis::from_word_offset_ms`], names the one clock it
//!   is allowed to come from. A wall-clock value that slips through anyway is
//!   astronomically past the retention window and is answered
//!   [`SliceError::NotYetBuffered`] — never clamped, never allocated for.
//!
//! # Retention
//!
//! [`DEFAULT_RETENTION`] is 45 seconds, sized to cover the *worst* age a
//! finalized window's first sample can have when the segment arrives: a
//! long utterance the provider endpoints late (Deepgram's utterance windows run
//! to roughly 30 s) plus finalization and delivery latency (seconds, not tens of
//! seconds) plus slack for a stalled reader task. It is deliberately not larger:
//! everything past that is a provider so far behind that the transcript is no
//! longer live, and the right answer there is no voiceprint, not a bigger
//! buffer.
//!
//! Retention is expressed in time and converted to samples with the buffer's
//! sample rate, so the bound holds at any capture rate. Peak occupancy is fixed
//! at construction: `retention_secs * sample_rate_hz * 2` bytes — 1.44 MB for
//! 45 s of the 16 kHz mono capture stream.
//!
//! # Eviction and truncation
//!
//! Audio only ever ages off the *old* end. So a window whose start has been
//! partly evicted still describes the same speaker: what survives is the tail of
//! that same window, merely shorter. Such a slice is returned, provided it is
//! still at least [`MIN_EMBEDDING_MS`] long — a shorter voiceprint is not worth
//! computing. A window reaching past the *newest* buffered sample is a different
//! matter: it means the timeline disagrees with the audio the buffer has seen
//! (clock skew, an epoch mix-up, a wall-clock timestamp), so it returns `None`
//! rather than a slice of whatever happened to be there.
//!
//! Reads never mutate. Two segments that abut or overlap both cut correctly.

use crate::speech_profiles::MIN_EMBEDDING_MS;
use std::collections::VecDeque;
use std::time::Duration;

/// How much recent capture audio is kept. See the module header for why 45 s.
pub const DEFAULT_RETENTION: Duration = Duration::from_secs(45);

/// A point on the stream clock: milliseconds of audio sent to the current STT
/// connection, counted from its first sample.
///
/// It exists so a wall-clock Unix timestamp cannot be passed where a stream
/// offset belongs. `stt.rs` reports both through the same `i64` field —
/// word-derived offsets normally, `occurred_at_ms` when a response carried no
/// words — and only the first is meaningful here.
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct StreamMillis(i64);

impl StreamMillis {
    /// Wraps an offset taken from a provider word's `start` / `end`, the only
    /// values on this clock. Negative offsets are rejected.
    pub fn from_word_offset_ms(offset_ms: i64) -> Option<Self> {
        (offset_ms >= 0).then_some(Self(offset_ms))
    }

    /// The offset in milliseconds.
    pub fn get(self) -> i64 {
        self.0
    }
}

/// A half-open `[start_ms, end_ms)` window on one STT connection's audio.
///
/// Constructed only through [`stream_window`], which is the single place the
/// "these offsets are stream-relative, not wall clock" assumption is asserted.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct StreamWindow {
    /// The STT epoch — the connection — these offsets are counted against.
    pub epoch: u32,
    /// Where the window starts on that connection's stream clock.
    pub start_ms: StreamMillis,
    /// Exclusive end, on the same clock.
    pub end_ms: StreamMillis,
}

impl StreamWindow {
    /// The window's length in milliseconds.
    pub fn duration_ms(self) -> i64 {
        self.end_ms.get() - self.start_ms.get()
    }

    /// Whether the window is long enough for a voiceprint to be worth taking.
    pub fn is_embeddable(self) -> bool {
        self.duration_ms() >= i64::from(MIN_EMBEDDING_MS)
    }
}

/// Builds a window from a finalized segment's provider-reported offsets.
///
/// `word_derived` records whether `start_ms` / `end_ms` came from the response's
/// word list. When they did not, `stt.rs` substituted a wall-clock
/// `occurred_at_ms`, which shares no origin with this buffer's clock; those
/// windows are rejected here rather than being cut out of unrelated audio.
/// Negative or non-increasing offsets are rejected for the same reason.
pub fn stream_window(
    epoch: u32,
    start_ms: i64,
    end_ms: i64,
    word_derived: bool,
) -> Option<StreamWindow> {
    if !word_derived {
        return None;
    }
    let start_ms = StreamMillis::from_word_offset_ms(start_ms)?;
    let end_ms = StreamMillis::from_word_offset_ms(end_ms)?;
    (end_ms > start_ms).then_some(StreamWindow {
        epoch,
        start_ms,
        end_ms,
    })
}

/// Why a window could not be cut.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SliceError {
    /// The window belongs to a previous STT connection, whose audio — and whose
    /// timeline — this buffer no longer holds.
    WrongEpoch,
    /// The whole window aged out of retention.
    Evicted,
    /// The window reaches past the newest buffered sample, so the timeline and
    /// the audio disagree.
    NotYetBuffered,
    /// What survives of the window is shorter than [`MIN_EMBEDDING_MS`].
    TooShort,
}

/// A bounded, timestamped ring of the most recent mono capture PCM.
#[derive(Debug)]
pub struct SpeechSegmentBuffer {
    sample_rate_hz: u32,
    capacity_samples: usize,
    samples: VecDeque<i16>,
    /// Stream-relative index of the oldest sample still held.
    first_sample: u64,
    /// Total samples pushed since the current epoch began.
    pushed_samples: u64,
    epoch: u32,
}

impl SpeechSegmentBuffer {
    /// A buffer holding `retention` of audio at `sample_rate_hz`, starting on
    /// STT epoch `epoch`.
    pub fn new(sample_rate_hz: u32, retention: Duration, epoch: u32) -> Self {
        let capacity_samples = (retention.as_millis() * u128::from(sample_rate_hz) / 1000)
            .try_into()
            .unwrap_or(usize::MAX)
            .max(1);
        Self {
            sample_rate_hz: sample_rate_hz.max(1),
            capacity_samples,
            samples: VecDeque::with_capacity(capacity_samples),
            first_sample: 0,
            pushed_samples: 0,
            epoch,
        }
    }

    /// A buffer with [`DEFAULT_RETENTION`].
    pub fn with_default_retention(sample_rate_hz: u32, epoch: u32) -> Self {
        Self::new(sample_rate_hz, DEFAULT_RETENTION, epoch)
    }

    /// The capture rate the stream clock is measured against.
    pub fn sample_rate_hz(&self) -> u32 {
        self.sample_rate_hz
    }

    /// The STT connection whose timeline the buffered audio is on.
    pub fn epoch(&self) -> u32 {
        self.epoch
    }

    /// The most samples this buffer will ever hold.
    pub fn capacity_samples(&self) -> usize {
        self.capacity_samples
    }

    /// How many samples are held right now.
    pub fn buffered_samples(&self) -> usize {
        self.samples.len()
    }

    /// The `[start_ms, end_ms)` span currently answerable, or `None` when empty.
    pub fn buffered_span_ms(&self) -> Option<(i64, i64)> {
        if self.samples.is_empty() {
            return None;
        }
        Some((
            self.samples_to_ms(self.first_sample),
            self.samples_to_ms(self.pushed_samples),
        ))
    }

    /// Starts a new STT connection: drops the old audio and restarts the clock,
    /// because the provider's word offsets restart at zero too.
    pub fn begin_epoch(&mut self, epoch: u32) {
        self.samples.clear();
        self.first_sample = 0;
        self.pushed_samples = 0;
        self.epoch = epoch;
    }

    /// Appends capture PCM, evicting whatever that pushes past retention.
    pub fn push(&mut self, pcm: &[i16]) {
        if pcm.len() >= self.capacity_samples {
            let keep = &pcm[pcm.len() - self.capacity_samples..];
            self.samples.clear();
            self.samples.extend(keep.iter().copied());
        } else {
            let overflow = (self.samples.len() + pcm.len()).saturating_sub(self.capacity_samples);
            self.samples.drain(..overflow);
            self.samples.extend(pcm.iter().copied());
        }
        self.pushed_samples = self.pushed_samples.saturating_add(pcm.len() as u64);
        self.first_sample = self.pushed_samples - self.samples.len() as u64;
    }

    /// The PCM for a window on this buffer's own epoch.
    ///
    /// Truncation at the old end is allowed; see the module header.
    pub fn slice(&self, start_ms: StreamMillis, end_ms: StreamMillis) -> Option<Vec<i16>> {
        self.try_slice(StreamWindow {
            epoch: self.epoch,
            start_ms,
            end_ms,
        })
        .ok()
    }

    /// The PCM for a window, refusing windows stamped by another connection.
    pub fn slice_for_epoch(&self, window: StreamWindow) -> Option<Vec<i16>> {
        self.try_slice(window).ok()
    }

    /// The PCM for a window, or the reason there is none.
    pub fn try_slice(&self, window: StreamWindow) -> Result<Vec<i16>, SliceError> {
        if window.epoch != self.epoch {
            return Err(SliceError::WrongEpoch);
        }
        if window.end_ms <= window.start_ms {
            return Err(SliceError::TooShort);
        }
        let start = self.ms_to_samples(window.start_ms.get());
        let end = self.ms_to_samples(window.end_ms.get());
        if end > self.pushed_samples {
            return Err(SliceError::NotYetBuffered);
        }
        if end <= self.first_sample {
            return Err(SliceError::Evicted);
        }
        let start = start.max(self.first_sample);
        if self.samples_to_ms(end) - self.samples_to_ms(start) < i64::from(MIN_EMBEDDING_MS) {
            return Err(SliceError::TooShort);
        }
        let from = (start - self.first_sample) as usize;
        let to = (end - self.first_sample) as usize;
        Ok(self.samples.range(from..to).copied().collect())
    }

    fn ms_to_samples(&self, ms: i64) -> u64 {
        let ms = ms.max(0) as u64;
        ms.saturating_mul(u64::from(self.sample_rate_hz)) / 1000
    }

    fn samples_to_ms(&self, samples: u64) -> i64 {
        (samples.saturating_mul(1000) / u64::from(self.sample_rate_hz)) as i64
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const RATE: u32 = 16_000;

    fn ramp(from: u64, count: usize) -> Vec<i16> {
        (0..count)
            .map(|index| (from + index as u64) as i16)
            .collect()
    }

    fn buffer(retention_ms: u64) -> SpeechSegmentBuffer {
        SpeechSegmentBuffer::new(RATE, Duration::from_millis(retention_ms), 0)
    }

    #[test]
    fn slices_exact_window_samples() {
        let mut buffer = buffer(10_000);
        buffer.push(&ramp(0, RATE as usize * 5));
        let slice = buffer
            .slice(ms(1_000), ms(2_000))
            .unwrap_or_else(|| panic!("window is buffered"));
        assert_eq!(slice.len(), RATE as usize);
        assert_eq!(slice.first().copied(), Some(RATE as i16));
        assert_eq!(slice.last().copied(), Some((RATE * 2 - 1) as i16));
    }

    #[test]
    fn end_is_exclusive_at_sample_boundaries() {
        let mut buffer = buffer(10_000);
        buffer.push(&ramp(0, RATE as usize * 2));
        let slice = buffer
            .slice(ms(500), ms(1_000))
            .unwrap_or_else(|| panic!("window is buffered"));
        assert_eq!(slice.len(), RATE as usize / 2);
        assert_eq!(slice.first().copied(), Some(8_000));
        assert_eq!(slice.last().copied(), Some(15_999));
        let next = buffer
            .slice(ms(1_000), ms(1_500))
            .unwrap_or_else(|| panic!("window is buffered"));
        assert_eq!(next.first().copied(), Some(16_000));
    }

    #[test]
    fn fully_evicted_window_returns_none() {
        let mut buffer = buffer(2_000);
        buffer.push(&ramp(0, RATE as usize * 10));
        assert_eq!(buffer.try_slice(window(0, 1_000)), Err(SliceError::Evicted));
        assert!(buffer.slice(ms(0), ms(1_000)).is_none());
    }

    #[test]
    fn partially_evicted_window_returns_the_surviving_tail() {
        let mut buffer = buffer(2_000);
        buffer.push(&ramp(0, RATE as usize * 3));
        let slice = buffer
            .slice(ms(500), ms(2_000))
            .unwrap_or_else(|| panic!("the tail of the window survives"));
        assert_eq!(slice.len(), RATE as usize);
        assert_eq!(slice.first().copied(), Some((RATE) as i16));
        assert_eq!(slice.last().copied(), Some((RATE * 2 - 1) as i16));
    }

    #[test]
    fn partially_evicted_window_shorter_than_the_minimum_returns_none() {
        let mut buffer = buffer(2_000);
        buffer.push(&ramp(0, RATE as usize * 3));
        assert_eq!(
            buffer.try_slice(window(500, 1_200)),
            Err(SliceError::TooShort)
        );
    }

    #[test]
    fn future_window_returns_none() {
        let mut buffer = buffer(10_000);
        buffer.push(&ramp(0, RATE as usize * 2));
        assert_eq!(
            buffer.try_slice(window(3_000, 4_000)),
            Err(SliceError::NotYetBuffered)
        );
        assert_eq!(
            buffer.try_slice(window(1_500, 2_500)),
            Err(SliceError::NotYetBuffered)
        );
    }

    #[test]
    fn empty_buffer_answers_nothing() {
        let buffer = buffer(10_000);
        assert_eq!(buffer.buffered_span_ms(), None);
        assert_eq!(
            buffer.try_slice(window(0, 1_000)),
            Err(SliceError::NotYetBuffered)
        );
    }

    #[test]
    fn overlapping_windows_both_read_correctly() {
        let mut buffer = buffer(10_000);
        buffer.push(&ramp(0, RATE as usize * 4));
        let first = buffer
            .slice(ms(1_000), ms(2_500))
            .unwrap_or_else(|| panic!("buffered"));
        let second = buffer
            .slice(ms(2_000), ms(3_000))
            .unwrap_or_else(|| panic!("buffered"));
        assert_eq!(first.first().copied(), Some(RATE as i16));
        assert_eq!(second.first().copied(), Some((RATE * 2) as i16));
        assert_eq!(first[RATE as usize..], second[..RATE as usize / 2]);
        assert_eq!(buffer.buffered_samples(), RATE as usize * 4);
    }

    #[test]
    fn adjacent_windows_do_not_share_a_sample() {
        let mut buffer = buffer(10_000);
        buffer.push(&ramp(0, RATE as usize * 3));
        let first = buffer
            .slice(ms(0), ms(1_000))
            .unwrap_or_else(|| panic!("buffered"));
        let second = buffer
            .slice(ms(1_000), ms(2_000))
            .unwrap_or_else(|| panic!("buffered"));
        assert_eq!(first.last().copied(), Some((RATE - 1) as i16));
        assert_eq!(second.first().copied(), Some(RATE as i16));
    }

    #[test]
    fn never_exceeds_retention_under_long_pushing() {
        let mut buffer = buffer(45_000);
        let capacity = buffer.capacity_samples();
        assert_eq!(capacity, RATE as usize * 45);
        for _ in 0..600 {
            buffer.push(&ramp(0, RATE as usize / 2));
            assert!(buffer.buffered_samples() <= capacity);
        }
        assert_eq!(buffer.buffered_samples(), capacity);
        let (start_ms, end_ms) = buffer
            .buffered_span_ms()
            .unwrap_or_else(|| panic!("audio is held"));
        assert_eq!(end_ms - start_ms, 45_000);
    }

    #[test]
    fn a_push_larger_than_retention_keeps_only_the_newest_audio() {
        let mut buffer = buffer(1_000);
        buffer.push(&ramp(0, RATE as usize * 3));
        assert_eq!(buffer.buffered_samples(), RATE as usize);
        let slice = buffer
            .slice(ms(2_000), ms(3_000))
            .unwrap_or_else(|| panic!("newest second is held"));
        assert_eq!(slice.first().copied(), Some((RATE * 2) as i16));
    }

    #[test]
    fn windows_from_another_epoch_are_refused() {
        let mut buffer = SpeechSegmentBuffer::new(RATE, Duration::from_millis(10_000), 3);
        buffer.push(&ramp(0, RATE as usize * 2));
        assert_eq!(
            buffer.try_slice(StreamWindow {
                epoch: 2,
                start_ms: ms(0),
                end_ms: ms(1_000),
            }),
            Err(SliceError::WrongEpoch)
        );
        assert!(
            buffer
                .slice_for_epoch(StreamWindow {
                    epoch: 3,
                    start_ms: ms(0),
                    end_ms: ms(1_000),
                })
                .is_some()
        );
    }

    #[test]
    fn a_new_epoch_drops_the_previous_connections_audio() {
        let mut buffer = buffer(10_000);
        buffer.push(&ramp(0, RATE as usize * 2));
        buffer.begin_epoch(1);
        assert_eq!(buffer.buffered_samples(), 0);
        assert_eq!(buffer.epoch(), 1);
        assert_eq!(
            buffer.try_slice(window(0, 1_000)),
            Err(SliceError::WrongEpoch)
        );
        buffer.push(&ramp(9_000, RATE as usize));
        let slice = buffer
            .slice_for_epoch(StreamWindow {
                epoch: 1,
                start_ms: ms(0),
                end_ms: ms(1_000),
            })
            .unwrap_or_else(|| panic!("the new connection's audio is buffered"));
        assert_eq!(slice.first().copied(), Some(9_000));
    }

    #[test]
    fn stream_millis_rejects_a_negative_offset() {
        assert_eq!(StreamMillis::from_word_offset_ms(-1), None);
        assert_eq!(
            StreamMillis::from_word_offset_ms(7).map(StreamMillis::get),
            Some(7)
        );
    }

    #[test]
    fn wall_clock_windows_are_not_accepted() {
        assert_eq!(stream_window(0, 1_000, 2_000, false), None);
        assert_eq!(
            stream_window(0, 1_000, 2_000, true),
            Some(StreamWindow {
                epoch: 0,
                start_ms: ms(1_000),
                end_ms: ms(2_000),
            })
        );
        assert_eq!(stream_window(0, -1, 2_000, true), None);
        assert_eq!(stream_window(0, 2_000, 2_000, true), None);
    }

    #[test]
    fn a_wall_clock_timestamp_cannot_masquerade_as_a_stream_offset() {
        let mut buffer = buffer(45_000);
        buffer.push(&ramp(0, RATE as usize * 10));
        let now_ms = 1_764_000_000_000;
        assert_eq!(
            buffer.try_slice(window(now_ms, now_ms + 1_000)),
            Err(SliceError::NotYetBuffered)
        );
    }

    #[test]
    fn window_reports_its_own_embeddability() {
        let short = window(0, 400);
        let long = window(0, 500);
        assert_eq!(short.duration_ms(), 400);
        assert!(!short.is_embeddable());
        assert!(long.is_embeddable());
    }

    fn ms(value: i64) -> StreamMillis {
        StreamMillis::from_word_offset_ms(value)
            .unwrap_or_else(|| panic!("test offsets are non-negative"))
    }

    fn window(start_ms: i64, end_ms: i64) -> StreamWindow {
        StreamWindow {
            epoch: 0,
            start_ms: ms(start_ms),
            end_ms: ms(end_ms),
        }
    }
}
