// Settings value clamps and lsm6dsl_time_base blob parse/normalize.

pub const MAX_DIM_RATIO: u8 = 100;
pub const MAX_MIC_GAIN: u8 = 8;

pub const LSM6DSL_TIME_BASE_SIZE: usize = 16;
pub const LSM6DSL_TIME_BASE_LEGACY_SIZE: usize = 12;

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Lsm6dslTimeBase {
    pub epoch_s: u64,
    pub ts: u32,
    pub reserved: u32,
}

pub fn clamp_dim_ratio(value: u8) -> u8 {
    if value > MAX_DIM_RATIO {
        MAX_DIM_RATIO
    } else {
        value
    }
}

pub fn clamp_mic_gain(value: u8) -> u8 {
    if value > MAX_MIC_GAIN {
        MAX_MIC_GAIN
    } else {
        value
    }
}

/// Map clamped gain level 0..=8 to the nRF PDM hardware gain byte.
pub fn mic_hw_gain(level: u8) -> u8 {
    const GAIN_MAP: [u8; 9] = [
        0x00, // Level 0: mute
        0x14, // Level 1: -20dB
        0x1E, // Level 2: -10dB
        0x28, // Level 3: +0dB
        0x2E, // Level 4: +6dB
        0x32, // Level 5: +10dB
        0x3C, // Level 6: +20dB (default)
        0x46, // Level 7: +30dB
        0x50, // Level 8: +40dB
    ];
    GAIN_MAP[usize::from(clamp_mic_gain(level))]
}

/// Parse a 16-byte full or 12-byte legacy `lsm6dsl_time_base` blob.
pub fn parse_lsm6dsl_time_base(bytes: &[u8]) -> Result<Lsm6dslTimeBase, i32> {
    match bytes.len() {
        LSM6DSL_TIME_BASE_SIZE => {
            let epoch_s = u64::from_le_bytes(bytes[0..8].try_into().unwrap());
            let ts = u32::from_le_bytes(bytes[8..12].try_into().unwrap());
            let reserved = u32::from_le_bytes(bytes[12..16].try_into().unwrap());
            Ok(Lsm6dslTimeBase {
                epoch_s,
                ts,
                reserved,
            })
        }
        LSM6DSL_TIME_BASE_LEGACY_SIZE => {
            let epoch_s = u64::from_le_bytes(bytes[0..8].try_into().unwrap());
            let ts = u32::from_le_bytes(bytes[8..12].try_into().unwrap());
            Ok(Lsm6dslTimeBase {
                epoch_s,
                ts,
                reserved: 0,
            })
        }
        _ => Err(-22),
    }
}

pub fn selftest() -> i32 {
    let mut failures = 0;

    if clamp_dim_ratio(0) != 0 || clamp_dim_ratio(100) != 100 || clamp_dim_ratio(101) != 100 {
        failures += 1;
    }
    if clamp_mic_gain(0) != 0 || clamp_mic_gain(8) != 8 || clamp_mic_gain(9) != 8 {
        failures += 1;
    }
    if mic_hw_gain(0) != 0x00 || mic_hw_gain(6) != 0x3C || mic_hw_gain(9) != 0x50 {
        failures += 1;
    }

    let mut full = [0u8; LSM6DSL_TIME_BASE_SIZE];
    full[0..8].copy_from_slice(&42u64.to_le_bytes());
    full[8..12].copy_from_slice(&0xAABB_CCDDu32.to_le_bytes());
    full[12..16].copy_from_slice(&7u32.to_le_bytes());
    let parsed = parse_lsm6dsl_time_base(&full).unwrap();
    if parsed.epoch_s != 42 || parsed.ts != 0xAABB_CCDD || parsed.reserved != 7 {
        failures += 1;
    }

    let mut legacy = [0u8; LSM6DSL_TIME_BASE_LEGACY_SIZE];
    legacy[0..8].copy_from_slice(&99u64.to_le_bytes());
    legacy[8..12].copy_from_slice(&0x0102_0304u32.to_le_bytes());
    let legacy_parsed = parse_lsm6dsl_time_base(&legacy).unwrap();
    if legacy_parsed.epoch_s != 99 || legacy_parsed.ts != 0x0102_0304 || legacy_parsed.reserved != 0
    {
        failures += 1;
    }

    if parse_lsm6dsl_time_base(&[0u8; 8]).is_ok() {
        failures += 1;
    }

    failures
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clamps_match_c() {
        assert_eq!(clamp_dim_ratio(50), 50);
        assert_eq!(clamp_dim_ratio(150), 100);
        assert_eq!(clamp_mic_gain(6), 6);
        assert_eq!(clamp_mic_gain(12), 8);
        assert_eq!(mic_hw_gain(1), 0x14);
        assert_eq!(mic_hw_gain(8), 0x50);
    }

    #[test]
    fn lsm6dsl_full_and_legacy() {
        let mut full = [0u8; 16];
        full[0..8].copy_from_slice(&1u64.to_le_bytes());
        full[8..12].copy_from_slice(&2u32.to_le_bytes());
        full[12..16].copy_from_slice(&3u32.to_le_bytes());
        assert_eq!(
            parse_lsm6dsl_time_base(&full).unwrap(),
            Lsm6dslTimeBase {
                epoch_s: 1,
                ts: 2,
                reserved: 3,
            }
        );

        let mut legacy = [0u8; 12];
        legacy[0..8].copy_from_slice(&4u64.to_le_bytes());
        legacy[8..12].copy_from_slice(&5u32.to_le_bytes());
        assert_eq!(
            parse_lsm6dsl_time_base(&legacy).unwrap(),
            Lsm6dslTimeBase {
                epoch_s: 4,
                ts: 5,
                reserved: 0,
            }
        );
        assert!(parse_lsm6dsl_time_base(&[0u8; 4]).is_err());
    }
}
