//! The perceptual hash the similarity gate is built on.
//!
//! The preview the difference hash is computed over: nine columns by eight
//! rows of luminance. The native side downscales the screen to roughly eighty
//! pixels wide and hands back these 72 bytes, so the similarity check never
//! touches a full-resolution frame and never decodes an encoded one.

pub const PREVIEW_WIDTH: usize = 9;
pub const PREVIEW_HEIGHT: usize = 8;
pub const PREVIEW_LENGTH: usize = PREVIEW_WIDTH * PREVIEW_HEIGHT;

/// A 64-bit difference hash: one bit per horizontally adjacent pair, set when
/// the left sample is brighter than the right. Robust to the small luminance
/// drift of a cursor blink or an antialiased character, sensitive to a scroll
/// or a new window.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct PreviewHash(u64);

impl PreviewHash {
    pub const EMPTY: Self = Self(0);

    /// Builds a hash from a [`PREVIEW_LENGTH`]-byte luminance preview. Returns
    /// `None` for any other length rather than guessing at the layout — a
    /// short buffer is a failed capture, not a dark screen, and treating it as
    /// a hash would let the similarity gate skip real frames.
    pub fn from_luma(luma: &[u8]) -> Option<Self> {
        if luma.len() != PREVIEW_LENGTH {
            return None;
        }
        let mut bits = 0_u64;
        let mut bit = 0_u32;
        for row in 0..PREVIEW_HEIGHT {
            let offset = row * PREVIEW_WIDTH;
            for column in 0..PREVIEW_WIDTH - 1 {
                if luma[offset + column] > luma[offset + column + 1] {
                    bits |= 1_u64 << bit;
                }
                bit += 1;
            }
        }
        Some(Self(bits))
    }

    /// Reads a hash back out of the on-disk index. The stored form is the
    /// sixteen-hex-digit rendering [`Self::to_hex`] writes.
    pub fn try_parse(hex: &str) -> Option<Self> {
        if hex.is_empty() {
            return None;
        }
        u64::from_str_radix(hex, 16).ok().map(Self)
    }

    /// Number of differing bits. Zero means the two previews are identical.
    pub fn distance_to(self, other: Self) -> u32 {
        (self.0 ^ other.0).count_ones()
    }

    pub fn to_hex(self) -> String {
        format!("{:016x}", self.0)
    }
}

#[cfg(test)]
mod tests {
    use super::{PREVIEW_LENGTH, PreviewHash};

    fn luma(step: usize) -> Vec<u8> {
        (0..PREVIEW_LENGTH)
            .map(|index| u8::try_from((index * step) % 251).unwrap_or_default())
            .collect()
    }

    /// Ported from `rewind_store_test.dart`, "the difference hash is stable,
    /// and sensitive to real change".
    #[test]
    fn the_difference_hash_is_stable_and_sensitive_to_real_change() {
        let flat = vec![0_u8; PREVIEW_LENGTH];
        let ramp = luma(37);
        let (Some(first), Some(second), Some(changed)) = (
            PreviewHash::from_luma(&flat),
            PreviewHash::from_luma(&flat),
            PreviewHash::from_luma(&ramp),
        ) else {
            panic!("a full-length preview always hashes");
        };
        assert_eq!(first.distance_to(second), 0);
        assert!(first.distance_to(changed) > 3);
        assert_eq!(PreviewHash::try_parse(&changed.to_hex()), Some(changed));
        assert_eq!(PreviewHash::from_luma(&[0, 0, 0, 0]), None);
    }

    #[test]
    fn the_hex_rendering_is_sixteen_digits_and_round_trips_the_top_bit() {
        // The last pair of the last row sets bit 63; a signed rendering would
        // lose it, which is why the stored form is fixed-width unsigned hex.
        let mut preview = vec![0_u8; PREVIEW_LENGTH];
        preview[PREVIEW_LENGTH - 2] = 255;
        let Some(hash) = PreviewHash::from_luma(&preview) else {
            panic!("a full-length preview always hashes");
        };
        let hex = hash.to_hex();
        assert_eq!(hex.len(), 16);
        assert_eq!(PreviewHash::try_parse(&hex), Some(hash));
        assert_eq!(PreviewHash::try_parse(""), None);
        assert_eq!(PreviewHash::try_parse("not hex"), None);
    }
}
