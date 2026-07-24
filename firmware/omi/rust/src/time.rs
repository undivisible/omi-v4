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
