//! Client-side voice-activity gating for the metered transcription path.
//!
//! The pendant streams continuously for as long as it is worn, so without a
//! gate every second of room tone is paid for three times over: Bluetooth
//! airtime, phone battery, and a metered websocket to the speech provider.
//! Worse, audio that carries nothing leaves the device anyway. This module
//! decides — inside the hub, before a byte reaches the socket — which audio is
//! worth sending, so silence stays on the phone.
//!
//! ## Why a bare threshold would be wrong
//!
//! An amplitude threshold applied naively destroys the leading consonant of
//! every utterance: by the time energy crosses the line, the attack of the
//! word is already in the past, and a transcript that starts mid-syllable is
//! worse than one paid for in full. Two mechanisms prevent that:
//!
//! * A **pre-roll ring** keeps the most recent [`GatePolicy::pre_roll_ms`] of
//!   audio while the gate is shut, and flushes it ahead of the chunk that
//!   opened the gate. The provider therefore always receives the run-up to
//!   speech, not just the part loud enough to notice.
//! * A **hangover** holds the gate open for [`GatePolicy::hangover_ms`] after
//!   energy falls away, so the pauses inside a sentence do not chop one
//!   utterance into several, each of which the provider would then punctuate
//!   and finalize separately.
//!
//! ## Why the detector sits behind a seam
//!
//! The energy detector here is deliberately the whole of the first pass: the
//! hub is linked into the iOS and Android binaries, where an ONNX runtime plus
//! a model file is a size cost, and fetching a model on first use is a network
//! call this crate must not make. [`SpeechProbability`] therefore states the
//! contract in the terms a neural detector uses — a probability per analysis
//! window — and [`VadBackend`] dispatches over the implementations. Adding a
//! Silero backend later is a new variant plus a new arm; no call site moves,
//! and the pre-roll, hangover, accounting, and configuration below are shared
//! by construction rather than reimplemented.
//!
//! ## What can and cannot be gated
//!
//! Energy is a property of the waveform, so the gate reads the linear-PCM
//! encodings and nothing else. An Opus stream is passed through untouched and
//! reports itself as un-gateable rather than pretending to a saving it is not
//! making.
//!
//! Encoded packet size is the obvious way to gate Opus without a decoder — the
//! pendant encodes with unconstrained VBR, so quiet frames could in principle
//! be smaller — and it was measured against libopus configured exactly as
//! `codec_start()` configures it (16 kHz mono, 20 ms, `RESTRICTED_LOWDELAY`,
//! 32 kbps, VBR unconstrained, complexity 3, `OPUS_SIGNAL_VOICE`, DTX off).
//! The separation is far too weak to gate on:
//!
//! * Room tone encodes to a near-constant 72 bytes per frame whatever its
//!   level, from -70 dBFS to -30 dBFS. Size tracks entropy, not loudness, and
//!   broadband noise is expensive to code however quiet it is.
//! * Speech spans 62 to 160 bytes, and its tenth percentile (64 to 68 bytes)
//!   sits *below* the median silence frame. More than a tenth of speech frames
//!   are smaller than the typical silent one.
//! * Driving the machinery below from an adaptive noise floor and a ratio
//!   trigger, the best suppression available at no worse than 1% speech loss
//!   is 64% in a -50 dBFS room, 29% at -45 dBFS, and nothing at all at -40 dBFS
//!   or above. No single ratio serves a wearer who walks between rooms: the
//!   ratio that is optimal in a quiet room drops 40% of the same speaker's
//!   words once they reach a cafe.
//!
//! Dropping packets is *not* what rules it out — a gated stream decodes to
//! 60 dB SNR against an ungated one, so the codec's inter-frame state survives
//! the gaps. It is the classification that fails, and it fails towards
//! discarding speech, which is the expensive direction.
//!
//! Gating Opus therefore needs a real decoder, which would mean linking libopus
//! into the iOS and Android binaries. That is a size and dependency decision,
//! not a signal-processing one.
//!
//! ## What the device already does
//!
//! The pendant runs its own gate below this one: with
//! `CONFIG_OMI_ENABLE_T5838_AAD`, `aad_track_silence()` sleeps the microphone
//! in hardware after `CONFIG_OMI_VAD_HOLD_MS` (10 s in the shipped build) below
//! `CONFIG_OMI_VAD_ABS_THRESHOLD` (250, about -42 dBFS — within a whisker of
//! the default below), and audio stops flowing entirely until sound wakes it.
//! Silence longer than ten seconds therefore costs nothing already. What
//! reaches this gate is the first ten seconds of each silent run plus every
//! shorter one, which is what bounds the saving actually available here.
//!
//! ## What gating costs
//!
//! A provider counts time in the audio it was given, so removing silence
//! shortens its clock: the `start_ms` and `end_ms` on a
//! [`TranscriptDelta`](crate::signals::TranscriptDelta) are offsets into the
//! audio that was sent, not into the wall-clock recording. They stay internally
//! consistent — a
//! [`TranscriptLocator`](crate::signals::TranscriptLocator) still points at the
//! segment it names — and `occurred_at_ms`, which is the field everything
//! downstream orders by, is a real timestamp taken when the result arrived. Any
//! future consumer that wants elapsed recording time must take it from there
//! rather than from the provider's offsets.

use crate::signals::AudioEncoding;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};

/// Full-scale amplitude for the 16-bit samples every encoding is widened to.
const FULL_SCALE: f32 = 32_768.0;

/// The probability at which the gate opens. Backends are asked to place a
/// window they consider borderline here, which lets the two constants below
/// describe hysteresis in one shared unit no matter which backend answers.
const TRIGGER_PROBABILITY: f32 = 0.5;

/// The probability below which the closing timer runs. Keeping it under
/// [`TRIGGER_PROBABILITY`] is what stops a window hovering at the threshold
/// from switching the gate on and off once per analysis window.
const RELEASE_PROBABILITY: f32 = 0.35;

/// How much audio each analysis window covers. Twenty milliseconds is the
/// frame the pendant itself emits, and it is short enough that the gate reacts
/// within one window of a word starting.
const ANALYSIS_WINDOW_MS: u32 = 20;

/// The default trigger level, in basis points of full scale: 80 bp is an RMS
/// of 0.008, roughly -42 dBFS. Conversational speech reaching a worn pendant
/// sits far above that, while room tone sits below it, so the default errs
/// towards sending audio that might be speech.
///
/// The level it errs at is worth stating plainly: a room whose own tone
/// exceeds -42 dBFS never falls below the threshold, so the gate simply stays
/// open and saves nothing there. Measured against 20 ms frames of pink room
/// tone, 126 frames in 1357 fall below it at -40 dBFS and none at all at
/// -35 dBFS. The saving is therefore large in a quiet room and approaches zero
/// in a loud one — and the failure is always towards transmitting, never
/// towards discarding speech, which is why a fixed threshold is safe to ship
/// even though it is not always useful.
pub(crate) const DEFAULT_THRESHOLD_BASIS_POINTS: u32 = 80;

/// How much audio is retained ahead of a detected onset. Three hundred
/// milliseconds covers both the attack of an unvoiced onset and the one window
/// the detector needs to notice it, with margin to spare.
pub(crate) const DEFAULT_PRE_ROLL_MS: u32 = 300;

/// How long the gate stays open after energy falls away. Pauses between words
/// in continuous speech run to a few hundred milliseconds, so a shorter
/// hangover would fragment ordinary sentences; a longer one would spend more
/// than the silence is worth.
pub(crate) const DEFAULT_HANGOVER_MS: u32 = 600;

/// Bounds on the runtime-settable policy. They exist so a malformed client
/// command cannot turn the gate into either a permanent block or an unbounded
/// buffer.
const MIN_THRESHOLD_BASIS_POINTS: u32 = 1;
const MAX_THRESHOLD_BASIS_POINTS: u32 = 2_000;
const MAX_PRE_ROLL_MS: u32 = 2_000;
const MAX_HANGOVER_MS: u32 = 5_000;

/// The gate is on by default. The saving it exists for is not realized by a
/// setting nobody turns on, and its failure modes are bounded: the pre-roll and
/// hangover above are sized so that clipping requires speech quieter than the
/// room it is spoken in, the client can switch it off at any moment with
/// [`Command::SetVoiceGate`](crate::signals::Command::SetVoiceGate), and an
/// encoding the gate cannot read is passed through rather than guessed at.
static ENABLED: AtomicBool = AtomicBool::new(true);
static THRESHOLD_BASIS_POINTS: AtomicU32 = AtomicU32::new(DEFAULT_THRESHOLD_BASIS_POINTS);
static PRE_ROLL_MS: AtomicU32 = AtomicU32::new(DEFAULT_PRE_ROLL_MS);
static HANGOVER_MS: AtomicU32 = AtomicU32::new(DEFAULT_HANGOVER_MS);

/// The tuning a gate runs under. Sessions re-read it per chunk, so a change
/// reaches audio already in flight instead of waiting for the next session.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct GatePolicy {
    pub(crate) enabled: bool,
    pub(crate) threshold_basis_points: u32,
    pub(crate) pre_roll_ms: u32,
    pub(crate) hangover_ms: u32,
}

impl Default for GatePolicy {
    fn default() -> Self {
        Self {
            enabled: true,
            threshold_basis_points: DEFAULT_THRESHOLD_BASIS_POINTS,
            pre_roll_ms: DEFAULT_PRE_ROLL_MS,
            hangover_ms: DEFAULT_HANGOVER_MS,
        }
    }
}

impl GatePolicy {
    /// The trigger level as a fraction of full scale.
    fn threshold(&self) -> f32 {
        self.threshold_basis_points as f32 / 10_000.0
    }

    /// Clamps every field into the range the gate can honour, so a policy that
    /// reached the hub from outside cannot express a degenerate gate.
    fn clamped(self) -> Self {
        Self {
            enabled: self.enabled,
            threshold_basis_points: self
                .threshold_basis_points
                .clamp(MIN_THRESHOLD_BASIS_POINTS, MAX_THRESHOLD_BASIS_POINTS),
            pre_roll_ms: self.pre_roll_ms.min(MAX_PRE_ROLL_MS),
            hangover_ms: self.hangover_ms.min(MAX_HANGOVER_MS),
        }
    }
}

/// The policy every active audio session currently runs under.
pub(crate) fn policy() -> GatePolicy {
    GatePolicy {
        enabled: ENABLED.load(Ordering::Acquire),
        threshold_basis_points: THRESHOLD_BASIS_POINTS.load(Ordering::Acquire),
        pre_roll_ms: PRE_ROLL_MS.load(Ordering::Acquire),
        hangover_ms: HANGOVER_MS.load(Ordering::Acquire),
    }
}

/// The policy that results from applying a client's request to the one in
/// force. A `None` field leaves that setting at whatever it already is, so a
/// client that only wants the kill switch does not have to restate tuning it
/// never chose, and the result is clamped so what is stored and what the gates
/// read can never disagree.
fn merged(
    current: GatePolicy,
    enabled: bool,
    threshold_basis_points: Option<u32>,
    pre_roll_ms: Option<u32>,
    hangover_ms: Option<u32>,
) -> GatePolicy {
    GatePolicy {
        enabled,
        threshold_basis_points: threshold_basis_points.unwrap_or(current.threshold_basis_points),
        pre_roll_ms: pre_roll_ms.unwrap_or(current.pre_roll_ms),
        hangover_ms: hangover_ms.unwrap_or(current.hangover_ms),
    }
    .clamped()
}

/// Replaces the policy every active and future session runs under, and returns
/// what was actually stored.
pub(crate) fn set_policy(
    enabled: bool,
    threshold_basis_points: Option<u32>,
    pre_roll_ms: Option<u32>,
    hangover_ms: Option<u32>,
) -> GatePolicy {
    let updated = merged(
        policy(),
        enabled,
        threshold_basis_points,
        pre_roll_ms,
        hangover_ms,
    );
    ENABLED.store(updated.enabled, Ordering::Release);
    THRESHOLD_BASIS_POINTS.store(updated.threshold_basis_points, Ordering::Release);
    PRE_ROLL_MS.store(updated.pre_roll_ms, Ordering::Release);
    HANGOVER_MS.store(updated.hangover_ms, Ordering::Release);
    updated
}

/// A voice-activity detector, stated the way a neural detector states itself:
/// given one window of interleaved 16-bit samples, how likely is it to carry
/// speech. Everything around the answer — retaining the run-up, riding out
/// pauses, counting what was saved — belongs to [`SpeechGate`], so a second
/// implementation only has to answer this one question.
pub(crate) trait SpeechProbability {
    /// The analysis window this detector wants, in milliseconds. The gate
    /// converts it to samples using the stream's own format, so a detector
    /// with a fixed sample count states the duration that yields it at the
    /// rate it was trained on and resamples the rest itself.
    fn window_ms(&self) -> u32;

    /// Scores one window. `sample_rate_hz` is the stream's rate, which a
    /// detector trained at a fixed rate needs in order to resample.
    fn probability(&mut self, window: &[i16], sample_rate_hz: u32) -> f32;

    /// Takes whatever the new policy means for this detector.
    fn retune(&mut self, policy: GatePolicy);

    /// Drops any state carried between windows, for a stream that is starting
    /// over rather than continuing.
    fn reset(&mut self);
}

/// The detectors the hub can gate with. A Silero variant belongs here; adding
/// it changes this enum and its delegating impl, and nothing else.
pub(crate) enum VadBackend {
    Energy(EnergyBackend),
}

impl SpeechProbability for VadBackend {
    fn window_ms(&self) -> u32 {
        match self {
            Self::Energy(backend) => backend.window_ms(),
        }
    }

    fn probability(&mut self, window: &[i16], sample_rate_hz: u32) -> f32 {
        match self {
            Self::Energy(backend) => backend.probability(window, sample_rate_hz),
        }
    }

    fn retune(&mut self, policy: GatePolicy) {
        match self {
            Self::Energy(backend) => backend.retune(policy),
        }
    }

    fn reset(&mut self) {
        match self {
            Self::Energy(backend) => backend.reset(),
        }
    }
}

/// Root-mean-square loudness against a fixed threshold.
///
/// The score is the window's RMS expressed as a multiple of the threshold and
/// scaled so that a window sitting exactly on the threshold scores
/// [`TRIGGER_PROBABILITY`]. That mapping is what lets an energy measurement and
/// a neural probability share one hysteresis: the release level below the
/// trigger becomes a fixed fraction of the threshold in amplitude terms, which
/// is the conventional few decibels of margin an energy gate needs.
pub(crate) struct EnergyBackend {
    threshold: f32,
}

impl EnergyBackend {
    fn new(policy: GatePolicy) -> Self {
        Self {
            threshold: policy.threshold(),
        }
    }
}

impl SpeechProbability for EnergyBackend {
    fn window_ms(&self) -> u32 {
        ANALYSIS_WINDOW_MS
    }

    fn probability(&mut self, window: &[i16], _sample_rate_hz: u32) -> f32 {
        if window.is_empty() || self.threshold <= 0.0 {
            return 0.0;
        }
        let mean_square = window
            .iter()
            .map(|sample| {
                let normalized = f32::from(*sample) / FULL_SCALE;
                normalized * normalized
            })
            .sum::<f32>()
            / window.len() as f32;
        (mean_square.sqrt() / self.threshold * TRIGGER_PROBABILITY).min(1.0)
    }

    fn retune(&mut self, policy: GatePolicy) {
        self.threshold = policy.threshold();
    }

    fn reset(&mut self) {}
}

/// The two-level state machine that turns a stream of per-window probabilities
/// into a gate that opens promptly and closes reluctantly.
///
/// Opening takes one window above the trigger. Closing takes a continuous run
/// below the release level lasting the whole hangover: the moment the first
/// quiet window arrives the clock starts, and any window back above the trigger
/// cancels it. Without the cancel, a gap between two words would count towards
/// closing even though speech resumed.
struct Hysteresis {
    hangover_samples: u64,
    open: bool,
    quiet_since: Option<u64>,
    processed_samples: u64,
}

impl Hysteresis {
    fn new(hangover_samples: u64) -> Self {
        Self {
            hangover_samples,
            open: false,
            quiet_since: None,
            processed_samples: 0,
        }
    }

    fn set_hangover(&mut self, hangover_samples: u64) {
        self.hangover_samples = hangover_samples;
    }

    fn reset(&mut self) {
        self.open = false;
        self.quiet_since = None;
        self.processed_samples = 0;
    }

    /// Folds one scored window in and reports whether the gate is open after
    /// it. `window_samples` is what advances the hangover clock, which keeps
    /// the timing in units of audio rather than of wall-clock delivery.
    fn observe(&mut self, probability: f32, window_samples: usize) -> bool {
        self.processed_samples = self.processed_samples.saturating_add(window_samples as u64);
        if probability >= TRIGGER_PROBABILITY {
            self.quiet_since = None;
            self.open = true;
        } else if probability < RELEASE_PROBABILITY && self.open {
            let quiet_since = *self.quiet_since.get_or_insert(self.processed_samples);
            if self.processed_samples.saturating_sub(quiet_since) >= self.hangover_samples {
                self.quiet_since = None;
                self.open = false;
            }
        }
        self.open
    }
}

/// The linear-PCM layout of a stream the gate can read.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct PcmFormat {
    sample_bytes: usize,
    sample_rate_hz: u32,
    channels: usize,
}

impl PcmFormat {
    /// The layout of `encoding`, or `None` when the encoding is not linear PCM
    /// and so carries no loudness the gate can read without decoding it.
    fn new(encoding: AudioEncoding, sample_rate_hz: u32, channels: u8) -> Option<Self> {
        let sample_bytes = match encoding {
            AudioEncoding::PcmS16Le => 2,
            AudioEncoding::PcmU8 => 1,
            AudioEncoding::Opus => return None,
        };
        Some(Self {
            sample_bytes,
            sample_rate_hz: sample_rate_hz.max(1),
            channels: usize::from(channels).max(1),
        })
    }

    /// One sample of every channel: the smallest run of bytes the stream can
    /// be cut on without shifting which channel a sample belongs to.
    fn frame_bytes(&self) -> usize {
        self.sample_bytes * self.channels
    }

    /// Interleaved samples per millisecond, which is the unit the analysis
    /// window and the hangover are both measured in.
    fn samples_per_ms(&self) -> u64 {
        u64::from(self.sample_rate_hz) * self.channels as u64 / 1_000
    }

    fn ms_to_bytes(&self, ms: u32) -> usize {
        (u64::from(ms) * self.samples_per_ms()) as usize * self.sample_bytes
    }

    fn bytes_to_ms(&self, bytes: u64) -> u64 {
        let per_ms = self.samples_per_ms() * self.sample_bytes as u64;
        if per_ms == 0 {
            return 0;
        }
        bytes / per_ms
    }
}

/// What the caller should do with the chunk it just offered.
#[derive(Debug, Eq, PartialEq)]
pub(crate) enum GateDecision {
    /// Send the chunk as it stands.
    Pass,
    /// Send these retained bytes first, then the chunk. This is the onset
    /// case: the retained audio is the run-up that the gate held back and that
    /// the provider needs in order to transcribe the first word whole.
    PassWithPreRoll(Vec<u8>),
    /// Drop the chunk; it is silence the provider would be paid to ignore.
    Suppress,
}

/// What a gate has kept off the wire, in bytes that were offered to it.
///
/// A byte counts as suppressed only once it has left the pre-roll ring without
/// being sent, so audio still eligible for a pre-roll flush is in neither
/// total. That is what makes the two figures add up to a real saving rather
/// than to an optimistic one.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct GateStats {
    pub(crate) forwarded_bytes: u64,
    pub(crate) suppressed_bytes: u64,
}

/// The gate for one audio stream.
///
/// It is deliberately synchronous and owns no I/O: it is handed the bytes a
/// session accepted and answers what to do with them, which keeps the decision
/// testable and keeps the accounting next to the decision that produced it.
pub(crate) struct SpeechGate {
    policy: GatePolicy,
    format: Option<PcmFormat>,
    backend: VadBackend,
    hysteresis: Hysteresis,
    window_samples: usize,
    pending: Vec<i16>,
    scratch: Vec<i16>,
    /// A 16-bit sample split across two chunks. Dropping it would rotate every
    /// following sample by one byte and turn speech into noise.
    carry: Option<u8>,
    pre_roll: VecDeque<u8>,
    pre_roll_capacity: usize,
    stats: GateStats,
}

impl SpeechGate {
    pub(crate) fn new(
        policy: GatePolicy,
        encoding: AudioEncoding,
        sample_rate_hz: u32,
        channels: u8,
    ) -> Self {
        let policy = policy.clamped();
        let format = PcmFormat::new(encoding, sample_rate_hz, channels);
        let backend = VadBackend::Energy(EnergyBackend::new(policy));
        let window_samples = format.map_or(0, |format| {
            (u64::from(backend.window_ms()) * format.samples_per_ms()).max(1) as usize
        });
        let hangover_samples = format.map_or(0, |format| {
            u64::from(policy.hangover_ms) * format.samples_per_ms()
        });
        let pre_roll_capacity = format.map_or(0, |format| format.ms_to_bytes(policy.pre_roll_ms));
        Self {
            policy,
            format,
            backend,
            hysteresis: Hysteresis::new(hangover_samples),
            window_samples,
            pending: Vec::with_capacity(window_samples),
            scratch: Vec::with_capacity(window_samples),
            carry: None,
            pre_roll: VecDeque::with_capacity(pre_roll_capacity),
            pre_roll_capacity,
            stats: GateStats::default(),
        }
    }

    /// Whether this stream's encoding is one the gate can read at all. A
    /// stream that answers `false` is passed through in full, and says so
    /// rather than reporting a saving of zero as if it had gated successfully.
    pub(crate) fn gateable(&self) -> bool {
        self.format.is_some()
    }

    pub(crate) fn enabled(&self) -> bool {
        self.policy.enabled
    }

    pub(crate) fn stats(&self) -> GateStats {
        self.stats
    }

    /// How much audio a byte count represents, for reporting a saving in the
    /// unit a metered session is actually billed in.
    pub(crate) fn bytes_to_ms(&self, bytes: u64) -> u64 {
        self.format.map_or(0, |format| format.bytes_to_ms(bytes))
    }

    /// Adopts a policy change mid-stream. Switching the gate off flushes what
    /// it was holding on the next chunk instead of discarding it, so toggling
    /// the setting never costs the user audio.
    pub(crate) fn set_policy(&mut self, policy: GatePolicy) {
        let policy = policy.clamped();
        if policy == self.policy {
            return;
        }
        let was_enabled = self.policy.enabled;
        self.policy = policy;
        self.backend.retune(policy);
        if let Some(format) = self.format {
            self.hysteresis
                .set_hangover(u64::from(policy.hangover_ms) * format.samples_per_ms());
            self.pre_roll_capacity = format.ms_to_bytes(policy.pre_roll_ms);
            self.trim_pre_roll();
        }
        if was_enabled && !policy.enabled {
            self.backend.reset();
            self.hysteresis.reset();
            self.pending.clear();
            self.carry = None;
        }
    }

    /// Offers one chunk of a stream and answers what to send.
    pub(crate) fn observe(&mut self, bytes: &[u8]) -> GateDecision {
        let Some(format) = self.format.filter(|_| self.policy.enabled) else {
            return self.open(bytes.len());
        };
        self.decode(format, bytes);
        if self.drain_windows(format) {
            return self.open(bytes.len());
        }
        self.retain(bytes);
        GateDecision::Suppress
    }

    /// Ends the stream's accounting: audio still held back was never sent and
    /// now never will be, so it belongs in the suppressed total.
    pub(crate) fn finish(&mut self) {
        self.stats.suppressed_bytes = self
            .stats
            .suppressed_bytes
            .saturating_add(self.pre_roll.len() as u64);
        self.pre_roll.clear();
    }

    /// Counts a chunk as sent, along with any retained run-up that goes ahead
    /// of it.
    fn open(&mut self, chunk_bytes: usize) -> GateDecision {
        let pre_roll: Vec<u8> = self.pre_roll.drain(..).collect();
        self.stats.forwarded_bytes = self
            .stats
            .forwarded_bytes
            .saturating_add((chunk_bytes + pre_roll.len()) as u64);
        if pre_roll.is_empty() {
            GateDecision::Pass
        } else {
            GateDecision::PassWithPreRoll(pre_roll)
        }
    }

    /// Holds a suppressed chunk in the pre-roll ring so an onset in the next
    /// one can still be transcribed from its beginning.
    fn retain(&mut self, bytes: &[u8]) {
        self.pre_roll.extend(bytes.iter().copied());
        self.trim_pre_roll();
    }

    /// Drops the oldest audio once the ring is over its window. Trimming is
    /// rounded up to whole frames: cutting mid-frame would rotate the channel
    /// order of everything the ring later flushes.
    fn trim_pre_roll(&mut self) {
        let Some(format) = self.format else {
            return;
        };
        if self.pre_roll.len() <= self.pre_roll_capacity {
            return;
        }
        let excess = self.pre_roll.len() - self.pre_roll_capacity;
        let frame = format.frame_bytes().max(1);
        let trim = excess
            .div_ceil(frame)
            .saturating_mul(frame)
            .min(self.pre_roll.len());
        self.pre_roll.drain(..trim);
        self.stats.suppressed_bytes = self.stats.suppressed_bytes.saturating_add(trim as u64);
    }

    /// Widens the chunk's bytes to 16-bit samples for analysis, carrying a
    /// split sample across the chunk boundary.
    fn decode(&mut self, format: PcmFormat, bytes: &[u8]) {
        if format.sample_bytes == 1 {
            self.pending.extend(
                bytes
                    .iter()
                    .map(|byte| (i16::from(*byte) - 128).saturating_mul(256)),
            );
            return;
        }
        let mut rest = bytes;
        if let Some(low) = self.carry.take() {
            match rest.split_first() {
                Some((high, tail)) => {
                    self.pending.push(i16::from_le_bytes([low, *high]));
                    rest = tail;
                }
                None => self.carry = Some(low),
            }
        }
        let mut pairs = rest.chunks_exact(2);
        for pair in &mut pairs {
            self.pending.push(i16::from_le_bytes([pair[0], pair[1]]));
        }
        self.carry = pairs.remainder().first().copied();
    }

    /// Scores every complete window the chunk produced and reports whether the
    /// gate was open at any point during it.
    ///
    /// A chunk that straddles the onset is sent whole rather than split at the
    /// window that crossed the threshold: the pre-roll already covers far more
    /// history than one chunk, so splitting would add arithmetic without
    /// saving audio worth keeping.
    fn drain_windows(&mut self, format: PcmFormat) -> bool {
        let mut open = self.hysteresis.open;
        let target = self.window_samples.max(1);
        while self.pending.len() >= target {
            self.scratch.clear();
            self.scratch.extend_from_slice(&self.pending[..target]);
            self.pending.drain(..target);
            let probability = self
                .backend
                .probability(&self.scratch, format.sample_rate_hz);
            if self.hysteresis.observe(probability, target) {
                open = true;
            }
        }
        open
    }
}

#[cfg(test)]
mod tests {
    use super::{
        DEFAULT_HANGOVER_MS, DEFAULT_PRE_ROLL_MS, GateDecision, GatePolicy, MAX_HANGOVER_MS,
        MAX_PRE_ROLL_MS, MAX_THRESHOLD_BASIS_POINTS, SpeechGate,
    };
    use crate::signals::AudioEncoding;

    const RATE: u32 = 16_000;

    /// Bytes of 16-bit mono audio at `amplitude`, alternating sign so the
    /// window has the RMS of a square wave rather than a constant offset.
    fn pcm16(amplitude: i16, ms: u32) -> Vec<u8> {
        let samples = (RATE as usize) * ms as usize / 1_000;
        (0..samples)
            .flat_map(|index| {
                let value = if index % 2 == 0 {
                    amplitude
                } else {
                    -amplitude
                };
                value.to_le_bytes()
            })
            .collect()
    }

    fn silence(ms: u32) -> Vec<u8> {
        pcm16(0, ms)
    }

    fn speech(ms: u32) -> Vec<u8> {
        pcm16(6_000, ms)
    }

    fn gate(policy: GatePolicy) -> SpeechGate {
        SpeechGate::new(policy, AudioEncoding::PcmS16Le, RATE, 1)
    }

    #[test]
    fn silence_is_suppressed_and_speech_opens_the_gate() {
        let mut gate = gate(GatePolicy::default());
        for _ in 0..10 {
            assert_eq!(gate.observe(&silence(20)), GateDecision::Suppress);
        }
        assert!(matches!(
            gate.observe(&speech(20)),
            GateDecision::PassWithPreRoll(_)
        ));
        assert_eq!(gate.observe(&speech(20)), GateDecision::Pass);
    }

    #[test]
    fn the_pre_roll_flush_carries_the_run_up_to_the_first_word() {
        let mut gate = gate(GatePolicy::default());
        // Far more silence than the ring can hold, so the flush is the window
        // and not merely everything that happened to be buffered.
        for _ in 0..100 {
            assert_eq!(gate.observe(&silence(20)), GateDecision::Suppress);
        }
        let GateDecision::PassWithPreRoll(pre_roll) = gate.observe(&speech(20)) else {
            panic!("speech after silence must flush the pre-roll");
        };
        assert_eq!(pre_roll.len(), silence(DEFAULT_PRE_ROLL_MS).len());
        // The retained audio precedes the chunk that opened the gate, so what
        // reaches the provider starts before the onset rather than at it.
        assert!(pre_roll.iter().all(|byte| *byte == 0));
    }

    #[test]
    fn a_short_pause_inside_an_utterance_does_not_close_the_gate() {
        let mut gate = gate(GatePolicy::default());
        assert!(matches!(gate.observe(&speech(40)), GateDecision::Pass));
        // A pause well inside the hangover keeps the utterance whole.
        let pause = DEFAULT_HANGOVER_MS / 2;
        assert_eq!(gate.observe(&silence(pause)), GateDecision::Pass);
        assert_eq!(gate.observe(&speech(20)), GateDecision::Pass);
    }

    #[test]
    fn the_gate_closes_once_the_hangover_has_elapsed() {
        let mut gate = gate(GatePolicy::default());
        assert!(matches!(gate.observe(&speech(40)), GateDecision::Pass));
        assert_eq!(
            gate.observe(&silence(
                DEFAULT_HANGOVER_MS + 2 * super::ANALYSIS_WINDOW_MS
            )),
            GateDecision::Pass
        );
        assert_eq!(gate.observe(&silence(20)), GateDecision::Suppress);
    }

    #[test]
    fn a_disabled_gate_forwards_everything() {
        let mut gate = gate(GatePolicy {
            enabled: false,
            ..GatePolicy::default()
        });
        for _ in 0..50 {
            assert_eq!(gate.observe(&silence(20)), GateDecision::Pass);
        }
        gate.finish();
        assert_eq!(gate.stats().suppressed_bytes, 0);
        assert_eq!(gate.stats().forwarded_bytes, 50 * silence(20).len() as u64);
    }

    #[test]
    fn disabling_the_gate_mid_stream_releases_what_it_was_holding() {
        let mut gate = gate(GatePolicy::default());
        assert_eq!(gate.observe(&silence(100)), GateDecision::Suppress);
        gate.set_policy(GatePolicy {
            enabled: false,
            ..GatePolicy::default()
        });
        let GateDecision::PassWithPreRoll(pre_roll) = gate.observe(&silence(20)) else {
            panic!("disabling the gate must release the retained audio");
        };
        assert_eq!(pre_roll.len(), silence(100).len());
    }

    #[test]
    fn an_encoding_the_gate_cannot_read_is_passed_through() {
        let mut gate = SpeechGate::new(GatePolicy::default(), AudioEncoding::Opus, RATE, 1);
        assert!(!gate.gateable());
        assert_eq!(gate.observe(&[1, 2, 3, 4]), GateDecision::Pass);
        gate.finish();
        assert_eq!(gate.stats().suppressed_bytes, 0);
        assert_eq!(gate.stats().forwarded_bytes, 4);
    }

    #[test]
    fn eight_bit_silence_sits_at_the_encoding_midpoint() {
        let mut gate = SpeechGate::new(GatePolicy::default(), AudioEncoding::PcmU8, RATE, 1);
        // 128 is zero amplitude in unsigned 8-bit PCM; reading it as a raw
        // magnitude would score it as the loudest possible audio.
        assert_eq!(gate.observe(&[128; 640]), GateDecision::Suppress);
        assert!(matches!(
            gate.observe(&[250; 640]),
            GateDecision::PassWithPreRoll(_)
        ));
    }

    #[test]
    fn a_sample_split_across_two_chunks_is_not_lost() {
        let mut gate = gate(GatePolicy::default());
        let loud = speech(40);
        let (head, tail) = loud.split_at(21);
        assert_eq!(gate.observe(head), GateDecision::Suppress);
        // Reading the tail one byte out of phase would turn the same audio
        // into noise, and the gate would still open; what proves the carry
        // works is that the samples reassemble, which the stats show by
        // counting the whole utterance as sent.
        assert!(matches!(
            gate.observe(tail),
            GateDecision::PassWithPreRoll(_)
        ));
        assert_eq!(gate.stats().forwarded_bytes, loud.len() as u64);
        assert_eq!(gate.stats().suppressed_bytes, 0);
    }

    #[test]
    fn only_audio_that_never_left_counts_as_suppressed() {
        let mut gate = gate(GatePolicy::default());
        let quiet = silence(1_000);
        assert_eq!(gate.observe(&quiet), GateDecision::Suppress);
        let retained = silence(DEFAULT_PRE_ROLL_MS).len() as u64;
        // What is still eligible for a flush is in neither total yet.
        assert_eq!(gate.stats().suppressed_bytes, quiet.len() as u64 - retained);
        assert_eq!(gate.stats().forwarded_bytes, 0);
        let loud = speech(20);
        assert!(matches!(
            gate.observe(&loud),
            GateDecision::PassWithPreRoll(_)
        ));
        assert_eq!(gate.stats().forwarded_bytes, retained + loud.len() as u64);
        assert_eq!(gate.stats().suppressed_bytes, quiet.len() as u64 - retained);
    }

    #[test]
    fn a_policy_from_outside_cannot_express_a_degenerate_gate() {
        let mut gate = gate(GatePolicy::default());
        gate.set_policy(GatePolicy {
            enabled: true,
            threshold_basis_points: u32::MAX,
            pre_roll_ms: u32::MAX,
            hangover_ms: u32::MAX,
        });
        assert_eq!(
            gate.policy.threshold_basis_points,
            MAX_THRESHOLD_BASIS_POINTS
        );
        assert_eq!(gate.policy.pre_roll_ms, MAX_PRE_ROLL_MS);
        assert_eq!(gate.policy.hangover_ms, MAX_HANGOVER_MS);
        // A zero threshold would open the gate on pure silence, so it is
        // clamped away from zero rather than accepted.
        gate.set_policy(GatePolicy {
            threshold_basis_points: 0,
            ..GatePolicy::default()
        });
        assert!(gate.policy.threshold_basis_points > 0);
        assert_eq!(gate.observe(&silence(100)), GateDecision::Suppress);
    }

    #[test]
    fn an_unstated_setting_keeps_the_value_it_already_had() {
        let current = GatePolicy {
            enabled: true,
            threshold_basis_points: 120,
            pre_roll_ms: 250,
            hangover_ms: 400,
        };
        // A client that only wants the kill switch states only the kill
        // switch; the tuning someone else chose has to survive that.
        let toggled = super::merged(current, false, None, None, None);
        assert_eq!(
            toggled,
            GatePolicy {
                enabled: false,
                ..current
            }
        );
        let retuned = super::merged(current, true, Some(40), None, Some(900));
        assert_eq!(
            retuned,
            GatePolicy {
                enabled: true,
                threshold_basis_points: 40,
                pre_roll_ms: 250,
                hangover_ms: 900,
            }
        );
    }
}
