#![cfg_attr(target_os = "none", no_std)]

pub mod battery;
pub mod button;
pub mod feedback;
pub mod framing;
pub mod haptic;
pub mod imu_gesture;
pub mod led;

#[cfg(target_os = "none")]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    extern "C" {
        fn k_panic() -> !;
    }
    // SAFETY: k_panic() is Zephyr's own panic entry point. It is `FUNC_NORETURN`
    // on the C side and is always linked into the application image.
    unsafe { k_panic() }
}

#[no_mangle]
pub extern "C" fn omi_rust_selftest() -> i32 {
    framing::selftest()
        + imu_gesture::selftest()
        + button::selftest()
        + haptic::selftest()
        + led::selftest()
        + feedback::selftest()
}

/// # Safety
///
/// `out` must be null or point at `framing::RING_BUFFER_HEADER_SIZE` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn omi_rust_ring_header(len: u16, out: *mut u8) {
    if out.is_null() {
        return;
    }
    let header = framing::encode_ring_header(len);
    // SAFETY: the caller guarantees `out` points at RING_BUFFER_HEADER_SIZE
    // writable bytes; the null case is rejected above.
    unsafe {
        core::ptr::copy_nonoverlapping(header.as_ptr(), out, framing::RING_BUFFER_HEADER_SIZE);
    }
}

/// # Safety
///
/// `out` must be null or point at `framing::NET_BUFFER_HEADER_SIZE` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn omi_rust_packet_header(id: u16, index: u8, out: *mut u8) {
    if out.is_null() {
        return;
    }
    let header = framing::encode_packet_header(id, index);
    // SAFETY: the caller guarantees `out` points at NET_BUFFER_HEADER_SIZE
    // writable bytes; the null case is rejected above.
    unsafe {
        core::ptr::copy_nonoverlapping(header.as_ptr(), out, framing::NET_BUFFER_HEADER_SIZE);
    }
}

/// Battery voltage-to-percentage lookup with interpolation. `is_charging` is
/// non-zero when charging, matching the C `is_charging` global.
#[no_mangle]
pub extern "C" fn omi_rust_battery_raw_percentage(battery_millivolt: u16, is_charging: bool) -> u8 {
    battery::raw_percentage(battery_millivolt, is_charging)
}

/// One EMA smoothing step over the battery percentage.
#[no_mangle]
pub extern "C" fn omi_rust_battery_ema_step(
    current_ema: u32,
    new_value: u8,
    is_charging: bool,
) -> u8 {
    battery::ema_step(current_ema, new_value, is_charging)
}

/// IMU wake/tap source decode. Returns 2 for a double tap, 1 for motion, 0 for
/// neither — matching `omi_rust_gesture_t` in omi_rust.h.
#[no_mangle]
pub extern "C" fn omi_rust_imu_classify(wake_src: u8, tap_src: u8, double_tap_enabled: bool) -> u8 {
    match imu_gesture::classify(wake_src, tap_src, double_tap_enabled) {
        imu_gesture::Gesture::None => 0,
        imu_gesture::Gesture::Motion => 1,
        imu_gesture::Gesture::DoubleTap => 2,
    }
}

/// # Safety
///
/// `out` must be null or point at a writable `omi_rust_imu_registers_t`.
#[no_mangle]
pub unsafe extern "C" fn omi_rust_imu_program_registers(
    double_tap: bool,
    wake_threshold: u8,
    tap_duration: u8,
    tap_quiet: u8,
    tap_shock: u8,
    out: *mut OmiRustImuRegisters,
) {
    if out.is_null() {
        return;
    }
    let regs = imu_gesture::program_registers(
        double_tap,
        wake_threshold,
        tap_duration,
        tap_quiet,
        tap_shock,
    );
    // SAFETY: caller guarantees `out` is a writable omi_rust_imu_registers_t.
    unsafe {
        *out = OmiRustImuRegisters {
            ctrl1_xl_odr: regs.ctrl1_xl_odr,
            tap_cfg: regs.tap_cfg,
            wake_ths: regs.wake_ths,
            int_dur2: regs.int_dur2,
            md1_cfg: regs.md1_cfg,
        };
    }
}

#[repr(C)]
pub struct OmiRustImuRegisters {
    pub ctrl1_xl_odr: u8,
    pub tap_cfg: u8,
    pub wake_ths: u8,
    pub int_dur2: u8,
    pub md1_cfg: u8,
}

#[no_mangle]
pub extern "C" fn omi_rust_imu_merge_wake_up_dur(existing: u8, wake_duration: u8) -> u8 {
    imu_gesture::merge_wake_up_dur(existing, wake_duration)
}

static mut BUTTON_FSM: button::ButtonFsm = button::ButtonFsm::new();

/// Advance the button tap FSM by one 40 ms poll. Returns `omi_rust_button_event_t`.
#[no_mangle]
pub extern "C" fn omi_rust_button_step(pressed: bool) -> u8 {
    // SAFETY: the button work queue is the only caller; Zephyr runs that work
    // serially on one thread, so there is no concurrent access. `addr_of_mut!`
    // avoids forming a Rust reference to the mutable static.
    unsafe { (&raw mut BUTTON_FSM).as_mut().unwrap_unchecked().step(pressed) as u8 }
}

#[no_mangle]
pub extern "C" fn omi_rust_button_reset() {
    // SAFETY: same single-threaded work-queue caller as omi_rust_button_step.
    unsafe {
        (&raw mut BUTTON_FSM).as_mut().unwrap_unchecked().reset();
    }
}

/// Maps haptic GATT write byte to ms. Returns 0 for unrecognized values.
#[no_mangle]
pub extern "C" fn omi_rust_haptic_duration_from_ble(value: u8) -> u32 {
    haptic::duration_from_ble_value(value).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn omi_rust_haptic_clamp_duration(duration: u32) -> u32 {
    haptic::clamp_duration(duration)
}

#[no_mangle]
pub extern "C" fn omi_rust_led_pulse_width_ns(period_ns: u32, level: u8) -> u32 {
    led::pulse_width_ns(period_ns, level)
}

#[repr(C)]
pub struct OmiRustErrorPattern {
    pub red: bool,
    pub green: bool,
    pub blue: bool,
    pub blinks: u8,
}

/// # Safety
///
/// `out` must be null or point at a writable `omi_rust_error_pattern_t`.
/// `kind` must be a valid `omi_rust_error_kind_t` (0..=10); unknown values
/// leave `out` untouched and return false.
#[no_mangle]
pub unsafe extern "C" fn omi_rust_feedback_error_pattern(
    kind: u8,
    out: *mut OmiRustErrorPattern,
) -> bool {
    if out.is_null() {
        return false;
    }
    let Some(kind) = feedback_kind_from_u8(kind) else {
        return false;
    };
    let p = feedback::error_pattern(kind);
    // SAFETY: caller guarantees writable out.
    unsafe {
        *out = OmiRustErrorPattern {
            red: p.red,
            green: p.green,
            blue: p.blue,
            blinks: p.blinks,
        };
    }
    true
}

fn feedback_kind_from_u8(kind: u8) -> Option<feedback::ErrorKind> {
    match kind {
        0 => Some(feedback::ErrorKind::Settings),
        1 => Some(feedback::ErrorKind::LedDriver),
        2 => Some(feedback::ErrorKind::BatteryInit),
        3 => Some(feedback::ErrorKind::BatteryCharge),
        4 => Some(feedback::ErrorKind::Button),
        5 => Some(feedback::ErrorKind::Haptic),
        6 => Some(feedback::ErrorKind::SdCard),
        7 => Some(feedback::ErrorKind::Storage),
        8 => Some(feedback::ErrorKind::Transport),
        9 => Some(feedback::ErrorKind::Codec),
        10 => Some(feedback::ErrorKind::Microphone),
        _ => None,
    }
}
