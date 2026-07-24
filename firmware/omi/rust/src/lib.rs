#![cfg_attr(target_os = "none", no_std)]

pub mod battery;
pub mod framing;
pub mod imu_gesture;

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
