// RTC uptime extrapolation, IMU 24-bit timestamp delta, and (on-target) the
// soft-clock state + mutex. Persist work / settings / SD notify stay in C.

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

pub const UTC_DATETIME_LEN: usize = 20;

/*
 * Howard Hinnant's algorithm: convert days since 1970-01-01 into Y-M-D.
 * Works for a wide range of dates with only integer math.
 */
pub fn format_utc_datetime(utc_epoch_s: u64, out: &mut [u8]) -> Result<(), i32> {
    if out.len() < UTC_DATETIME_LEN {
        if let Some(first) = out.first_mut() {
            *first = 0;
        }
        return Err(-28);
    }

    let mut days = (utc_epoch_s / 86_400) as i64;
    let sod = (utc_epoch_s % 86_400) as u32;
    days += 719_468;
    let era = if days >= 0 {
        days / 146_097
    } else {
        (days - 146_096) / 146_097
    };
    let doe = (days - era * 146_097) as u32;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let mut year = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = mp as i64 + if mp < 10 { 3 } else { -9 };
    if month <= 2 {
        year += 1;
    }
    if !(0..=9_999).contains(&year) {
        out[0] = 0;
        return Err(-34);
    }

    let hour = sod / 3_600;
    let minute = (sod % 3_600) / 60;
    let second = sod % 60;
    let fields = [
        (year as u32, 4, 0),
        (month as u32, 2, 5),
        (day, 2, 8),
        (hour, 2, 11),
        (minute, 2, 14),
        (second, 2, 17),
    ];
    out[..UTC_DATETIME_LEN].fill(b'0');
    out[4] = b'-';
    out[7] = b'-';
    out[10] = b' ';
    out[13] = b':';
    out[16] = b':';
    out[19] = 0;
    for (value, width, start) in fields {
        let mut value = value;
        for index in (start..start + width).rev() {
            out[index] = b'0' + (value % 10) as u8;
            value /= 10;
        }
    }
    Ok(())
}

/// Wrap-safe 24-bit IMU timestamp delta → new epoch milliseconds.
pub fn imu_boot_epoch_ms(base_epoch_s: u64, base_ts: u32, ts_now: u32) -> u64 {
    let delta_ticks = (ts_now.wrapping_sub(base_ts)) & IMU_TIMESTAMP_MASK;
    let delta_us = u64::from(delta_ticks) * IMU_TIMESTAMP_TICK_US;
    let delta_ms = delta_us / 1000;
    base_epoch_s.saturating_mul(1000).saturating_add(delta_ms)
}

#[cfg(target_os = "none")]
mod soft_clock {
    use core::sync::atomic::{AtomicBool, Ordering};

    use zephyr::sync::Mutex;
    use zephyr::sys::uptime_get;

    use super::{extrapolate_utc_ms, utc_seconds_clamped};

    struct SoftClock {
        base_epoch_ms: u64,
        base_uptime_ms: i64,
        utc_valid: bool,
        pending_epoch_to_persist: u64,
    }

    impl SoftClock {
        const fn new() -> Self {
            Self {
                base_epoch_ms: 0,
                base_uptime_ms: 0,
                utc_valid: false,
                pending_epoch_to_persist: 0,
            }
        }
    }

    static CLOCK: Mutex<SoftClock> = Mutex::new(SoftClock::new());
    static INIT: AtomicBool = AtomicBool::new(false);

    pub fn init() {
        if INIT.swap(true, Ordering::AcqRel) {
            return;
        }
        let _ = CLOCK.lock();
    }

    pub fn is_valid() -> bool {
        CLOCK.lock().unwrap().utc_valid
    }

    pub fn get_utc_ms() -> u64 {
        let guard = CLOCK.lock().unwrap();
        if !guard.utc_valid {
            return 0;
        }
        extrapolate_utc_ms(guard.base_epoch_ms, guard.base_uptime_ms, uptime_get())
    }

    pub fn get_utc_s() -> u32 {
        utc_seconds_clamped(get_utc_ms())
    }

    pub fn set_utc_ms(utc_epoch_ms: u64) -> i32 {
        if utc_epoch_ms == 0 {
            return -22;
        }
        let mut guard = CLOCK.lock().unwrap();
        guard.base_epoch_ms = utc_epoch_ms;
        guard.base_uptime_ms = uptime_get();
        guard.utc_valid = true;
        0
    }

    pub fn set_pending_persist(epoch_s: u64) {
        CLOCK.lock().unwrap().pending_epoch_to_persist = epoch_s;
    }

    pub fn take_pending_persist() -> u64 {
        CLOCK.lock().unwrap().pending_epoch_to_persist
    }

    pub fn restore_from_epoch_s(saved_epoch_s: u64) {
        let mut guard = CLOCK.lock().unwrap();
        if saved_epoch_s == 0 {
            guard.utc_valid = false;
            return;
        }
        guard.base_epoch_ms = saved_epoch_s.saturating_mul(1000);
        guard.base_uptime_ms = uptime_get();
        guard.utc_valid = true;
    }

    pub fn invalidate() {
        CLOCK.lock().unwrap().utc_valid = false;
    }
}

#[cfg(target_os = "none")]
pub use soft_clock::{
    get_utc_ms as clock_get_utc_ms, get_utc_s as clock_get_utc_s, init as clock_init,
    invalidate as clock_invalidate, is_valid as clock_is_valid,
    restore_from_epoch_s as clock_restore_from_epoch_s, set_pending_persist as clock_set_pending,
    set_utc_ms as clock_set_utc_ms, take_pending_persist as clock_take_pending,
};

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
    let mut datetime = [0u8; UTC_DATETIME_LEN];
    if format_utc_datetime(0, &mut datetime).is_err() || datetime != *b"1970-01-01 00:00:00\0" {
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

    #[test]
    fn formats_utc_datetime_and_rejects_short_buffers() {
        let mut out = [0u8; UTC_DATETIME_LEN];
        format_utc_datetime(1_709_251_199, &mut out).unwrap();
        assert_eq!(&out, b"2024-02-29 23:59:59\0");

        let mut short = [b'x'; UTC_DATETIME_LEN - 1];
        assert_eq!(format_utc_datetime(0, &mut short), Err(-28));
        assert_eq!(short[0], 0);
    }
}
