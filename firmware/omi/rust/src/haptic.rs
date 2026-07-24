// Pure BLE write → duration map and duration clamp. GPIO and the delayable
// work item stay in C.

pub const MAX_HAPTIC_DURATION_MS: u32 = 5000;

pub fn duration_from_ble_value(value: u8) -> Option<u32> {
    match value {
        1 => Some(100),
        2 => Some(300),
        3 => Some(500),
        _ => None,
    }
}

pub fn clamp_duration(duration: u32) -> u32 {
    if duration > MAX_HAPTIC_DURATION_MS {
        MAX_HAPTIC_DURATION_MS
    } else {
        duration
    }
}

pub fn selftest() -> i32 {
    let mut failures = 0;
    if duration_from_ble_value(1) != Some(100) {
        failures += 1;
    }
    if duration_from_ble_value(2) != Some(300) {
        failures += 1;
    }
    if duration_from_ble_value(3) != Some(500) {
        failures += 1;
    }
    if duration_from_ble_value(0).is_some() || duration_from_ble_value(4).is_some() {
        failures += 1;
    }
    if clamp_duration(0) != 0 || clamp_duration(100) != 100 {
        failures += 1;
    }
    if clamp_duration(MAX_HAPTIC_DURATION_MS + 1) != MAX_HAPTIC_DURATION_MS {
        failures += 1;
    }
    failures
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ble_value_map_matches_c() {
        assert_eq!(duration_from_ble_value(1), Some(100));
        assert_eq!(duration_from_ble_value(2), Some(300));
        assert_eq!(duration_from_ble_value(3), Some(500));
        assert_eq!(duration_from_ble_value(9), None);
    }

    #[test]
    fn clamp_caps_at_max() {
        assert_eq!(clamp_duration(0), 0);
        assert_eq!(clamp_duration(5000), 5000);
        assert_eq!(clamp_duration(5001), 5000);
    }
}
