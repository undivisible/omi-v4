// Pure feature-bitmask assembly ported from transport.c `features_read_handler`.

pub const FEATURE_SPEAKER: u32 = 1 << 0;
pub const FEATURE_ACCELEROMETER: u32 = 1 << 1;
pub const FEATURE_BUTTON: u32 = 1 << 2;
pub const FEATURE_BATTERY: u32 = 1 << 3;
pub const FEATURE_USB: u32 = 1 << 4;
pub const FEATURE_HAPTIC: u32 = 1 << 5;
pub const FEATURE_OFFLINE_STORAGE: u32 = 1 << 6;
pub const FEATURE_LED_DIMMING: u32 = 1 << 7;
pub const FEATURE_MIC_GAIN: u32 = 1 << 8;
pub const FEATURE_CHARGING_STATE: u32 = 1 << 9;
pub const FEATURE_USER_EVENTS: u32 = 1 << 10;
pub const FEATURE_IMU_GESTURES: u32 = 1 << 11;
pub const FEATURE_HW_VAD: u32 = 1 << 12;
pub const FEATURE_BLE_SLEEP_CMD: u32 = 1 << 13;
pub const FEATURE_CAPTURE_STATE: u32 = 1 << 14;
pub const FEATURE_DEVICE_NAME_RW: u32 = 1 << 15;
/// WiFi SoftAP / home-STA sync. Upstream BasedHardware/omi used bit 9 for WIFI;
/// omi-v4 already uses bit 9 for FEATURE_CHARGING_STATE, so WIFI is bit 16.
pub const FEATURE_WIFI: u32 = 1 << 16;

/// Compile-time optional features passed from C (`IS_ENABLED(CONFIG_...)`).
#[derive(Copy, Clone, Debug, Default, PartialEq, Eq)]
pub struct FeatureFlags {
    pub speaker: bool,
    pub accelerometer: bool,
    pub button: bool,
    pub battery: bool,
    pub usb: bool,
    pub haptic: bool,
    pub offline_storage: bool,
    pub user_events: bool,
    pub imu_gestures: bool,
    pub hw_vad: bool,
    pub ble_sleep_cmd: bool,
    pub capture_state: bool,
    pub device_name_rw: bool,
    pub wifi: bool,
}

pub fn assemble(flags: &FeatureFlags) -> u32 {
    let mut features = 0u32;

    if flags.speaker {
        features |= FEATURE_SPEAKER;
    }
    if flags.accelerometer {
        features |= FEATURE_ACCELEROMETER;
    }
    if flags.button {
        features |= FEATURE_BUTTON;
    }
    if flags.battery {
        features |= FEATURE_BATTERY;
    }
    if flags.usb {
        features |= FEATURE_USB;
    }
    if flags.haptic {
        features |= FEATURE_HAPTIC;
    }
    if flags.offline_storage {
        features |= FEATURE_OFFLINE_STORAGE;
    }
    if flags.user_events {
        features |= FEATURE_USER_EVENTS;
    }
    if flags.imu_gestures {
        features |= FEATURE_IMU_GESTURES;
    }
    if flags.hw_vad {
        features |= FEATURE_HW_VAD;
    }
    if flags.ble_sleep_cmd {
        features |= FEATURE_BLE_SLEEP_CMD;
    }
    if flags.capture_state {
        features |= FEATURE_CAPTURE_STATE;
    }
    if flags.device_name_rw {
        features |= FEATURE_DEVICE_NAME_RW;
    }
    if flags.wifi {
        features |= FEATURE_WIFI;
    }

    // Always advertised in the settings service.
    features |= FEATURE_CHARGING_STATE;
    features |= FEATURE_LED_DIMMING;
    features |= FEATURE_MIC_GAIN;

    features
}

pub fn selftest() -> i32 {
    let mut failures = 0;

    let none = assemble(&FeatureFlags::default());
    let always_on = FEATURE_CHARGING_STATE | FEATURE_LED_DIMMING | FEATURE_MIC_GAIN;
    if none != always_on {
        failures += 1;
    }

    let all = assemble(&FeatureFlags {
        speaker: true,
        accelerometer: true,
        button: true,
        battery: true,
        usb: true,
        haptic: true,
        offline_storage: true,
        user_events: true,
        imu_gestures: true,
        hw_vad: true,
        ble_sleep_cmd: true,
        capture_state: true,
        device_name_rw: true,
        wifi: true,
    });
    if all & FEATURE_SPEAKER == 0 || all & FEATURE_DEVICE_NAME_RW == 0 {
        failures += 1;
    }
    if all & FEATURE_WIFI == 0 {
        failures += 1;
    }
    if all & always_on != always_on {
        failures += 1;
    }
    if FEATURE_WIFI == FEATURE_CHARGING_STATE {
        failures += 1;
    }

    failures
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn always_on_bits_are_set() {
        let features = assemble(&FeatureFlags::default());
        assert_ne!(features & FEATURE_CHARGING_STATE, 0);
        assert_ne!(features & FEATURE_LED_DIMMING, 0);
        assert_ne!(features & FEATURE_MIC_GAIN, 0);
    }

    #[test]
    fn optional_bits_follow_flags() {
        let features = assemble(&FeatureFlags {
            speaker: true,
            button: true,
            wifi: true,
            ..FeatureFlags::default()
        });
        assert_ne!(features & FEATURE_SPEAKER, 0);
        assert_ne!(features & FEATURE_BUTTON, 0);
        assert_ne!(features & FEATURE_WIFI, 0);
        assert_eq!(features & FEATURE_BATTERY, 0);
        assert_ne!(FEATURE_WIFI, FEATURE_CHARGING_STATE);
    }

    #[test]
    fn selftest_passes() {
        assert_eq!(selftest(), 0);
    }
}
