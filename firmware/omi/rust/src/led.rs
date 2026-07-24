// Pure PWM pulse-width math ported from firmware/omi/src/led.c. The PWM
// devices and Zephyr `pwm_set_pulse_dt` calls stay in C.

/// Computes the on-pulse width in nanoseconds for a given PWM period and
/// brightness level (0–100 percent). Levels above 100 are clamped.
pub fn pulse_width_ns(period_ns: u32, level: u8) -> u32 {
    let level = if level > 100 { 100 } else { level };
    (period_ns * u32::from(level)) / 100
}

pub fn selftest() -> i32 {
    let mut failures = 0;
    if pulse_width_ns(1000, 0) != 0 {
        failures += 1;
    }
    if pulse_width_ns(1000, 50) != 500 {
        failures += 1;
    }
    if pulse_width_ns(1000, 100) != 1000 {
        failures += 1;
    }
    if pulse_width_ns(1000, 150) != 1000 {
        failures += 1;
    }
    failures
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pulse_width_scales_and_clamps() {
        assert_eq!(pulse_width_ns(20_000, 0), 0);
        assert_eq!(pulse_width_ns(20_000, 25), 5_000);
        assert_eq!(pulse_width_ns(20_000, 100), 20_000);
        assert_eq!(pulse_width_ns(20_000, 200), 20_000);
    }
}
