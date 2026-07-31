//! The on-device speaker-embedding model behind
//! [`crate::speech_profiles::EmbeddingSource`].
//!
//! Inference runs through `tract` (MIT OR Apache-2.0), a pure-Rust ONNX
//! interpreter, deliberately in preference to an ONNX Runtime binding: no C++
//! toolchain, no build-time download, no dynamic library to ship per platform,
//! and nothing that can reach the network at any point in this file.
//!
//! # What must be supplied
//!
//! No weights live in this repository and none are fetched. The caller points
//! [`resolve_embedding_source`] at a path; if a readable, loadable ONNX file is
//! there it is used, and otherwise the fail-closed
//! [`crate::speech_profiles::NullEmbeddingSource`] is returned so the feature
//! degrades to "off" rather than to guessing.
//!
//! # The input contract
//!
//! ECAPA-TDNN speaker encoders are exported in two shapes and which one a given
//! file wants cannot be known until it is opened, so both are supported and the
//! choice is made from the model's own declared input rank:
//!
//! * **Rank 2 — raw waveform, `[1, samples]`.** The model carries its own
//!   filterbank front end. The PCM is handed over as `f32` in `-1.0..=1.0`
//!   (`i16 / 32768.0`), resampled to 16 kHz, with no windowing applied here.
//! * **Rank 3 — precomputed log-mel filterbank.** Either `[1, frames, bins]` or
//!   `[1, bins, frames]`; the layout is taken from whichever of the two trailing
//!   dimensions the model declares concretely, defaulting to `[1, frames, 80]`
//!   when neither is fixed. The features are produced by [`fbank`] below.
//!
//! Any other rank is refused at load time rather than at the first meeting.
//!
//! The filterbank parameters follow the SpeechBrain ECAPA-TDNN recipe, which is
//! what the commonly exported checkpoints were trained with: 16 kHz mono,
//! 25 ms frames (400 samples) every 10 ms (160 samples), 512-point FFT, Hamming
//! window, 80 triangular mel bands spanning 20 Hz–7600 Hz, natural-log
//! magnitudes, and per-utterance mean normalization ("sentence" norm). A model
//! trained with different conventions will load and run and return numbers that
//! are quietly wrong, so a supplied file must match this recipe.

use crate::speech_profiles::{
    EmbeddingError, EmbeddingSource, NullEmbeddingSource, SpeakerEmbedding,
};
use std::f32::consts::PI;
use std::path::Path;
use std::sync::Arc;
use tract_onnx::prelude::{
    Datum, Framework, InferenceFact, InferenceModelExt, IntoRunnable, SymbolValues, Tensor, ToDim,
    TypedRunnableModel, tvec,
};
use tract_onnx::tract_hir::infer::{Factoid, ShapeFactoid};

/// The rate every model here is fed at.
pub const TARGET_SAMPLE_RATE_HZ: u32 = 16_000;
/// Analysis window, 25 ms at [`TARGET_SAMPLE_RATE_HZ`].
pub const FRAME_LENGTH: usize = 400;
/// Hop between windows, 10 ms at [`TARGET_SAMPLE_RATE_HZ`].
pub const FRAME_SHIFT: usize = 160;
/// FFT size: the first power of two at or above [`FRAME_LENGTH`].
pub const FFT_SIZE: usize = 512;
/// Triangular mel bands produced by [`fbank`].
pub const MEL_BINS: usize = 80;
/// Low edge of the mel range, in hertz.
pub const MEL_LOW_HZ: f32 = 20.0;
/// High edge of the mel range, in hertz.
pub const MEL_HIGH_HZ: f32 = 7_600.0;

const LOG_FLOOR: f32 = 1e-10;

/// Which of the two export conventions a loaded model follows.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ModelInput {
    /// `[1, samples]`, front end inside the graph.
    Waveform,
    /// `[1, frames, bins]`.
    FbankTimeMajor { bins: usize },
    /// `[1, bins, frames]`.
    FbankBinMajor { bins: usize },
}

/// One log-mel filterbank, row-major over frames.
#[derive(Clone, Debug, PartialEq)]
pub struct Fbank {
    frames: usize,
    bins: usize,
    values: Vec<f32>,
}

impl Fbank {
    pub fn frames(&self) -> usize {
        self.frames
    }

    pub fn bins(&self) -> usize {
        self.bins
    }

    /// `frames * bins` values, frame-major.
    pub fn values(&self) -> &[f32] {
        &self.values
    }
}

/// A speaker encoder loaded from an ONNX file on disk.
pub struct TractEmbeddingSource {
    plan: Arc<TypedRunnableModel>,
    input: ModelInput,
}

impl TractEmbeddingSource {
    /// Opens and optimizes the model at `path`.
    ///
    /// Every failure — missing file, unreadable bytes, a graph tract cannot
    /// lower, an input rank this module does not speak — becomes
    /// [`EmbeddingError::Unavailable`], the same answer the null source gives,
    /// because from the matcher's point of view they are the same situation:
    /// there is no usable model. Nothing here panics.
    pub fn load(path: &Path) -> Result<Self, EmbeddingError> {
        let model = tract_onnx::onnx()
            .model_for_path(path)
            .map_err(|_| EmbeddingError::Unavailable)?;
        let fact = model
            .input_fact(0)
            .map_err(|_| EmbeddingError::Unavailable)?;
        let input = classify_input(&fact.shape).ok_or(EmbeddingError::Unavailable)?;
        let length = model.sym("length");
        let shape: ShapeFactoid = match input {
            ModelInput::Waveform => vec![1.to_dim(), length.to_dim()].into(),
            ModelInput::FbankTimeMajor { bins } => {
                vec![1.to_dim(), length.to_dim(), bins.to_dim()].into()
            }
            ModelInput::FbankBinMajor { bins } => {
                vec![1.to_dim(), bins.to_dim(), length.to_dim()].into()
            }
        };
        let plan = model
            .with_input_fact(0, InferenceFact::dt_shape(f32::datum_type(), shape))
            .and_then(InferenceModelExt::into_optimized)
            .and_then(IntoRunnable::into_runnable)
            .map_err(|_| EmbeddingError::Unavailable)?;
        Ok(Self { plan, input })
    }

    /// Which export convention this file follows.
    pub fn model_input(&self) -> ModelInput {
        self.input
    }

    fn tensor_for(&self, samples: &[f32]) -> Result<Tensor, EmbeddingError> {
        match self.input {
            ModelInput::Waveform => {
                Tensor::from_shape(&[1, samples.len()], samples).map_err(|_| tensor_refused())
            }
            ModelInput::FbankTimeMajor { bins } => {
                let features = fbank(samples, bins)?;
                Tensor::from_shape(&[1, features.frames, bins], &features.values)
                    .map_err(|_| tensor_refused())
            }
            ModelInput::FbankBinMajor { bins } => {
                let features = fbank(samples, bins)?;
                Tensor::from_shape(&[1, bins, features.frames], &transpose(&features))
                    .map_err(|_| tensor_refused())
            }
        }
    }
}

impl EmbeddingSource for TractEmbeddingSource {
    fn embed(&self, pcm: &[i16], sample_rate: u32) -> Result<SpeakerEmbedding, EmbeddingError> {
        let samples = resample_to_target(pcm, sample_rate)?;
        let tensor = self.tensor_for(&samples)?;
        let outputs = self
            .plan
            .run(tvec!(tensor.into()))
            .map_err(|_| EmbeddingError::Degenerate)?;
        let first: &Tensor = outputs.first().ok_or(EmbeddingError::Degenerate)?;
        let view = first.view();
        let values = view
            .as_slice::<f32>()
            .map_err(|_| EmbeddingError::Degenerate)?;
        SpeakerEmbedding::new(values.to_vec())
    }
}

/// The source the app should use: the real model when `path` holds one that
/// loads, and the fail-closed null source otherwise.
pub fn resolve_embedding_source(path: &Path) -> Box<dyn EmbeddingSource> {
    match TractEmbeddingSource::load(path) {
        Ok(source) => Box::new(source),
        Err(_) => Box::new(NullEmbeddingSource),
    }
}

/// How many frames [`fbank`] yields for `samples` inputs. Kaldi's `snip_edges`
/// convention: no frame is padded, so a tail shorter than a window is dropped.
pub fn frame_count(samples: usize) -> usize {
    if samples < FRAME_LENGTH {
        return 0;
    }
    1 + (samples - FRAME_LENGTH) / FRAME_SHIFT
}

/// The log-mel filterbank described in the module header.
///
/// Deterministic: no dither, no randomness, and the same input always produces
/// the same bytes.
pub fn fbank(samples: &[f32], bins: usize) -> Result<Fbank, EmbeddingError> {
    let frames = frame_count(samples.len());
    if frames == 0 || bins == 0 {
        return Err(EmbeddingError::TooShort {
            have_ms: 0,
            need_ms: crate::speech_profiles::MIN_EMBEDDING_MS,
        });
    }
    let window = hamming_window();
    let filters = mel_filters(bins);
    let mut values = vec![0.0_f32; frames * bins];
    let mut real = vec![0.0_f32; FFT_SIZE];
    let mut imaginary = vec![0.0_f32; FFT_SIZE];
    let mut power = vec![0.0_f32; FFT_SIZE / 2 + 1];
    for frame in 0..frames {
        let start = frame * FRAME_SHIFT;
        let slice = samples.get(start..start + FRAME_LENGTH).unwrap_or_default();
        real.fill(0.0);
        imaginary.fill(0.0);
        let mean = slice.iter().sum::<f32>() / FRAME_LENGTH as f32;
        let mut previous = 0.0_f32;
        for (index, (target, (sample, weight))) in real
            .iter_mut()
            .zip(slice.iter().zip(window.iter()))
            .enumerate()
        {
            let centered = sample - mean;
            let emphasized = if index == 0 {
                centered * (1.0 - PREEMPHASIS)
            } else {
                centered - PREEMPHASIS * previous
            };
            previous = centered;
            *target = emphasized * weight;
        }
        fft_in_place(&mut real, &mut imaginary);
        for (bin, slot) in power.iter_mut().enumerate() {
            let re = real.get(bin).copied().unwrap_or_default();
            let im = imaginary.get(bin).copied().unwrap_or_default();
            *slot = re * re + im * im;
        }
        for (band, filter) in filters.iter().enumerate() {
            let energy: f32 = filter
                .iter()
                .map(|&(bin, weight)| power.get(bin).copied().unwrap_or_default() * weight)
                .sum();
            if let Some(slot) = values.get_mut(frame * bins + band) {
                *slot = energy.max(LOG_FLOOR).ln();
            }
        }
    }
    apply_sentence_norm(&mut values, frames, bins);
    Ok(Fbank {
        frames,
        bins,
        values,
    })
}

const PREEMPHASIS: f32 = 0.97;

/// `i16` PCM to `f32` in `-1.0..=1.0` at [`TARGET_SAMPLE_RATE_HZ`].
///
/// Division by 32768 rather than 32767 keeps the mapping linear and symmetric,
/// which is what every training front end in this family assumes. Rate
/// conversion is linear interpolation: the caller's audio is already band
/// limited by the capture device, and speaker embeddings are far more sensitive
/// to the spectral envelope than to interpolation error.
pub fn resample_to_target(pcm: &[i16], sample_rate: u32) -> Result<Vec<f32>, EmbeddingError> {
    if sample_rate == 0 {
        return Err(EmbeddingError::UnsupportedSampleRate(sample_rate));
    }
    let scaled: Vec<f32> = pcm
        .iter()
        .map(|&value| f32::from(value) / 32_768.0)
        .collect();
    if sample_rate == TARGET_SAMPLE_RATE_HZ {
        return Ok(scaled);
    }
    let ratio = f64::from(TARGET_SAMPLE_RATE_HZ) / f64::from(sample_rate);
    let target_len = ((scaled.len() as f64) * ratio).floor() as usize;
    let mut out = Vec::with_capacity(target_len);
    for index in 0..target_len {
        let position = index as f64 / ratio;
        let left = position.floor() as usize;
        let fraction = (position - position.floor()) as f32;
        let first = scaled.get(left).copied().unwrap_or_default();
        let second = scaled.get(left + 1).copied().unwrap_or(first);
        out.push(first + (second - first) * fraction);
    }
    Ok(out)
}

fn tensor_refused() -> EmbeddingError {
    EmbeddingError::Degenerate
}

fn classify_input(shape: &ShapeFactoid) -> Option<ModelInput> {
    let rank = usize::try_from(shape.rank().concretize()?).ok()?;
    match rank {
        2 => Some(ModelInput::Waveform),
        3 => {
            let trailing = concrete_dim(shape, 2);
            let middle = concrete_dim(shape, 1);
            match (middle, trailing) {
                (_, Some(bins)) => Some(ModelInput::FbankTimeMajor { bins }),
                (Some(bins), None) => Some(ModelInput::FbankBinMajor { bins }),
                (None, None) => Some(ModelInput::FbankTimeMajor { bins: MEL_BINS }),
            }
        }
        _ => None,
    }
}

fn concrete_dim(shape: &ShapeFactoid, index: usize) -> Option<usize> {
    let dim = shape.dim(index)?.concretize()?;
    let value = dim.eval(&SymbolValues::default()).to_i64().ok()?;
    usize::try_from(value).ok().filter(|&value| value > 1)
}

fn transpose(features: &Fbank) -> Vec<f32> {
    let mut out = vec![0.0_f32; features.frames * features.bins];
    for frame in 0..features.frames {
        for bin in 0..features.bins {
            if let (Some(slot), Some(value)) = (
                out.get_mut(bin * features.frames + frame),
                features.values.get(frame * features.bins + bin),
            ) {
                *slot = *value;
            }
        }
    }
    out
}

fn apply_sentence_norm(values: &mut [f32], frames: usize, bins: usize) {
    for bin in 0..bins {
        let mut total = 0.0_f32;
        for frame in 0..frames {
            total += values.get(frame * bins + bin).copied().unwrap_or_default();
        }
        let mean = total / frames as f32;
        for frame in 0..frames {
            if let Some(slot) = values.get_mut(frame * bins + bin) {
                *slot -= mean;
            }
        }
    }
}

fn hamming_window() -> Vec<f32> {
    (0..FRAME_LENGTH)
        .map(|index| 0.54 - 0.46 * (2.0 * PI * index as f32 / (FRAME_LENGTH as f32 - 1.0)).cos())
        .collect()
}

fn hz_to_mel(hz: f32) -> f32 {
    1127.0 * (1.0 + hz / 700.0).ln()
}

fn mel_to_hz(mel: f32) -> f32 {
    700.0 * ((mel / 1127.0).exp() - 1.0)
}

/// Triangular bands as `(fft_bin, weight)` pairs, so the inner loop touches
/// only the handful of bins each band actually covers.
fn mel_filters(bins: usize) -> Vec<Vec<(usize, f32)>> {
    let low = hz_to_mel(MEL_LOW_HZ);
    let high = hz_to_mel(MEL_HIGH_HZ);
    let step = (high - low) / (bins as f32 + 1.0);
    let bin_hz = TARGET_SAMPLE_RATE_HZ as f32 / FFT_SIZE as f32;
    let spectrum = FFT_SIZE / 2 + 1;
    (0..bins)
        .map(|band| {
            let left = mel_to_hz(low + step * band as f32);
            let center = mel_to_hz(low + step * (band as f32 + 1.0));
            let right = mel_to_hz(low + step * (band as f32 + 2.0));
            (0..spectrum)
                .filter_map(|bin| {
                    let hz = bin as f32 * bin_hz;
                    let weight = if hz > left && hz <= center {
                        (hz - left) / (center - left)
                    } else if hz > center && hz < right {
                        (right - hz) / (right - center)
                    } else {
                        0.0
                    };
                    (weight > 0.0).then_some((bin, weight))
                })
                .collect()
        })
        .collect()
}

/// In-place radix-2 FFT over [`FFT_SIZE`] points.
fn fft_in_place(real: &mut [f32], imaginary: &mut [f32]) {
    let n = real.len();
    if n < 2 || !n.is_power_of_two() {
        return;
    }
    let mut target = 0_usize;
    for source in 1..n {
        let mut bit = n >> 1;
        while target & bit != 0 {
            target ^= bit;
            bit >>= 1;
        }
        target |= bit;
        if source < target {
            real.swap(source, target);
            imaginary.swap(source, target);
        }
    }
    let mut span = 2_usize;
    while span <= n {
        let angle = -2.0 * PI / span as f32;
        let (step_sin, step_cos) = angle.sin_cos();
        let mut block = 0_usize;
        while block < n {
            let mut factor_re = 1.0_f32;
            let mut factor_im = 0.0_f32;
            for offset in 0..span / 2 {
                let low = block + offset;
                let high = low + span / 2;
                let (Some(&hr), Some(&hi), Some(&lr), Some(&li)) = (
                    real.get(high),
                    imaginary.get(high),
                    real.get(low),
                    imaginary.get(low),
                ) else {
                    break;
                };
                let product_re = hr * factor_re - hi * factor_im;
                let product_im = hr * factor_im + hi * factor_re;
                if let Some(slot) = real.get_mut(high) {
                    *slot = lr - product_re;
                }
                if let Some(slot) = imaginary.get_mut(high) {
                    *slot = li - product_im;
                }
                if let Some(slot) = real.get_mut(low) {
                    *slot = lr + product_re;
                }
                if let Some(slot) = imaginary.get_mut(low) {
                    *slot = li + product_im;
                }
                let next_re = factor_re * step_cos - factor_im * step_sin;
                factor_im = factor_re * step_sin + factor_im * step_cos;
                factor_re = next_re;
            }
            block += span;
        }
        span <<= 1;
    }
}

#[cfg(test)]
mod tests {
    use super::{
        FRAME_LENGTH, FRAME_SHIFT, Fbank, MEL_BINS, TARGET_SAMPLE_RATE_HZ, TractEmbeddingSource,
        fbank, frame_count, resample_to_target, resolve_embedding_source,
    };
    use crate::speech_profiles::EmbeddingError;
    use std::path::PathBuf;

    fn scratch(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!("speech_embedding_{}_{name}", std::process::id()))
    }

    fn tone(samples: usize) -> Vec<f32> {
        (0..samples)
            .map(|index| {
                (2.0 * std::f32::consts::PI * 220.0 * index as f32 / TARGET_SAMPLE_RATE_HZ as f32)
                    .sin()
                    * 0.5
            })
            .collect()
    }

    #[test]
    fn a_missing_model_resolves_to_the_fail_closed_source() {
        let path = scratch("absent.onnx");
        let _ = std::fs::remove_file(&path);
        let source = resolve_embedding_source(&path);
        assert_eq!(
            source.embed(&vec![0_i16; 32_000], TARGET_SAMPLE_RATE_HZ),
            Err(EmbeddingError::Unavailable)
        );
    }

    #[test]
    fn loading_a_missing_or_garbage_file_is_a_typed_error() {
        let missing = scratch("nowhere.onnx");
        let _ = std::fs::remove_file(&missing);
        assert_eq!(
            TractEmbeddingSource::load(&missing).err(),
            Some(EmbeddingError::Unavailable)
        );
        let garbage = scratch("garbage.onnx");
        assert!(std::fs::write(&garbage, b"this is not a protobuf at all").is_ok());
        assert_eq!(
            TractEmbeddingSource::load(&garbage).err(),
            Some(EmbeddingError::Unavailable)
        );
        assert!(
            resolve_embedding_source(&garbage)
                .embed(&vec![0_i16; 32_000], TARGET_SAMPLE_RATE_HZ)
                .is_err()
        );
        let _ = std::fs::remove_file(&garbage);
    }

    #[test]
    fn the_frame_count_follows_the_snip_edges_convention() {
        assert_eq!(frame_count(0), 0);
        assert_eq!(frame_count(FRAME_LENGTH - 1), 0);
        assert_eq!(frame_count(FRAME_LENGTH), 1);
        assert_eq!(frame_count(FRAME_LENGTH + FRAME_SHIFT), 2);
        // One second at 16 kHz.
        assert_eq!(frame_count(16_000), 98);
    }

    #[test]
    fn the_front_end_is_deterministic_and_correctly_shaped() {
        let samples = tone(16_000);
        let Ok(first) = fbank(&samples, MEL_BINS) else {
            panic!("a one-second tone produces features");
        };
        let Ok(second) = fbank(&samples, MEL_BINS) else {
            panic!("a one-second tone produces features");
        };
        assert_eq!(first.frames(), 98);
        assert_eq!(first.bins(), MEL_BINS);
        assert_eq!(first.values().len(), 98 * MEL_BINS);
        assert_eq!(first, second);
        assert!(first.values().iter().all(|value| value.is_finite()));
    }

    #[test]
    fn a_segment_shorter_than_one_window_has_no_features() {
        assert!(matches!(
            fbank(&tone(FRAME_LENGTH - 1), MEL_BINS),
            Err(EmbeddingError::TooShort { .. })
        ));
        assert!(matches!(
            fbank(&tone(16_000), 0),
            Err(EmbeddingError::TooShort { .. })
        ));
    }

    #[test]
    fn pcm_is_scaled_and_resampled_to_the_model_rate() {
        let Ok(direct) = resample_to_target(&[0, 16_384, -32_768], TARGET_SAMPLE_RATE_HZ) else {
            panic!("16 kHz audio passes straight through");
        };
        assert_eq!(direct, vec![0.0, 0.5, -1.0]);
        let Ok(upsampled) = resample_to_target(&vec![0_i16; 8_000], 8_000) else {
            panic!("8 kHz audio resamples");
        };
        assert_eq!(upsampled.len(), 16_000);
        let Ok(downsampled) = resample_to_target(&vec![0_i16; 48_000], 48_000) else {
            panic!("48 kHz audio resamples");
        };
        assert_eq!(downsampled.len(), 16_000);
        assert_eq!(
            resample_to_target(&[0], 0),
            Err(EmbeddingError::UnsupportedSampleRate(0))
        );
    }

    #[test]
    fn a_pure_tone_peaks_in_the_band_that_contains_it() {
        let Ok(features) = fbank(&tone(16_000), MEL_BINS) else {
            panic!("a one-second tone produces features");
        };
        let Some(frame) = features.values().get(0..MEL_BINS) else {
            panic!("the first frame exists");
        };
        let Some((peak, _)) = frame
            .iter()
            .enumerate()
            .max_by(|left, right| left.1.total_cmp(right.1))
        else {
            panic!("a frame has a maximum");
        };
        // 220 Hz sits low in a 20 Hz-7600 Hz mel scale; the peak must not
        // wander into the top half or the filterbank is mis-built.
        assert!(peak < MEL_BINS / 2, "peak band {peak}");
    }

    #[test]
    fn features_are_mean_normalized_per_band() {
        let Ok(features) = fbank(&tone(16_000), MEL_BINS) else {
            panic!("a one-second tone produces features");
        };
        let Fbank { frames, bins, .. } = features.clone();
        for bin in 0..bins {
            let total: f32 = (0..frames)
                .filter_map(|frame| features.values().get(frame * bins + bin))
                .sum();
            assert!((total / frames as f32).abs() < 1e-3);
        }
    }
}
