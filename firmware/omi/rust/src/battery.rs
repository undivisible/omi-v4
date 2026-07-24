// State-of-charge math ported verbatim from firmware/omi/src/battery.c: voltage
// lookup, EMA, ADC median/divider, and the percentage filter state machine.
// SAADC sampling, charge GPIO ISR, and the battery mutex stay in C.
//
// The calibration constants — the 16-entry discharge and charging curves, the
// 65535/(N+1) alpha, and the +32768 rounding bias — are reproduced exactly.
// Changing any of them changes what the fuel gauge reads.

pub const BATTERY_STATES_COUNT: usize = 16;
pub const ADC_TOTAL_SAMPLES: usize = 50;
pub const FILTER_INIT_CYCLES: u8 = 5;
pub const DIVIDER_R1: u16 = 1091;
pub const DIVIDER_R2: u16 = 499;
pub const CHARGE_SKEW_MV: i32 = 16;

/// One point on a LiPo discharge/charge profile: open-circuit millivolts and the
/// percentage assigned to it. Mirrors the C `BatteryState`.
#[derive(Copy, Clone)]
pub struct BatteryState {
    pub millivolts: u16,
    pub percentage: u8,
}

const fn state(millivolts: u16, percentage: u8) -> BatteryState {
    BatteryState {
        millivolts,
        percentage,
    }
}

// 150mAh LiPo battery discharge profile
pub static BATTERY_DISCHARGE_STATES: [BatteryState; BATTERY_STATES_COUNT] = [
    state(4140, 100),
    state(4135, 99),
    state(4091, 91),
    state(4020, 78),
    state(3938, 63),
    state(3884, 53),
    state(3791, 36),
    state(3785, 35),
    state(3671, 14),
    state(3655, 11),
    state(3600, 1), // Threshold for <1%
    state(0000, 0), // Below safe level
    state(0, 0),
    state(0, 0),
    state(0, 0),
    state(0, 0),
];

pub static BATTERY_CHARGING_STATES: [BatteryState; BATTERY_STATES_COUNT] = [
    state(4200, 100),
    state(4195, 99),
    state(4159, 91),
    state(4100, 78),
    state(4032, 63),
    state(3986, 53),
    state(3909, 36),
    state(3905, 35),
    state(3809, 14),
    state(3795, 11),
    state(3750, 1), // Threshold for <1%
    state(0000, 0), // Below safe level
    state(0, 0),
    state(0, 0),
    state(0, 0),
    state(0, 0),
];

// BATTERY_FILTER_ALPHA_U16 = 65535/(5+1). Integer division, exactly as the C
// macro evaluates it.
const BATTERY_FILTER_ALPHA_U16: u32 = 65535 / (5 + 1);

fn battery_states(is_charging: bool) -> &'static [BatteryState; BATTERY_STATES_COUNT] {
    if is_charging {
        &BATTERY_CHARGING_STATES
    } else {
        &BATTERY_DISCHARGE_STATES
    }
}

/// Voltage-to-percentage lookup with linear interpolation, matching the body of
/// `battery_get_percentage` before the EMA stage. Pure: the caller supplies the
/// charging flag the C reads from the `is_charging` global.
pub fn raw_percentage(battery_millivolt: u16, is_charging: bool) -> u8 {
    let states = battery_states(is_charging);

    if battery_millivolt >= states[0].millivolts {
        return states[0].percentage;
    }
    if battery_millivolt <= states[BATTERY_STATES_COUNT - 1].millivolts {
        return states[BATTERY_STATES_COUNT - 1].percentage;
    }

    for i in 0..BATTERY_STATES_COUNT - 1 {
        if battery_millivolt <= states[i].millivolts && battery_millivolt > states[i + 1].millivolts
        {
            // Linear interpolation between the two closest points
            let voltage_range = states[i].millivolts - states[i + 1].millivolts;
            let percentage_range = states[i].percentage - states[i + 1].percentage;
            let voltage_diff = states[i].millivolts - battery_millivolt;

            return states[i].percentage
                - ((u32::from(voltage_diff) * u32::from(percentage_range))
                    / u32::from(voltage_range)) as u8;
        }
    }

    0
}

/// One EMA smoothing step, ported from `update_ema_filter`. The edge-case
/// transitions near the rails and the 16-bit fixed-point average with round-up
/// are reproduced exactly.
pub fn ema_step(current_ema: u32, new_value: u8, is_charging: bool) -> u8 {
    // handle edge case transitions directly
    if (!is_charging && current_ema <= 5) || (is_charging && current_ema >= 95) {
        if is_charging {
            return if u32::from(new_value) > current_ema {
                (current_ema + 1) as u8
            } else {
                current_ema as u8
            };
        }
        return if u32::from(new_value) < current_ema {
            (current_ema - 1) as u8
        } else {
            current_ema as u8
        };
    }

    // Constant coefficient Alpha for EMA calculation, scaled to 16 bit.
    // Alpha = 65535/(N+1) where N is the averaging window
    let alpha = BATTERY_FILTER_ALPHA_U16;
    let alpha_complement = u32::from(u16::MAX) - BATTERY_FILTER_ALPHA_U16;

    // Calculate new EMA: new_ema = (alpha * new_value + alpha_complement * current_ema) / 65535
    let new_ema: u64 =
        u64::from(alpha * u32::from(new_value)) + u64::from(alpha_complement * current_ema);

    // Scale result back to 8-bit, with rounding up
    ((new_ema + 32768) >> 16) as u8
}

/// Bubble-sort median of `samples` (mutates in place). Empty → 0.
pub fn median_i16(samples: &mut [i16]) -> i32 {
    let n = samples.len();
    if n == 0 {
        return 0;
    }
    for i in 0..n - 1 {
        for j in 0..n - i - 1 {
            if samples[j] > samples[j + 1] {
                samples.swap(j, j + 1);
            }
        }
    }
    if n.is_multiple_of(2) {
        (i32::from(samples[n / 2 - 1]) + i32::from(samples[n / 2])) / 2
    } else {
        i32::from(samples[n / 2])
    }
}

pub fn apply_charge_skew(adc_pin_mv: i32, is_charging: bool) -> i32 {
    if is_charging {
        adc_pin_mv - CHARGE_SKEW_MV
    } else {
        adc_pin_mv
    }
}

/// Voltage-divider scale matching C's float cast to `uint16_t`.
pub fn divider_to_battery_mv(adc_pin_mv: i32) -> u16 {
    (adc_pin_mv as f32 * ((u32::from(DIVIDER_R1) + u32::from(DIVIDER_R2)) as f32
        / f32::from(DIVIDER_R2))) as u16
}

/// Monotonic clamp + EMA init/step for `battery_get_percentage`.
pub struct PercentageFilter {
    ema: u8,
    initialized: bool,
    init_counter: u8,
}

impl Default for PercentageFilter {
    fn default() -> Self {
        Self::new()
    }
}

impl PercentageFilter {
    pub const fn new() -> Self {
        Self {
            ema: 0,
            initialized: false,
            init_counter: 0,
        }
    }

    pub fn step(&mut self, mut raw_percentage: u8, is_charging: bool) -> u8 {
        if self.ema != 0
            && ((is_charging && raw_percentage < self.ema)
                || (!is_charging && raw_percentage > self.ema))
        {
            raw_percentage = self.ema;
        }

        if !self.initialized {
            self.ema = raw_percentage;
            self.init_counter = self.init_counter.saturating_add(1);
            if self.init_counter >= FILTER_INIT_CYCLES {
                self.initialized = true;
            }
            raw_percentage
        } else {
            self.ema = ema_step(u32::from(self.ema), raw_percentage, is_charging);
            self.ema
        }
    }
}

static mut PERCENTAGE_FILTER: PercentageFilter = PercentageFilter::new();
static FIRST_MEASUREMENT: core::sync::atomic::AtomicBool =
    core::sync::atomic::AtomicBool::new(true);

/// Returns true on the first call (C should treat as `-EAGAIN` skip).
pub fn consume_first_measurement() -> bool {
    FIRST_MEASUREMENT.swap(false, core::sync::atomic::Ordering::AcqRel)
}

pub fn percentage_step(raw_percentage: u8, is_charging: bool) -> u8 {
    // SAFETY: battery mutex in C serializes callers.
    unsafe {
        (&raw mut PERCENTAGE_FILTER)
            .as_mut()
            .unwrap_unchecked()
            .step(raw_percentage, is_charging)
    }
}

pub fn selftest() -> i32 {
    let mut failures = 0;
    let mut samples = [3i16, 1, 2, 9, 5];
    if median_i16(&mut samples) != 3 {
        failures += 1;
    }
    if apply_charge_skew(100, true) != 84 || apply_charge_skew(100, false) != 100 {
        failures += 1;
    }
    if divider_to_battery_mv(1000) == 0 {
        failures += 1;
    }
    let mut filt = PercentageFilter::new();
    let p0 = filt.step(50, false);
    if p0 != 50 {
        failures += 1;
    }
    failures
}

#[cfg(test)]
mod tests {
    use super::*;

    // Reference reimplementation of the C lookup, used to cross-check the port
    // across the whole voltage sweep rather than at a handful of points.
    fn c_reference(mv: u16, charging: bool) -> u8 {
        let s = battery_states(charging);
        if mv >= s[0].millivolts {
            return s[0].percentage;
        }
        if mv <= s[BATTERY_STATES_COUNT - 1].millivolts {
            return s[BATTERY_STATES_COUNT - 1].percentage;
        }
        for i in 0..BATTERY_STATES_COUNT - 1 {
            if mv <= s[i].millivolts && mv > s[i + 1].millivolts {
                let vr = (s[i].millivolts - s[i + 1].millivolts) as u32;
                let pr = (s[i].percentage - s[i + 1].percentage) as u32;
                let vd = (s[i].millivolts - mv) as u32;
                return (s[i].percentage as u32 - (vd * pr) / vr) as u8;
            }
        }
        0
    }

    #[test]
    fn raw_percentage_pins_the_curve_endpoints() {
        assert_eq!(raw_percentage(5000, false), 100);
        assert_eq!(raw_percentage(4140, false), 100);
        assert_eq!(raw_percentage(3600, false), 1);
        // Below the last real point the C interpolates toward {0,0}; only 0mV
        // lands on the zero endpoint exactly.
        assert_eq!(raw_percentage(0, false), 0);
        assert_eq!(raw_percentage(4200, true), 100);
        assert_eq!(raw_percentage(3750, true), 1);
    }

    #[test]
    fn raw_percentage_interpolates_between_points() {
        // Midpoint between {4020,78} and {3938,63}: 41mV of a 82mV span, 15pp
        // range -> 78 - (41*15)/82 = 78 - 7 = 71.
        assert_eq!(raw_percentage(3979, false), 71);
    }

    #[test]
    fn raw_percentage_matches_reference_across_the_sweep() {
        for mv in 0u16..=4300 {
            assert_eq!(raw_percentage(mv, false), c_reference(mv, false), "mv={mv}");
            assert_eq!(raw_percentage(mv, true), c_reference(mv, true), "mv={mv}");
        }
    }

    #[test]
    fn ema_edge_cases_creep_one_step() {
        // Discharging near the floor: only moves down, one at a time.
        assert_eq!(ema_step(5, 0, false), 4);
        assert_eq!(ema_step(5, 9, false), 5);
        // Charging near the ceiling: only moves up, one at a time.
        assert_eq!(ema_step(95, 100, true), 96);
        assert_eq!(ema_step(95, 10, true), 95);
    }

    #[test]
    fn ema_matches_the_fixed_point_average() {
        // alpha = 65535/6 = 10922; complement = 65535 - 10922 = 54613.
        // new = (10922*80 + 54613*50 + 32768) >> 16
        //     = (873760 + 2730650 + 32768) >> 16 = 3637178 >> 16 = 55.
        assert_eq!(ema_step(50, 80, false), 55);
    }

    #[test]
    fn median_and_divider() {
        let mut even = [4i16, 1, 3, 2];
        assert_eq!(median_i16(&mut even), 2);
        assert_eq!(apply_charge_skew(200, true), 184);
        let mv = divider_to_battery_mv(1000);
        assert!(mv > 3000 && mv < 3300);
    }

    #[test]
    fn percentage_filter_init_then_ema() {
        let mut f = PercentageFilter::new();
        for _ in 0..FILTER_INIT_CYCLES {
            assert_eq!(f.step(40, false), 40);
        }
        assert!(f.init_counter >= FILTER_INIT_CYCLES || f.initialized);
        let next = f.step(80, false);
        assert_ne!(next, 80);
    }
}
