//! The Omi mark as an outbound video track.
//!
//! A realtime call that answers with audio only shows the caller a black
//! rectangle. This module renders the eight-dot Omi mark and animates it from
//! the assistant's *own* output amplitude: the ring breathes, a crest travels
//! around the dots and scatters them outward while it speaks, and everything
//! settles back to a still, evenly-lit ring the moment it is listening.
//!
//! Geometry is read from `app/assets/images/omi_mark.svg` (viewBox 0 0 260
//! 260, ring centre 129.5,129.5, dot radius 17.2, dots `d1` due north running
//! clockwise). That file is owned elsewhere and is not edited here; the
//! constants below mirror it so the animation and the in-app orb agree.
//!
//! Frames are single-channel luma. The mark is white on black, so chroma
//! carries nothing, and a luma-only frame stays legible when a call degrades
//! to a low bitrate at a small size: large solid discs with soft edges are
//! about the most compressible legible shape there is.

#![allow(dead_code)]
// The call path is complete and tested end to end inside the hub, but nothing
// in this crate calls into it yet: the command that places a FaceTime call and
// hands back a join link lives in the Worker and the Dart UI, both outside this
// change's ownership. `facetime_bridge::live::join` and `call_bridge::run_call`
// are the two entry points that surface needs.

use std::f32::consts::TAU;

/// Ring centre and dot radius, in the SVG's 260x260 user space.
const MARK_EXTENT: f32 = 260.0;
const MARK_CENTRE: f32 = 129.5;
const DOT_RADIUS: f32 = 17.2;

/// The eight dot centres, `d1` (due north) first, then clockwise. Copied from
/// the SVG rather than generated from an angle, because the mark is a rounded
/// square: the axis dots sit at radius 86.71 and the diagonal dots at 91.92.
const DOTS: [(f32, f32); 8] = [
    (129.5, 42.79),
    (194.5, 64.5),
    (216.21, 129.5),
    (194.5, 194.5),
    (129.5, 216.21),
    (64.5, 194.5),
    (42.79, 129.5),
    (64.5, 64.5),
];

pub(crate) const DOT_COUNT: usize = DOTS.len();

/// How fast the smoothed level chases the measured amplitude. Speech onsets
/// must land on the frame they happen on, but the tail has to fall gently or
/// the ring flickers on every syllable gap.
const ATTACK: f32 = 0.55;
const RELEASE: f32 = 0.10;

/// Full-scale RMS of Gemini's PCM output is nowhere near 1.0; normal speech
/// sits around 0.1-0.2. This maps that working range onto 0..1.
const RMS_FULL_SCALE: f32 = 0.22;

/// Idle drift, and the extra travel speed the crest picks up at full level,
/// both in turns per second.
const IDLE_TURNS_PER_SECOND: f32 = 0.06;
const SPEAKING_TURNS_PER_SECOND: f32 = 0.85;

#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct Dot {
    pub(crate) x: f32,
    pub(crate) y: f32,
    pub(crate) radius: f32,
    pub(crate) brightness: f32,
}

/// A single-channel luma frame, row-major, no padding.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct VideoFrame {
    pub(crate) width: u32,
    pub(crate) height: u32,
    pub(crate) luma: Vec<u8>,
}

/// Root-mean-square amplitude of a little-endian PCM16 buffer, normalised to
/// 0..1 against `RMS_FULL_SCALE`. A trailing odd byte is ignored rather than
/// misread as half a sample.
pub(crate) fn pcm16_amplitude(bytes: &[u8]) -> f32 {
    let mut sum_squares = 0.0f64;
    let mut count = 0u64;
    for frame in bytes.chunks_exact(2) {
        let sample = i16::from_le_bytes([frame[0], frame[1]]) as f64 / 32_768.0;
        sum_squares += sample * sample;
        count += 1;
    }
    if count == 0 {
        return 0.0;
    }
    let rms = (sum_squares / count as f64).sqrt() as f32;
    (rms / RMS_FULL_SCALE).clamp(0.0, 1.0)
}

/// Drives the mark from the assistant's output amplitude.
#[derive(Debug, Default)]
pub(crate) struct MarkAnimator {
    level: f32,
    target: f32,
    phase: f32,
}

impl MarkAnimator {
    pub(crate) fn new() -> Self {
        Self::default()
    }

    /// Feed a chunk of the assistant's own output audio. Chunks arrive in
    /// bursts far faster than frames are rendered, so the loudest chunk since
    /// the last frame wins rather than the most recent one.
    pub(crate) fn observe_output(&mut self, pcm16: &[u8]) {
        self.target = self.target.max(pcm16_amplitude(pcm16));
    }

    /// The assistant stopped talking — barge-in, turn complete, or hangup.
    /// The level is not slammed to zero; it releases, so the ring settles
    /// instead of snapping.
    pub(crate) fn silence(&mut self) {
        self.target = 0.0;
    }

    /// Advance by `dt` seconds and consume the amplitude accumulated since the
    /// previous frame.
    pub(crate) fn advance(&mut self, dt: f32) {
        let dt = dt.clamp(0.0, 0.5);
        let coefficient = if self.target > self.level {
            ATTACK
        } else {
            RELEASE
        };
        // Frame-rate independent one-pole smoothing, referenced to 30fps so
        // the constants above read as per-frame coefficients.
        let alpha = 1.0 - (1.0 - coefficient).powf((dt * 30.0).max(0.0));
        self.level += (self.target - self.level) * alpha;
        if self.level < 0.001 {
            self.level = 0.0;
        }
        let turns = IDLE_TURNS_PER_SECOND + SPEAKING_TURNS_PER_SECOND * self.level;
        self.phase = (self.phase + turns * dt).fract();
        self.target = 0.0;
    }

    pub(crate) fn level(&self) -> f32 {
        self.level
    }

    /// The eight dots for the current instant.
    ///
    /// - the whole ring breathes outward with the level,
    /// - a crest travels d1 -> d8 in mark order, faster the louder it is,
    /// - each dot is thrown further out and lit brighter as the crest passes,
    ///   with the scatter scaling as level^2 so quiet speech stays composed,
    /// - at level 0 the crest contributes nothing: eight evenly lit dots at
    ///   rest, drifting only in phase, which is the listening state.
    pub(crate) fn dots(&self) -> [Dot; DOT_COUNT] {
        let level = self.level;
        let ring_scale = 1.0 + 0.12 * level;
        let mut dots = [Dot {
            x: 0.0,
            y: 0.0,
            radius: 0.0,
            brightness: 0.0,
        }; DOT_COUNT];
        for (index, dot) in dots.iter_mut().enumerate() {
            let (base_x, base_y) = DOTS[index];
            let offset_x = base_x - MARK_CENTRE;
            let offset_y = base_y - MARK_CENTRE;
            let distance = offset_x.hypot(offset_y).max(f32::EPSILON);
            // Travelling crest: a cosine raised to a high power is a narrow
            // bump that still sums smoothly as it walks the ring.
            let position = self.phase - index as f32 / DOT_COUNT as f32;
            let crest = (position * TAU).cos().max(0.0).powi(3) * level;
            let scatter = 14.0 * level * level * crest;
            let radial = ring_scale + scatter / distance;
            dot.x = MARK_CENTRE + offset_x * radial;
            dot.y = MARK_CENTRE + offset_y * radial;
            dot.radius = DOT_RADIUS * (0.88 + 0.18 * level + 0.34 * crest);
            dot.brightness = (0.62 + 0.16 * level + 0.22 * crest).clamp(0.0, 1.0);
        }
        dots
    }

    /// Rasterise the current dots into a square luma frame of `size` pixels.
    pub(crate) fn render(&self, size: u32) -> VideoFrame {
        render_dots(&self.dots(), size)
    }
}

/// Draw the dots white-on-black with a one-pixel soft edge. Coverage is
/// accumulated with a saturating max so overlapping dots never seam.
pub(crate) fn render_dots(dots: &[Dot], size: u32) -> VideoFrame {
    let size = size.clamp(16, 1024);
    let mut luma = vec![0u8; (size as usize) * (size as usize)];
    let scale = size as f32 / MARK_EXTENT;
    for dot in dots {
        let centre_x = dot.x * scale;
        let centre_y = dot.y * scale;
        let radius = (dot.radius * scale).max(0.5);
        let peak = (dot.brightness * 255.0).clamp(0.0, 255.0);
        let min_x = ((centre_x - radius - 1.0).floor().max(0.0)) as u32;
        let max_x = ((centre_x + radius + 1.0).ceil().max(0.0) as u32).min(size);
        let min_y = ((centre_y - radius - 1.0).floor().max(0.0)) as u32;
        let max_y = ((centre_y + radius + 1.0).ceil().max(0.0) as u32).min(size);
        for y in min_y..max_y {
            for x in min_x..max_x {
                let dx = x as f32 + 0.5 - centre_x;
                let dy = y as f32 + 0.5 - centre_y;
                let distance = dx.hypot(dy);
                let coverage = ((radius - distance) + 0.5).clamp(0.0, 1.0);
                if coverage <= 0.0 {
                    continue;
                }
                let value = (peak * coverage) as u8;
                let index = (y as usize) * (size as usize) + x as usize;
                if luma[index] < value {
                    luma[index] = value;
                }
            }
        }
    }
    VideoFrame {
        width: size,
        height: size,
        luma,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(samples: usize, peak: i16) -> Vec<u8> {
        (0..samples)
            .flat_map(|index| {
                let value = if index % 2 == 0 { peak } else { -peak };
                value.to_le_bytes()
            })
            .collect()
    }

    #[test]
    fn amplitude_of_silence_is_zero() {
        assert_eq!(pcm16_amplitude(&[0u8; 320]), 0.0);
        assert_eq!(pcm16_amplitude(&[]), 0.0);
        assert_eq!(pcm16_amplitude(&[0x01]), 0.0);
    }

    #[test]
    fn amplitude_rises_with_level_and_saturates() {
        let quiet = pcm16_amplitude(&tone(160, 1_000));
        let loud = pcm16_amplitude(&tone(160, 12_000));
        assert!(quiet > 0.0 && quiet < loud);
        assert_eq!(pcm16_amplitude(&tone(160, i16::MAX)), 1.0);
    }

    #[test]
    fn level_attacks_faster_than_it_releases() {
        let mut animator = MarkAnimator::new();
        animator.observe_output(&tone(160, 12_000));
        animator.advance(1.0 / 30.0);
        let after_attack = animator.level();
        assert!(after_attack > 0.3, "attack was {after_attack}");
        animator.silence();
        animator.advance(1.0 / 30.0);
        let after_release = animator.level();
        assert!(after_release > after_attack * 0.5, "release was too abrupt");
        assert!(after_release < after_attack);
    }

    #[test]
    fn loudest_chunk_between_frames_wins() {
        let mut animator = MarkAnimator::new();
        animator.observe_output(&tone(160, 12_000));
        animator.observe_output(&tone(160, 100));
        animator.advance(1.0 / 30.0);
        let mut quiet_only = MarkAnimator::new();
        quiet_only.observe_output(&tone(160, 100));
        quiet_only.advance(1.0 / 30.0);
        assert!(animator.level() > quiet_only.level());
    }

    #[test]
    fn listening_ring_is_still_and_evenly_lit() {
        let animator = MarkAnimator::new();
        let dots = animator.dots();
        let first = dots[0];
        for dot in dots {
            assert!((dot.radius - first.radius).abs() < 1e-4);
            assert!((dot.brightness - first.brightness).abs() < 1e-4);
        }
        for (index, dot) in dots.iter().enumerate() {
            let (x, y) = DOTS[index];
            assert!((dot.x - x).abs() < 1e-3 && (dot.y - y).abs() < 1e-3);
        }
    }

    #[test]
    fn speaking_scatters_and_brightens_the_ring() {
        let mut animator = MarkAnimator::new();
        for _ in 0..12 {
            animator.observe_output(&tone(160, 20_000));
            animator.advance(1.0 / 30.0);
        }
        assert!(animator.level() > 0.8);
        let dots = animator.dots();
        let rest = MarkAnimator::new().dots();
        let spread: f32 = dots
            .iter()
            .zip(rest.iter())
            .map(|(now, rest)| (now.x - rest.x).hypot(now.y - rest.y))
            .sum();
        assert!(spread > 1.0, "ring did not move, spread {spread}");
        let brightest = dots.iter().map(|dot| dot.brightness).fold(0.0f32, f32::max);
        assert!(brightest > rest[0].brightness);
    }

    #[test]
    fn crest_travels_around_the_ring() {
        let mut animator = MarkAnimator::new();
        let mut brightest_over_time = Vec::new();
        for _ in 0..60 {
            animator.observe_output(&tone(160, 20_000));
            animator.advance(1.0 / 30.0);
            let dots = animator.dots();
            let (index, _) = dots.iter().enumerate().fold((0usize, -1.0f32), |best, it| {
                if it.1.brightness > best.1 {
                    (it.0, it.1.brightness)
                } else {
                    best
                }
            });
            brightest_over_time.push(index);
        }
        let distinct: std::collections::BTreeSet<_> = brightest_over_time.iter().collect();
        assert!(
            distinct.len() >= 3,
            "crest stayed put: {brightest_over_time:?}"
        );
    }

    #[test]
    fn silence_settles_the_ring_back_to_rest() {
        let mut animator = MarkAnimator::new();
        for _ in 0..12 {
            animator.observe_output(&tone(160, 20_000));
            animator.advance(1.0 / 30.0);
        }
        animator.silence();
        for _ in 0..400 {
            animator.advance(1.0 / 30.0);
        }
        assert_eq!(animator.level(), 0.0);
        let dots = animator.dots();
        for (index, dot) in dots.iter().enumerate() {
            let (x, y) = DOTS[index];
            assert!((dot.x - x).abs() < 1e-3 && (dot.y - y).abs() < 1e-3);
        }
    }

    #[test]
    fn frames_are_square_black_backed_and_have_lit_dots() {
        let frame = MarkAnimator::new().render(160);
        assert_eq!(frame.width, 160);
        assert_eq!(frame.height, 160);
        assert_eq!(frame.luma.len(), 160 * 160);
        assert_eq!(frame.luma[0], 0, "corner should be background");
        let lit = frame.luma.iter().filter(|value| **value > 8).count();
        assert!(lit > 0, "nothing was drawn");
        // Eight discs of radius ~17.2/260 of the frame: a small, bounded
        // fraction of the picture, which is what keeps it cheap at low
        // bitrate. Anything near a full frame means the raster blew up.
        assert!(lit < frame.luma.len() / 4, "mark covers too much: {lit}");
    }

    #[test]
    fn frame_size_is_clamped_to_a_sane_range() {
        assert_eq!(MarkAnimator::new().render(1).width, 16);
        assert_eq!(MarkAnimator::new().render(8192).width, 1024);
    }

    #[test]
    fn dots_stay_inside_the_frame_at_full_level() {
        let mut animator = MarkAnimator::new();
        for _ in 0..30 {
            animator.observe_output(&tone(160, i16::MAX));
            animator.advance(1.0 / 30.0);
        }
        for dot in animator.dots() {
            assert!(dot.x - dot.radius > -1.0 && dot.x + dot.radius < MARK_EXTENT + 1.0);
            assert!(dot.y - dot.radius > -1.0 && dot.y + dot.radius < MARK_EXTENT + 1.0);
        }
    }
}
