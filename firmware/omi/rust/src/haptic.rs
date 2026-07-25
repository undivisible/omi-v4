// Pure BLE write → duration map and duration clamp. On-target motor GPIO
// uses the zephyr crate; delayable off work and BLE GATT stay in C.

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

#[cfg(target_os = "none")]
mod motor {
    use core::cell::UnsafeCell;
    use core::sync::atomic::{AtomicBool, Ordering};

    use zephyr::device::gpio::GpioPin;
    use zephyr::raw::{ENODEV, ZR_GPIO_OUTPUT};

    struct Slot(UnsafeCell<Option<GpioPin>>);
    // SAFETY: access is gated by INIT and only from cooperative contexts that
    // already serialized the C haptic API.
    unsafe impl Sync for Slot {}

    static SLOT: Slot = Slot(UnsafeCell::new(None));
    static INIT: AtomicBool = AtomicBool::new(false);

    pub fn init() -> i32 {
        if INIT.load(Ordering::Acquire) {
            return 0;
        }
        let Some(mut pin) = zephyr::devicetree::labels::motor_pin::get_instance() else {
            return -(ENODEV as i32);
        };
        pin.configure(ZR_GPIO_OUTPUT);
        // SAFETY: first init only; Unique.once() already consumed above.
        unsafe {
            *SLOT.0.get() = Some(pin);
        }
        INIT.store(true, Ordering::Release);
        0
    }

    pub fn set(on: bool) -> i32 {
        if !INIT.load(Ordering::Acquire) {
            return -(ENODEV as i32);
        }
        // SAFETY: INIT guarantees the Option is Some and exclusive with C callers.
        unsafe {
            if let Some(pin) = (*SLOT.0.get()).as_mut() {
                pin.set(on);
                0
            } else {
                -(ENODEV as i32)
            }
        }
    }

    pub fn is_ready() -> bool {
        INIT.load(Ordering::Acquire)
    }
}

#[cfg(target_os = "none")]
pub use motor::{init as motor_init, is_ready as motor_is_ready, set as motor_set};

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
