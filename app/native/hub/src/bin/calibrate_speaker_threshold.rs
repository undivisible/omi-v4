//! Developer tool: measure `speech_profiles::MATCH_THRESHOLD` against real
//! recorded speech instead of synthesized voices.
//!
//! This binary is not part of the shipped app. It is not linked into the
//! `cdylib`/`staticlib` the mobile and desktop builds consume; it exists only
//! to be run by hand on a laptop with a model file and a folder of audio.
//!
//! # Input layout
//!
//! One directory per speaker, each holding two or more recordings of that one
//! person and nobody else:
//!
//! ```text
//! samples/
//!   speaker-a/1.wav
//!   speaker-a/2.wav
//!   speaker-a/3.wav
//!   speaker-b/1.wav
//!   speaker-b/2.wav
//! ```
//!
//! Files must be RIFF/WAVE holding 16-bit PCM (`WAVE_FORMAT_PCM`, or
//! `WAVE_FORMAT_EXTENSIBLE` whose sub-format is PCM). Multi-channel files are
//! downmixed by averaging. Any other encoding — 8/24/32-bit, float, a-law,
//! compressed — is refused by name rather than reinterpreted as noise. The
//! sample rate may be anything at or above
//! `speech_profiles::MIN_EMBEDDING_SAMPLE_RATE_HZ`; the embedding source
//! resamples to 16 kHz itself. Clips shorter than
//! `speech_profiles::MIN_EMBEDDING_MS` are rejected by the same guard the app
//! uses.
//!
//! `meeting_capture::parse_wav_header` is deliberately not reused: it is
//! `pub(crate)` and compiled only on macOS or under `cfg(test)`, so a binary
//! target cannot call it, and it reads only the sample rate — it does not
//! report channel count or bit depth, which is exactly the information needed
//! here to refuse a file rather than misread it.
//!
//! # Invocation
//!
//! ```text
//! cargo run --release --bin calibrate_speaker_threshold -- \
//!     --model /path/to/ecapa.onnx \
//!     --samples /path/to/samples \
//!     [--target-far 0.01] [--max-merges 20]
//! ```
//!
//! # Reading the output
//!
//! Every recording is embedded, then every unordered pair of recordings is
//! scored with the same `cosine_distance` the matcher uses, and the pairs are
//! split into same-speaker (should match) and different-speaker (must not
//! match) sets.
//!
//! * **Overlap** is the headline. If the largest same-speaker distance is at or
//!   above the smallest different-speaker distance, the two populations
//!   interleave and *no* threshold separates them. Nothing further in the
//!   report can fix that; the model or the audio is wrong.
//! * **EER** is where the miss rate equals the false-accept rate. It is
//!   reported because it is the number usually quoted, not because it is the
//!   number to ship.
//! * **Suggested threshold** targets a low false-accept rate instead, because
//!   the expensive mistake here is attaching the wrong person's name to speech,
//!   not failing to attach a name at all.
//! * **Margin** reports, per clip, the gap between its nearest same-speaker
//!   neighbour and its nearest different-speaker neighbour. `MATCH_MARGIN`
//!   should sit below that gap for most clips, or ambiguity is declared on
//!   pairs that were in fact separable.
//!
//! Small collections produce confident-looking numbers that mean nothing, so
//! the report leads with explicit warnings when the sample is too thin and the
//! suggested threshold is withheld rather than guessed.

use hub::speech_embedding::TractEmbeddingSource;
use hub::speech_profiles::{
    MATCH_MARGIN, MATCH_THRESHOLD, MIN_EMBEDDING_SAMPLE_RATE_HZ, SpeakerEmbedding, embed_segment,
};
use std::path::{Path, PathBuf};

mod stats {
    #[derive(Clone, Copy, Debug, PartialEq)]
    pub struct Summary {
        pub count: usize,
        pub min: f32,
        pub median: f32,
        pub mean: f32,
        pub max: f32,
    }

    #[derive(Clone, Copy, Debug, PartialEq)]
    pub struct Eer {
        pub threshold: f32,
        pub rate: f64,
        pub false_accept: f64,
        pub false_reject: f64,
    }

    #[derive(Clone, Copy, Debug, PartialEq)]
    pub struct Overlap {
        pub max_same: f32,
        pub min_different: f32,
    }

    impl Overlap {
        pub fn overlaps(&self) -> bool {
            self.max_same >= self.min_different
        }

        pub fn gap(&self) -> f32 {
            self.min_different - self.max_same
        }
    }

    pub fn sorted(values: &[f32]) -> Vec<f32> {
        let mut out = values.to_vec();
        out.sort_by(f32::total_cmp);
        out
    }

    pub fn summarize(sorted_values: &[f32]) -> Option<Summary> {
        let count = sorted_values.len();
        let first = *sorted_values.first()?;
        let last = *sorted_values.last()?;
        let middle = count / 2;
        let median = if count.is_multiple_of(2) {
            let lower = sorted_values.get(middle - 1).copied().unwrap_or(first);
            let upper = sorted_values.get(middle).copied().unwrap_or(last);
            f32::midpoint(lower, upper)
        } else {
            sorted_values.get(middle).copied().unwrap_or(first)
        };
        let mean = sorted_values
            .iter()
            .map(|value| f64::from(*value))
            .sum::<f64>()
            / count as f64;
        Some(Summary {
            count,
            min: first,
            median,
            mean: mean as f32,
            max: last,
        })
    }

    /// Fraction of different-speaker pairs that the matcher would accept at
    /// `threshold`. The matcher accepts when `distance < threshold`.
    pub fn false_accept_rate(sorted_different: &[f32], threshold: f32) -> f64 {
        if sorted_different.is_empty() {
            return 0.0;
        }
        let accepted = sorted_different.partition_point(|value| *value < threshold);
        accepted as f64 / sorted_different.len() as f64
    }

    /// Fraction of same-speaker pairs the matcher would miss at `threshold`.
    pub fn false_reject_rate(sorted_same: &[f32], threshold: f32) -> f64 {
        if sorted_same.is_empty() {
            return 0.0;
        }
        let accepted = sorted_same.partition_point(|value| *value < threshold);
        (sorted_same.len() - accepted) as f64 / sorted_same.len() as f64
    }

    fn candidates(sorted_same: &[f32], sorted_different: &[f32]) -> Vec<f32> {
        let mut all: Vec<f32> = sorted_same
            .iter()
            .chain(sorted_different.iter())
            .copied()
            .collect();
        all.sort_by(f32::total_cmp);
        all.dedup();
        let mut out = Vec::with_capacity(all.len() + 2);
        out.push(0.0);
        for value in &all {
            out.push(*value);
            out.push(value + f32::EPSILON.max(value.abs() * f32::EPSILON));
        }
        if let Some(last) = all.last() {
            out.push(last + 1.0);
        }
        out.sort_by(f32::total_cmp);
        out.dedup();
        out
    }

    /// Sweeps every threshold at which either error rate can change and returns
    /// the one where the two rates are closest.
    ///
    /// `rate` is their midpoint, which is the conventional reading when the two
    /// step functions never meet exactly — with finitely many pairs they
    /// usually do not.
    pub fn equal_error_rate(sorted_same: &[f32], sorted_different: &[f32]) -> Option<Eer> {
        if sorted_same.is_empty() || sorted_different.is_empty() {
            return None;
        }
        let mut best: Option<Eer> = None;
        for threshold in candidates(sorted_same, sorted_different) {
            let false_accept = false_accept_rate(sorted_different, threshold);
            let false_reject = false_reject_rate(sorted_same, threshold);
            let spread = (false_accept - false_reject).abs();
            let rate = f64::midpoint(false_accept, false_reject);
            let better = match best {
                None => true,
                Some(current) => {
                    let current_spread = (current.false_accept - current.false_reject).abs();
                    spread < current_spread || (spread == current_spread && rate < current.rate)
                }
            };
            if better {
                best = Some(Eer {
                    threshold,
                    rate,
                    false_accept,
                    false_reject,
                });
            }
        }
        best
    }

    pub fn overlap(sorted_same: &[f32], sorted_different: &[f32]) -> Option<Overlap> {
        Some(Overlap {
            max_same: *sorted_same.last()?,
            min_different: *sorted_different.first()?,
        })
    }

    /// The largest threshold whose measured false-accept rate stays at or below
    /// `target`.
    ///
    /// The rate is a step function that rises only at an observed
    /// different-speaker distance, so the answer is the `k`-th smallest such
    /// distance where `k` is how many false accepts the target permits: setting
    /// the threshold exactly there accepts the `k` strictly smaller distances
    /// and nothing else. `None` when the whole different-speaker set would have
    /// to be accepted.
    pub fn threshold_for_target_far(sorted_different: &[f32], target: f64) -> Option<f32> {
        if sorted_different.is_empty() || !(0.0..=1.0).contains(&target) {
            return None;
        }
        let permitted = (target * sorted_different.len() as f64).floor() as usize;
        sorted_different.get(permitted).copied()
    }

    /// How finely the different-speaker set can express a rate at all: one
    /// pair. A target below this is arithmetic, not measurement.
    pub fn far_resolution(different_pairs: usize) -> f64 {
        if different_pairs == 0 {
            return 1.0;
        }
        1.0 / different_pairs as f64
    }

    /// Reasons the numbers below should not be trusted. Empty means the sample
    /// is large enough for the report to stand on its own.
    pub fn trust_warnings(
        speakers: usize,
        fewest_clips_per_speaker: usize,
        same_pairs: usize,
        different_pairs: usize,
        target_far: f64,
    ) -> Vec<String> {
        let mut out = Vec::new();
        if speakers < 2 {
            out.push(format!(
                "only {speakers} speaker(s): there are no different-speaker pairs, so nothing here measures a threshold"
            ));
        } else if speakers < 5 {
            out.push(format!(
                "only {speakers} speakers: a threshold fitted to this few voices will not generalise; use 8 or more"
            ));
        }
        if fewest_clips_per_speaker < 2 {
            out.push(format!(
                "some speaker has {fewest_clips_per_speaker} clip(s): a speaker with one clip contributes no same-speaker pair"
            ));
        }
        if same_pairs < 20 {
            out.push(format!(
                "only {same_pairs} same-speaker pairs: the miss rate and the margin figures are noise below about 20"
            ));
        }
        if different_pairs < 20 {
            out.push(format!(
                "only {different_pairs} different-speaker pairs: the false-accept rate is noise below about 20"
            ));
        }
        if target_far > 0.0 && (different_pairs as f64) < 10.0 / target_far {
            out.push(format!(
                "a {:.2}% false-accept target needs about {} different-speaker pairs to be measurable; there are {different_pairs}",
                target_far * 100.0,
                (10.0 / target_far).ceil() as usize
            ));
        }
        out
    }

    #[cfg(test)]
    mod tests {
        use super::{
            equal_error_rate, false_accept_rate, false_reject_rate, far_resolution, overlap,
            sorted, summarize, threshold_for_target_far, trust_warnings,
        };

        #[test]
        fn summary_reports_min_median_and_max() {
            let values = sorted(&[0.4, 0.1, 0.3, 0.2]);
            let Some(summary) = summarize(&values) else {
                panic!("four values summarize");
            };
            assert_eq!(summary.count, 4);
            assert!((summary.min - 0.1).abs() < 1e-6);
            assert!((summary.median - 0.25).abs() < 1e-6);
            assert!((summary.max - 0.4).abs() < 1e-6);
            assert!(summarize(&[]).is_none());
        }

        #[test]
        fn false_accept_rate_counts_different_speaker_pairs_below_the_threshold() {
            let different = sorted(&[0.10, 0.20, 0.30, 0.40, 0.50]);
            assert!((false_accept_rate(&different, 0.05) - 0.0).abs() < 1e-9);
            assert!((false_accept_rate(&different, 0.25) - 0.4).abs() < 1e-9);
            assert!((false_accept_rate(&different, 0.60) - 1.0).abs() < 1e-9);
            assert!(
                (false_accept_rate(&different, 0.30) - 0.4).abs() < 1e-9,
                "acceptance is strictly below the threshold, matching the matcher"
            );
            assert!((false_accept_rate(&[], 0.25) - 0.0).abs() < 1e-9);
        }

        #[test]
        fn false_reject_rate_counts_same_speaker_pairs_at_or_above_the_threshold() {
            let same = sorted(&[0.05, 0.10, 0.15, 0.40]);
            assert!((false_reject_rate(&same, 0.20) - 0.25).abs() < 1e-9);
            assert!((false_reject_rate(&same, 0.50) - 0.0).abs() < 1e-9);
            assert!((false_reject_rate(&same, 0.05) - 1.0).abs() < 1e-9);
        }

        #[test]
        fn equal_error_rate_finds_the_crossing_of_a_known_separable_set() {
            let same = sorted(&[0.10, 0.12, 0.14, 0.16]);
            let different = sorted(&[0.60, 0.62, 0.64, 0.66]);
            let Some(eer) = equal_error_rate(&same, &different) else {
                panic!("both partitions are populated");
            };
            assert!(
                (eer.rate - 0.0).abs() < 1e-9,
                "cleanly separated sets have a zero equal error rate"
            );
            assert!(eer.threshold > 0.16 && eer.threshold <= 0.60);
        }

        #[test]
        fn equal_error_rate_reports_the_symmetric_error_of_an_overlapping_set() {
            let same = sorted(&[0.10, 0.20, 0.30, 0.60]);
            let different = sorted(&[0.15, 0.50, 0.70, 0.80]);
            let Some(eer) = equal_error_rate(&same, &different) else {
                panic!("both partitions are populated");
            };
            assert!(
                (eer.rate - 0.25).abs() < 1e-9,
                "one of four fails on each side: {eer:?}"
            );
            assert!((eer.false_accept - eer.false_reject).abs() < 1e-9);
        }

        #[test]
        fn equal_error_rate_needs_both_partitions() {
            assert!(equal_error_rate(&[], &[0.5]).is_none());
            assert!(equal_error_rate(&[0.1], &[]).is_none());
        }

        #[test]
        fn overlap_is_detected_when_the_partitions_interleave() {
            let same = sorted(&[0.10, 0.45]);
            let different = sorted(&[0.30, 0.80]);
            let Some(region) = overlap(&same, &different) else {
                panic!("both partitions are populated");
            };
            assert!(region.overlaps());
            assert!(region.gap() < 0.0);
        }

        #[test]
        fn separated_partitions_report_a_positive_gap() {
            let same = sorted(&[0.10, 0.20]);
            let different = sorted(&[0.50, 0.80]);
            let Some(region) = overlap(&same, &different) else {
                panic!("both partitions are populated");
            };
            assert!(!region.overlaps());
            assert!((region.gap() - 0.30).abs() < 1e-6);
        }

        #[test]
        fn suggested_threshold_holds_the_false_accept_rate_at_or_under_target() {
            let different = sorted(&[0.10, 0.20, 0.30, 0.40, 0.50, 0.60, 0.70, 0.80, 0.90, 1.00]);
            let Some(strict) = threshold_for_target_far(&different, 0.0) else {
                panic!("a zero target is the smallest observed distance");
            };
            assert!((strict - 0.10).abs() < 1e-6);
            assert!((false_accept_rate(&different, strict) - 0.0).abs() < 1e-9);

            let Some(lenient) = threshold_for_target_far(&different, 0.2) else {
                panic!("a 20% target is reachable with ten pairs");
            };
            assert!((lenient - 0.30).abs() < 1e-6);
            assert!(false_accept_rate(&different, lenient) <= 0.2 + 1e-9);

            assert!(threshold_for_target_far(&different, 1.0).is_none());
            assert!(threshold_for_target_far(&[], 0.01).is_none());
        }

        #[test]
        fn far_resolution_is_one_pair() {
            assert!((far_resolution(200) - 0.005).abs() < 1e-9);
            assert!((far_resolution(0) - 1.0).abs() < 1e-9);
        }

        #[test]
        fn thin_collections_are_called_out_and_ample_ones_are_not() {
            let thin = trust_warnings(2, 1, 1, 1, 0.01);
            assert!(thin.len() >= 4, "every thinness check fires: {thin:?}");
            assert!(thin.iter().any(|warning| warning.contains("2 speakers")));
            assert!(thin.iter().any(|warning| warning.contains("1 clip(s)")));

            let single = trust_warnings(1, 3, 3, 0, 0.01);
            assert!(
                single
                    .iter()
                    .any(|warning| warning.contains("1 speaker(s)"))
            );

            assert!(
                trust_warnings(10, 5, 100, 1_000, 0.01).is_empty(),
                "ten speakers with five clips each is enough to stand on"
            );
        }
    }
}

mod wav {
    /// 16-bit PCM samples downmixed to one channel, with the file's rate.
    pub struct Pcm {
        pub samples: Vec<i16>,
        pub sample_rate: u32,
    }

    const FORMAT_PCM: u16 = 1;
    const FORMAT_EXTENSIBLE: u16 = 0xFFFE;

    fn read_u16(bytes: &[u8], offset: usize) -> Option<u16> {
        bytes
            .get(offset..offset + 2)?
            .try_into()
            .ok()
            .map(u16::from_le_bytes)
    }

    fn read_u32(bytes: &[u8], offset: usize) -> Option<u32> {
        bytes
            .get(offset..offset + 4)?
            .try_into()
            .ok()
            .map(u32::from_le_bytes)
    }

    /// Walks the RIFF chunks, refusing anything that is not 16-bit PCM by name.
    pub fn decode(bytes: &[u8]) -> Result<Pcm, String> {
        if bytes.len() < 12 || bytes.get(0..4) != Some(b"RIFF") || bytes.get(8..12) != Some(b"WAVE")
        {
            return Err("not a RIFF/WAVE file".to_owned());
        }
        let mut position = 12usize;
        let mut format: Option<(u16, u16, u32, u16)> = None;
        while position + 8 <= bytes.len() {
            let id = bytes
                .get(position..position + 4)
                .ok_or_else(|| "truncated chunk header".to_owned())?;
            let size = read_u32(bytes, position + 4)
                .ok_or_else(|| "truncated chunk header".to_owned())?
                as usize;
            let body = position + 8;
            let end = body
                .checked_add(size)
                .ok_or_else(|| "chunk size overflows the file".to_owned())?;
            if id == b"fmt " {
                let chunk = bytes
                    .get(body..end.min(bytes.len()))
                    .ok_or_else(|| "truncated fmt chunk".to_owned())?;
                let mut code = read_u16(chunk, 0).ok_or_else(|| "short fmt chunk".to_owned())?;
                let channels = read_u16(chunk, 2).ok_or_else(|| "short fmt chunk".to_owned())?;
                let rate = read_u32(chunk, 4).ok_or_else(|| "short fmt chunk".to_owned())?;
                let bits = read_u16(chunk, 14).ok_or_else(|| "short fmt chunk".to_owned())?;
                if code == FORMAT_EXTENSIBLE {
                    code = read_u16(chunk, 24)
                        .ok_or_else(|| "short WAVE_FORMAT_EXTENSIBLE fmt chunk".to_owned())?;
                }
                if code != FORMAT_PCM {
                    return Err(format!(
                        "unsupported encoding: WAVE format tag {code} (only 16-bit PCM is read here; re-encode with `ffmpeg -i in -c:a pcm_s16le -ar 16000 -ac 1 out.wav`)"
                    ));
                }
                if bits != 16 {
                    return Err(format!(
                        "unsupported sample width: {bits}-bit (only 16-bit PCM is read here)"
                    ));
                }
                if channels == 0 {
                    return Err("fmt chunk declares zero channels".to_owned());
                }
                format = Some((code, channels, rate, bits));
            } else if id == b"data" {
                let (_, channels, rate, _) =
                    format.ok_or_else(|| "data chunk precedes the fmt chunk".to_owned())?;
                let chunk = bytes
                    .get(body..end.min(bytes.len()))
                    .ok_or_else(|| "truncated data chunk".to_owned())?;
                let frame = usize::from(channels) * 2;
                if frame == 0 || chunk.len() < frame {
                    return Err("data chunk holds no complete frame".to_owned());
                }
                let mut samples = Vec::with_capacity(chunk.len() / frame);
                for frame_bytes in chunk.chunks_exact(frame) {
                    let mut total = 0i32;
                    for channel in frame_bytes.chunks_exact(2) {
                        let value = channel
                            .try_into()
                            .map(i16::from_le_bytes)
                            .map_err(|_| "truncated sample".to_owned())?;
                        total += i32::from(value);
                    }
                    let mixed = total / i32::from(channels);
                    samples.push(mixed.clamp(i32::from(i16::MIN), i32::from(i16::MAX)) as i16);
                }
                return Ok(Pcm {
                    samples,
                    sample_rate: rate,
                });
            }
            position = end + (size % 2);
        }
        Err("no data chunk found".to_owned())
    }

    #[cfg(test)]
    mod tests {
        use super::decode;

        fn wav(format: u16, channels: u16, bits: u16, data: &[u8]) -> Vec<u8> {
            let mut out = Vec::new();
            out.extend_from_slice(b"RIFF");
            out.extend_from_slice(&0u32.to_le_bytes());
            out.extend_from_slice(b"WAVE");
            out.extend_from_slice(b"fmt ");
            out.extend_from_slice(&16u32.to_le_bytes());
            out.extend_from_slice(&format.to_le_bytes());
            out.extend_from_slice(&channels.to_le_bytes());
            out.extend_from_slice(&16_000u32.to_le_bytes());
            out.extend_from_slice(&0u32.to_le_bytes());
            out.extend_from_slice(&0u16.to_le_bytes());
            out.extend_from_slice(&bits.to_le_bytes());
            out.extend_from_slice(b"data");
            out.extend_from_slice(&(data.len() as u32).to_le_bytes());
            out.extend_from_slice(data);
            out
        }

        #[test]
        fn mono_sixteen_bit_pcm_decodes() {
            let mut data = Vec::new();
            data.extend_from_slice(&100i16.to_le_bytes());
            data.extend_from_slice(&(-100i16).to_le_bytes());
            let Ok(pcm) = decode(&wav(1, 1, 16, &data)) else {
                panic!("mono 16-bit PCM decodes");
            };
            assert_eq!(pcm.samples, vec![100, -100]);
            assert_eq!(pcm.sample_rate, 16_000);
        }

        #[test]
        fn stereo_is_downmixed_to_one_channel() {
            let mut data = Vec::new();
            data.extend_from_slice(&100i16.to_le_bytes());
            data.extend_from_slice(&300i16.to_le_bytes());
            let Ok(pcm) = decode(&wav(1, 2, 16, &data)) else {
                panic!("stereo 16-bit PCM decodes");
            };
            assert_eq!(pcm.samples, vec![200]);
        }

        #[test]
        fn unsupported_encodings_are_refused_by_name() {
            let float = decode(&wav(3, 1, 32, &[0u8; 8]));
            assert!(
                float.is_err_and(|message| message.contains("WAVE format tag 3")),
                "float WAV is named, not misread"
            );
            let wide = decode(&wav(1, 1, 24, &[0u8; 9]));
            assert!(wide.is_err_and(|message| message.contains("24-bit")));
            assert!(decode(b"not a wav at all").is_err());
        }
    }
}

struct Clip {
    speaker: String,
    label: String,
    embedding: SpeakerEmbedding,
}

struct Pair {
    left: usize,
    right: usize,
    distance: f32,
}

struct Options {
    model: PathBuf,
    samples: PathBuf,
    target_far: f64,
    max_merges: usize,
}

const USAGE: &str = "usage: calibrate_speaker_threshold --model <model.onnx> --samples <dir> [--target-far 0.01] [--max-merges 20]";

fn parse_options(arguments: &[String]) -> Result<Options, String> {
    let mut model: Option<PathBuf> = None;
    let mut samples: Option<PathBuf> = None;
    let mut target_far = 0.01f64;
    let mut max_merges = 20usize;
    let mut index = 0usize;
    while let Some(flag) = arguments.get(index) {
        let value = arguments.get(index + 1);
        let take = || {
            value
                .cloned()
                .ok_or_else(|| format!("{flag} needs a value\n{USAGE}"))
        };
        match flag.as_str() {
            "--model" => model = Some(PathBuf::from(take()?)),
            "--samples" => samples = Some(PathBuf::from(take()?)),
            "--target-far" => {
                target_far = take()?
                    .parse::<f64>()
                    .map_err(|_| "--target-far must be a fraction such as 0.01".to_owned())?;
                if !(0.0..1.0).contains(&target_far) {
                    return Err("--target-far must be in [0, 1)".to_owned());
                }
            }
            "--max-merges" => {
                max_merges = take()?
                    .parse::<usize>()
                    .map_err(|_| "--max-merges must be a whole number".to_owned())?;
            }
            "--help" | "-h" => return Err(USAGE.to_owned()),
            other => return Err(format!("unknown argument {other}\n{USAGE}")),
        }
        index += 2;
    }
    Ok(Options {
        model: model.ok_or_else(|| format!("--model is required\n{USAGE}"))?,
        samples: samples.ok_or_else(|| format!("--samples is required\n{USAGE}"))?,
        target_far,
        max_merges,
    })
}

fn sorted_entries(directory: &Path) -> Result<Vec<PathBuf>, String> {
    let mut out: Vec<PathBuf> = std::fs::read_dir(directory)
        .map_err(|error| format!("cannot read {}: {error}", directory.display()))?
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .collect();
    out.sort();
    Ok(out)
}

fn is_wav(path: &Path) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| extension.eq_ignore_ascii_case("wav"))
}

fn load_clips(options: &Options, source: &TractEmbeddingSource) -> Result<Vec<Clip>, String> {
    let mut clips = Vec::new();
    let mut skipped = Vec::new();
    for speaker_directory in sorted_entries(&options.samples)? {
        if !speaker_directory.is_dir() {
            continue;
        }
        let speaker = speaker_directory
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("?")
            .to_owned();
        for file in sorted_entries(&speaker_directory)? {
            if !file.is_file() || !is_wav(&file) {
                continue;
            }
            let label = format!(
                "{speaker}/{}",
                file.file_name()
                    .and_then(|name| name.to_str())
                    .unwrap_or("?")
            );
            let bytes = std::fs::read(&file)
                .map_err(|error| format!("cannot read {}: {error}", file.display()))?;
            let pcm = wav::decode(&bytes).map_err(|message| format!("{label}: {message}"))?;
            if pcm.sample_rate < MIN_EMBEDDING_SAMPLE_RATE_HZ {
                return Err(format!(
                    "{label}: {} Hz is below the {MIN_EMBEDDING_SAMPLE_RATE_HZ} Hz floor the embedding path accepts",
                    pcm.sample_rate
                ));
            }
            match embed_segment(source, &pcm.samples, pcm.sample_rate) {
                Ok(embedding) => clips.push(Clip {
                    speaker: speaker.clone(),
                    label,
                    embedding,
                }),
                Err(error) => skipped.push(format!("{label}: {error}")),
            }
        }
    }
    if !skipped.is_empty() {
        println!(
            "Skipped {} clip(s) the embedding path refused:",
            skipped.len()
        );
        for reason in &skipped {
            println!("  {reason}");
        }
        println!();
    }
    Ok(clips)
}

fn print_summary(title: &str, sorted_values: &[f32]) {
    match stats::summarize(sorted_values) {
        Some(summary) => println!(
            "  {title:<18} n={:<6} min={:.4}  median={:.4}  mean={:.4}  max={:.4}",
            summary.count, summary.min, summary.median, summary.mean, summary.max
        ),
        None => println!("  {title:<18} n=0     (no pairs)"),
    }
}

fn report(clips: &[Clip], pairs: &[Pair], options: &Options) {
    let mut speakers: Vec<&str> = clips.iter().map(|clip| clip.speaker.as_str()).collect();
    speakers.sort_unstable();
    speakers.dedup();
    let fewest = speakers
        .iter()
        .map(|speaker| clips.iter().filter(|clip| clip.speaker == *speaker).count())
        .min()
        .unwrap_or(0);

    let same_values: Vec<f32> = pairs
        .iter()
        .filter(|pair| {
            clips.get(pair.left).map(|clip| clip.speaker.as_str())
                == clips.get(pair.right).map(|clip| clip.speaker.as_str())
        })
        .map(|pair| pair.distance)
        .collect();
    let different_values: Vec<f32> = pairs
        .iter()
        .filter(|pair| {
            clips.get(pair.left).map(|clip| clip.speaker.as_str())
                != clips.get(pair.right).map(|clip| clip.speaker.as_str())
        })
        .map(|pair| pair.distance)
        .collect();
    let same = stats::sorted(&same_values);
    let different = stats::sorted(&different_values);

    let warnings = stats::trust_warnings(
        speakers.len(),
        fewest,
        same.len(),
        different.len(),
        options.target_far,
    );

    println!("== Collection ==");
    println!(
        "  {} clips across {} speakers, fewest clips for one speaker: {fewest}",
        clips.len(),
        speakers.len()
    );
    println!(
        "  embedding dimensions: {}",
        clips.first().map_or(0, |clip| clip.embedding.dimensions())
    );
    println!();

    if warnings.is_empty() {
        println!("== Trust ==");
        println!("  the collection is large enough for these numbers to stand.");
    } else {
        println!("== TRUST: THIS SAMPLE IS TOO SMALL ==");
        for warning in &warnings {
            println!("  - {warning}");
        }
        println!("  Treat every number below as an illustration, not a calibration.");
    }
    println!();

    println!("== Distances ==");
    print_summary("same speaker", &same);
    print_summary("different speaker", &different);
    println!();

    println!("== Overlap ==");
    match stats::overlap(&same, &different) {
        Some(region) if region.overlaps() => {
            println!(
                "  *** OVERLAP: worst same-speaker pair {:.4} >= closest different-speaker pair {:.4} ***",
                region.max_same, region.min_different
            );
            println!(
                "  NO threshold separates these two populations. Every choice below trades one"
            );
            println!(
                "  error for the other. Fix the model or the recordings before trusting a number."
            );
        }
        Some(region) => {
            println!(
                "  clean: worst same-speaker pair {:.4} < closest different-speaker pair {:.4}",
                region.max_same, region.min_different
            );
            println!(
                "  any threshold in ({:.4}, {:.4}] separates this collection perfectly; gap {:.4}",
                region.max_same,
                region.min_different,
                region.gap()
            );
        }
        None => println!("  not computable: one of the two partitions is empty"),
    }
    println!();

    println!("== Equal error rate ==");
    match stats::equal_error_rate(&same, &different) {
        Some(eer) => {
            println!(
                "  EER {:.2}% at distance {:.4}  (false accept {:.2}%, miss {:.2}%)",
                eer.rate * 100.0,
                eer.threshold,
                eer.false_accept * 100.0,
                eer.false_reject * 100.0
            );
            println!(
                "  Reported for reference. Do not ship it: it weighs a wrong name the same as a"
            );
            println!("  missing one, and they are not the same cost.");
        }
        None => println!("  not computable: one of the two partitions is empty"),
    }
    println!();

    println!("== MATCH_THRESHOLD = {MATCH_THRESHOLD:.4} (current) ==");
    println!(
        "  false accept {:.2}% of {} different-speaker pairs",
        stats::false_accept_rate(&different, MATCH_THRESHOLD) * 100.0,
        different.len()
    );
    println!(
        "  miss         {:.2}% of {} same-speaker pairs",
        stats::false_reject_rate(&same, MATCH_THRESHOLD) * 100.0,
        same.len()
    );
    println!();

    println!("== Suggested threshold ==");
    println!(
        "  target false-accept rate {:.2}%, measurable to {:.2}% with {} pairs",
        options.target_far * 100.0,
        stats::far_resolution(different.len()) * 100.0,
        different.len()
    );
    if warnings.is_empty() {
        match stats::threshold_for_target_far(&different, options.target_far) {
            Some(threshold) => println!(
                "  MATCH_THRESHOLD = {threshold:.4}  (false accept {:.2}%, miss {:.2}%)",
                stats::false_accept_rate(&different, threshold) * 100.0,
                stats::false_reject_rate(&same, threshold) * 100.0
            ),
            None => println!(
                "  no threshold reaches that target: even the largest observed different-speaker"
            ),
        }
    } else {
        match stats::threshold_for_target_far(&different, options.target_far) {
            Some(threshold) => println!(
                "  withheld. This collection would say {threshold:.4}, which is not enough evidence to change a constant."
            ),
            None => println!("  withheld, and not computable from this collection anyway."),
        }
    }
    println!();

    println!("== Wrong merges at MATCH_THRESHOLD = {MATCH_THRESHOLD:.4} ==");
    let mut merged: Vec<&Pair> = pairs
        .iter()
        .filter(|pair| {
            pair.distance < MATCH_THRESHOLD
                && clips.get(pair.left).map(|clip| clip.speaker.as_str())
                    != clips.get(pair.right).map(|clip| clip.speaker.as_str())
        })
        .collect();
    merged.sort_by(|left, right| left.distance.total_cmp(&right.distance));
    if merged.is_empty() {
        println!("  none: no two different speakers land inside the threshold.");
    } else {
        println!(
            "  {} different-speaker pair(s) would be called the same person:",
            merged.len()
        );
        for pair in merged.iter().take(options.max_merges) {
            let left = clips.get(pair.left).map_or("?", |clip| clip.label.as_str());
            let right = clips
                .get(pair.right)
                .map_or("?", |clip| clip.label.as_str());
            println!("    {left} vs {right} at {:.4}", pair.distance);
        }
        if merged.len() > options.max_merges {
            println!(
                "    ... and {} more (raise --max-merges to see them)",
                merged.len() - options.max_merges
            );
        }
    }
    println!();

    println!("== MATCH_MARGIN = {MATCH_MARGIN:.4} ==");
    report_margin(clips, pairs);
}

fn report_margin(clips: &[Clip], pairs: &[Pair]) {
    let mut nearest_same = vec![f32::INFINITY; clips.len()];
    let mut nearest_other = vec![f32::INFINITY; clips.len()];
    for pair in pairs {
        let (Some(left), Some(right)) = (clips.get(pair.left), clips.get(pair.right)) else {
            continue;
        };
        let table = if left.speaker == right.speaker {
            &mut nearest_same
        } else {
            &mut nearest_other
        };
        for index in [pair.left, pair.right] {
            if let Some(slot) = table.get_mut(index)
                && pair.distance < *slot
            {
                *slot = pair.distance;
            }
        }
    }

    let mut gaps = Vec::new();
    let mut tight = Vec::new();
    for (index, clip) in clips.iter().enumerate() {
        let (Some(same), Some(other)) = (
            nearest_same.get(index).copied(),
            nearest_other.get(index).copied(),
        ) else {
            continue;
        };
        if !same.is_finite() || !other.is_finite() {
            continue;
        }
        let gap = other - same;
        gaps.push(gap);
        if gap < MATCH_MARGIN {
            tight.push((clip.label.clone(), same, other, gap));
        }
    }

    if gaps.is_empty() {
        println!("  not computable: no clip has both a same-speaker and a different-speaker peer.");
        return;
    }
    let sorted_gaps = stats::sorted(&gaps);
    print_summary("runner-up gap", &sorted_gaps);
    println!(
        "  This is, per clip, how much further the nearest OTHER speaker sits than the nearest"
    );
    println!("  same-speaker clip. MATCH_MARGIN must sit below it or correct matches are called");
    println!("  ambiguous.");
    if tight.is_empty() {
        println!(
            "  every clip's runner-up sits at least {MATCH_MARGIN:.4} away: the margin costs nothing here."
        );
    } else {
        println!(
            "  {} of {} clips have a gap under MATCH_MARGIN and would be declared ambiguous:",
            tight.len(),
            gaps.len()
        );
        for (label, same, other, gap) in tight.iter().take(20) {
            println!("    {label}: same {same:.4}, other {other:.4}, gap {gap:.4}");
        }
    }
}

fn run() -> Result<(), String> {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let options = parse_options(&arguments)?;
    let source = TractEmbeddingSource::load(&options.model).map_err(|error| {
        format!(
            "cannot load the model at {}: {error}",
            options.model.display()
        )
    })?;
    let clips = load_clips(&options, &source)?;
    if clips.len() < 2 {
        return Err(format!(
            "only {} usable clip(s) under {}: expected one subdirectory per speaker, each holding WAV files",
            clips.len(),
            options.samples.display()
        ));
    }
    let mut pairs = Vec::new();
    for left in 0..clips.len() {
        for right in (left + 1)..clips.len() {
            let (Some(first), Some(second)) = (clips.get(left), clips.get(right)) else {
                continue;
            };
            let distance = first
                .embedding
                .cosine_distance(&second.embedding)
                .ok_or_else(|| {
                    format!(
                        "{} and {} produced different-width vectors from one model",
                        first.label, second.label
                    )
                })?;
            pairs.push(Pair {
                left,
                right,
                distance,
            });
        }
    }
    report(&clips, &pairs, &options);
    Ok(())
}

fn main() -> std::process::ExitCode {
    match run() {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("{message}");
            std::process::ExitCode::FAILURE
        }
    }
}
