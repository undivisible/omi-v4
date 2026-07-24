// RTC uptime extrapolation and IMU 24-bit timestamp delta. Zephyr uptime /
// I2C / mutex stay in C.

pub const IMU_TIMESTAMP_TICK_US: u64 = 6400;
pub const IMU_TIMESTAMP_MASK: u32 = 0x00FF_FFFF;

/// `now_ms = base_epoch_ms + max(0, uptime_ms - base_uptime_ms)`.
pub fn extrapolate_utc_ms(base_epoch_ms: u64, base_uptime_ms: i64, now_uptime_ms: i64) -> u64 {
    let mut delta_ms = now_uptime_ms - base_uptime_ms;
    if delta_ms < 0 {
        delta_ms = 0;
    }
    base_epoch_ms + delta_ms as u64
}

/// Truncate ms → seconds for the GATT-facing `get_utc_time` u32.
pub fn utc_seconds_clamped(now_ms: u64) -> u32 {
    if now_ms == 0 {
        return 0;
    }
    let now_s = now_ms / 1000;
    if now_s > u64::from(u32::MAX) {
        u32::MAX
    } else {
        now_s as u32
    }
}

/// Wrap-safe 24-bit IMU timestamp delta → new epoch milliseconds.
pub fn imu_boot_epoch_ms(base_epoch_s: u64, base_ts: u32, ts_now: u32) -> u64 {
    let delta_ticks = (ts_now.wrapping_sub(base_ts)) & IMU_TIMESTAMP_MASK;
    let delta_us = u64::from(delta_ticks) * IMU_TIMESTAMP_TICK_US;
    let delta_ms = delta_us / 1000;
    base_epoch_s.saturating_mul(1000).saturating_add(delta_ms)
}

pub fn selftest() -> i32 {
    let mut failures = 0;
    if extrapolate_utc_ms(1_000, 100, 250) != 1_150 {
        failures += 1;
    }
    if extrapolate_utc_ms(1_000, 100, 50) != 1_000 {
        failures += 1;
    }
    if utc_seconds_clamped(0) != 0 || utc_seconds_clamped(2500) != 2 {
        failures += 1;
    }
    // 10 ticks * 6400 us = 64000 us = 64 ms; base 1s → 1064 ms.
    if imu_boot_epoch_ms(1, 0, 10) != 1064 {
        failures += 1;
    }
    // Wrap across 24-bit boundary: base near top, now small.
    if imu_boot_epoch_ms(0, 0x00FF_FFFE, 1) != 19 {
        // delta ticks = 3; 3*6400/1000 = 19
        failures += 1;
    }
    failures
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extrapolate_clamps_negative_delta() {
        assert_eq!(extrapolate_utc_ms(5000, 1000, 900), 5000);
        assert_eq!(extrapolate_utc_ms(5000, 1000, 1500), 5500);
    }

    #[test]
    fn imu_wrap_and_scale() {
        assert_eq!(imu_boot_epoch_ms(10, 0, 100), 10_000 + 640);
        assert_eq!(imu_boot_epoch_ms(0, 0x00FF_FFFE, 1), 19);
    }
}
