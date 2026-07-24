#![cfg_attr(target_os = "none", no_std)]

pub mod audio_dsp;
pub mod battery;
pub mod button;
pub mod features;
pub mod feedback;
pub mod framing;
pub mod haptic;
pub mod imu_gesture;
pub mod led;
pub mod offline_packer;
pub mod settings_math;
pub mod storage_proto;
pub mod time;
pub mod user_event;

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
        + audio_dsp::selftest()
        + imu_gesture::selftest()
        + button::selftest()
        + haptic::selftest()
        + led::selftest()
        + feedback::selftest()
        + settings_math::selftest()
        + storage_proto::selftest()
        + time::selftest()
        + user_event::selftest()
        + features::selftest()
        + offline_packer::selftest()
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
/// `bytes` must be null or point at at least `RING_BUFFER_HEADER_SIZE` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn omi_rust_ring_header_decode(bytes: *const u8) -> u16 {
    if bytes.is_null() {
        return 0;
    }
    // SAFETY: caller guarantees RING_BUFFER_HEADER_SIZE readable bytes.
    unsafe {
        let slice = core::slice::from_raw_parts(bytes, framing::RING_BUFFER_HEADER_SIZE);
        framing::decode_ring_header(slice).unwrap_or(0)
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

#[no_mangle]
pub extern "C" fn omi_rust_audio_chunk_size(mtu: u16, remaining: u32) -> u32 {
    framing::audio_chunk_size(mtu, remaining)
}

/// # Safety
///
/// `interleaved` must be null or point at `2 * frames` readable i16 samples.
/// `mono_out` must be null or point at `frames` writable i16 samples.
#[no_mangle]
pub unsafe extern "C" fn omi_rust_audio_stereo_to_mono(
    interleaved: *const i16,
    frames: usize,
    mono_out: *mut i16,
) {
    if interleaved.is_null() || mono_out.is_null() || frames == 0 {
        return;
    }
    // SAFETY: caller guarantees slice lengths.
    unsafe {
        let inter = core::slice::from_raw_parts(interleaved, frames * 2);
        let out = core::slice::from_raw_parts_mut(mono_out, frames);
        audio_dsp::interleaved_stereo_to_mono(inter, out);
    }
}

/// # Safety
///
/// `buf` must be null or point at `n` readable i16 samples.
#[no_mangle]
pub unsafe extern "C" fn omi_rust_audio_avg_abs_amplitude(buf: *const i16, n: usize) -> u32 {
    if buf.is_null() || n == 0 {
        return 0;
    }
    // SAFETY: caller guarantees `n` readable samples at `buf`.
    unsafe {
        let slice = core::slice::from_raw_parts(buf, n);
        audio_dsp::avg_abs_amplitude(slice)
    }
}

#[no_mangle]
pub extern "C" fn omi_rust_settings_clamp_dim_ratio(value: u8) -> u8 {
    settings_math::clamp_dim_ratio(value)
}

#[no_mangle]
pub extern "C" fn omi_rust_settings_clamp_mic_gain(value: u8) -> u8 {
    settings_math::clamp_mic_gain(value)
}

#[repr(C)]
pub struct OmiRustLsm6dslTimeBase {
    pub epoch_s: u64,
    pub ts: u32,
    pub reserved: u32,
}

/// Returns 0 on success, -22 (`EINVAL`) when `len` is not 12 or 16.
///
/// # Safety
///
/// `buf` must be null or point at `len` readable bytes. `out` must be null or
/// point at a writable `omi_rust_lsm6dsl_time_base_t`.
#[no_mangle]
pub unsafe extern "C" fn omi_rust_settings_parse_lsm6dsl_time_base(
    buf: *const u8,
    len: usize,
    out: *mut OmiRustLsm6dslTimeBase,
) -> i32 {
    if buf.is_null() || out.is_null() {
        return -22;
    }
    // SAFETY: caller guarantees `len` readable bytes at `buf`.
    let slice = unsafe { core::slice::from_raw_parts(buf, len) };
    match settings_math::parse_lsm6dsl_time_base(slice) {
        Ok(parsed) => {
            // SAFETY: caller guarantees writable `out`.
            unsafe {
                *out = OmiRustLsm6dslTimeBase {
                    epoch_s: parsed.epoch_s,
                    ts: parsed.ts,
                    reserved: parsed.reserved,
                };
            }
            0
        }
        Err(err) => err,
    }
}

#[no_mangle]
pub extern "C" fn omi_rust_rtc_extrapolate_ms(
    base_epoch_ms: u64,
    base_uptime_ms: i64,
    now_uptime_ms: i64,
) -> u64 {
    time::extrapolate_utc_ms(base_epoch_ms, base_uptime_ms, now_uptime_ms)
}

#[no_mangle]
pub extern "C" fn omi_rust_rtc_seconds_clamped(now_ms: u64) -> u32 {
    time::utc_seconds_clamped(now_ms)
}

#[no_mangle]
pub extern "C" fn omi_rust_imu_boot_epoch_ms(base_epoch_s: u64, base_ts: u32, ts_now: u32) -> u64 {
    time::imu_boot_epoch_ms(base_epoch_s, base_ts, ts_now)
}

/// # Safety
///
/// `out` must be null or point at `user_event::PAYLOAD_LEN` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn omi_rust_user_event_encode(
    code: u8,
    source: u8,
    seq: u16,
    epoch_s: u32,
    out: *mut u8,
) {
    if out.is_null() {
        return;
    }
    let encoded = user_event::encode(&user_event::Record {
        code,
        source,
        seq,
        epoch_s,
    });
    // SAFETY: caller guarantees PAYLOAD_LEN writable bytes.
    unsafe {
        core::ptr::copy_nonoverlapping(encoded.as_ptr(), out, user_event::PAYLOAD_LEN);
    }
}

/// Fixed capacity; must match `CONFIG_OMI_USER_EVENT_QUEUE_LEN` (16 in omi.conf).
static mut USER_EVENT_QUEUE: user_event::Queue<{ user_event::DEFAULT_QUEUE_LEN }> =
    user_event::Queue::new();

/// Allocate the next monotonic sequence number for a user event.
#[no_mangle]
pub extern "C" fn omi_rust_user_event_alloc_seq() -> u16 {
    // SAFETY: C transport layer holds `user_event_lock` before calling.
    unsafe {
        (&raw mut USER_EVENT_QUEUE)
            .as_mut()
            .unwrap_unchecked()
            .alloc_seq()
    }
}

/// Push one event into the drop-oldest queue.
#[no_mangle]
pub extern "C" fn omi_rust_user_event_queue_push(code: u8, source: u8, seq: u16, epoch_s: u32) {
    // SAFETY: C transport layer holds `user_event_lock` before calling.
    unsafe {
        (&raw mut USER_EVENT_QUEUE)
            .as_mut()
            .unwrap_unchecked()
            .push(user_event::Record {
                code,
                source,
                seq,
                epoch_s,
            });
    }
}

/// Peek the head of the queue without removing it.
///
/// # Safety
///
/// All `out_*` pointers must be non-null when called.
#[no_mangle]
pub unsafe extern "C" fn omi_rust_user_event_queue_peek(
    out_code: *mut u8,
    out_source: *mut u8,
    out_seq: *mut u16,
    out_epoch: *mut u32,
) -> bool {
    if out_code.is_null() || out_source.is_null() || out_seq.is_null() || out_epoch.is_null() {
        return false;
    }
    // SAFETY: C transport layer holds `user_event_lock` before calling.
    let q = unsafe { (&raw mut USER_EVENT_QUEUE).as_mut().unwrap_unchecked() };
    if let Some(rec) = q.peek() {
        // SAFETY: caller guarantees writable out pointers.
        unsafe {
            *out_code = rec.code;
            *out_source = rec.source;
            *out_seq = rec.seq;
            *out_epoch = rec.epoch_s;
        }
        true
    } else {
        false
    }
}

/// Pop the head of the queue.
#[no_mangle]
pub extern "C" fn omi_rust_user_event_queue_pop() -> bool {
    // SAFETY: C transport layer holds `user_event_lock` before calling.
    unsafe {
        (&raw mut USER_EVENT_QUEUE)
            .as_mut()
            .unwrap_unchecked()
            .pop()
            .is_some()
    }
}

/// Current queue length (0..=16).
#[no_mangle]
pub extern "C" fn omi_rust_user_event_queue_len() -> u8 {
    // SAFETY: C transport layer holds `user_event_lock` before calling.
    unsafe {
        (&raw mut USER_EVENT_QUEUE)
            .as_ref()
            .unwrap_unchecked()
            .len() as u8
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
    unsafe {
        (&raw mut BUTTON_FSM)
            .as_mut()
            .unwrap_unchecked()
            .step(pressed) as u8
    }
}

#[no_mangle]
pub extern "C" fn omi_rust_button_reset() {
    // SAFETY: same single-threaded work-queue caller as omi_rust_button_step.
    unsafe {
        (&raw mut BUTTON_FSM).as_mut().unwrap_unchecked().reset();
    }
}

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

#[repr(C)]
pub struct OmiRustStorageParsed {
    pub command: u8,
    pub start_seq: u64,
    pub packet_count: u32,
    pub advance_seq: u64,
}

#[repr(C)]
pub struct OmiRustRingInfoFields {
    pub read_seq: u64,
    pub write_seq: u64,
    pub capacity_packets: u32,
    pub dropped_packets: u64,
    pub packet_bytes: u16,
}

/// Returns C-compatible status: `STORAGE_DEFERRED` (0xFF) for deferred commands,
/// `INVALID_COMMAND` (6) for invalid input, or `0` for stop-sync.
///
/// # Safety
///
/// `buf` must be null or point at `len` readable bytes. `out` must be null or
/// point at a writable `omi_rust_storage_parsed_t`.
#[no_mangle]
pub unsafe extern "C" fn omi_rust_storage_parse_command(
    buf: *const u8,
    len: u16,
    out: *mut OmiRustStorageParsed,
) -> u8 {
    if buf.is_null() || out.is_null() || len == 0 {
        return storage_proto::INVALID_COMMAND;
    }
    // SAFETY: caller guarantees `len` readable bytes at `buf`.
    let slice = unsafe { core::slice::from_raw_parts(buf, len as usize) };
    let (status, parsed) = storage_proto::parse_command(slice);
    // SAFETY: caller guarantees writable `out`.
    unsafe {
        *out = OmiRustStorageParsed {
            command: storage_command_to_u8(parsed.command),
            start_seq: parsed.start_seq,
            packet_count: parsed.packet_count,
            advance_seq: parsed.advance_seq,
        };
    }
    status
}

/// Map a negative Zephyr errno to a storage BLE status byte.
#[no_mangle]
pub extern "C" fn omi_rust_storage_status_from_error(err: i32, fallback_status: u8) -> u8 {
    storage_proto::status_from_error(err, fallback_status)
}

/// ATT MTU-based bulk DATA chunk payload size, matching `get_ble_data_chunk_size()`.
#[no_mangle]
pub extern "C" fn omi_rust_storage_ble_chunk_size(mtu: u16) -> u16 {
    storage_proto::ble_data_chunk_size(mtu)
}

/// # Safety
///
/// `out` must be null or point at at least `storage_proto::ACK_PAYLOAD_LEN` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn omi_rust_storage_encode_ack(status: u8, out: *mut u8) -> u16 {
    if out.is_null() {
        return 0;
    }
    let mut buf = [0u8; storage_proto::ACK_PAYLOAD_LEN];
    let len = storage_proto::encode_ack(status, &mut buf);
    // SAFETY: caller guarantees writable output buffer.
    unsafe {
        core::ptr::copy_nonoverlapping(buf.as_ptr(), out, len);
    }
    len as u16
}

/// # Safety
///
/// `out` must be null or point at at least `storage_proto::DONE_PAYLOAD_LEN` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn omi_rust_storage_encode_done(
    status: u8,
    next_seq: u64,
    out: *mut u8,
) -> u16 {
    if out.is_null() {
        return 0;
    }
    let mut buf = [0u8; storage_proto::DONE_PAYLOAD_LEN];
    let len = storage_proto::encode_done(status, next_seq, &mut buf);
    // SAFETY: caller guarantees writable output buffer.
    unsafe {
        core::ptr::copy_nonoverlapping(buf.as_ptr(), out, len);
    }
    len as u16
}

/// # Safety
///
/// `info` must be null or point at a readable `omi_rust_ring_info_fields_t`.
/// `out` must be null or point at at least `storage_proto::RING_INFO_PAYLOAD_LEN` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn omi_rust_storage_encode_ring_info(
    info: *const OmiRustRingInfoFields,
    out: *mut u8,
) -> u16 {
    if info.is_null() || out.is_null() {
        return 0;
    }
    // SAFETY: caller guarantees readable `info`.
    let fields = unsafe { &*info };
    let ring_info = storage_proto::RingInfoFields {
        read_seq: fields.read_seq,
        write_seq: fields.write_seq,
        capacity_packets: fields.capacity_packets,
        dropped_packets: fields.dropped_packets,
        packet_bytes: fields.packet_bytes,
    };
    let mut buf = [0u8; storage_proto::RING_INFO_PAYLOAD_LEN];
    let len = storage_proto::encode_ring_info(&ring_info, &mut buf);
    // SAFETY: caller guarantees writable output buffer.
    unsafe {
        core::ptr::copy_nonoverlapping(buf.as_ptr(), out, len);
    }
    len as u16
}

/// # Safety
///
/// `out` must be null or point at at least `storage_proto::READ_BEGIN_PAYLOAD_LEN` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn omi_rust_storage_encode_read_begin(
    start_seq: u64,
    packet_count: u32,
    out: *mut u8,
) -> u16 {
    if out.is_null() {
        return 0;
    }
    let mut buf = [0u8; storage_proto::READ_BEGIN_PAYLOAD_LEN];
    let len = storage_proto::encode_read_begin(start_seq, packet_count, &mut buf);
    // SAFETY: caller guarantees writable output buffer.
    unsafe {
        core::ptr::copy_nonoverlapping(buf.as_ptr(), out, len);
    }
    len as u16
}

/// # Safety
///
/// `payload` must be null or point at `payload_len` readable bytes when `payload_len > 0`.
/// `out` must be null or point at at least `1 + payload_len` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn omi_rust_storage_encode_data(
    payload: *const u8,
    payload_len: u16,
    out: *mut u8,
) -> u16 {
    if out.is_null() {
        return 0;
    }
    if payload_len > 0 && payload.is_null() {
        return 0;
    }
    let payload_slice = if payload_len > 0 {
        // SAFETY: caller guarantees `payload_len` readable bytes at `payload`.
        unsafe { core::slice::from_raw_parts(payload, payload_len as usize) }
    } else {
        &[]
    };
    // SAFETY: caller guarantees `1 + payload_len` writable bytes at `out`.
    let out_slice = unsafe { core::slice::from_raw_parts_mut(out, 1 + payload_len as usize) };
    storage_proto::encode_data(payload_slice, out_slice) as u16
}

fn storage_command_to_u8(command: storage_proto::StorageCommand) -> u8 {
    match command {
        storage_proto::StorageCommand::Invalid => 0,
        storage_proto::StorageCommand::RingInfo => 1,
        storage_proto::StorageCommand::RingRead => 2,
        storage_proto::StorageCommand::RingAdvance => 3,
        storage_proto::StorageCommand::RingClear => 4,
        storage_proto::StorageCommand::StopSync => 5,
    }
}

#[repr(C)]
pub struct OmiRustFeatureFlags {
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
}

/// Assemble the BLE features bitmask from compile-time `IS_ENABLED` flags.
///
/// # Safety
///
/// `flags` must be null or point at a readable `omi_rust_feature_flags_t`.
#[no_mangle]
pub unsafe extern "C" fn omi_rust_features_assemble(flags: *const OmiRustFeatureFlags) -> u32 {
    if flags.is_null() {
        return features::assemble(&features::FeatureFlags::default());
    }
    // SAFETY: caller guarantees readable `flags`.
    let f = unsafe { &*flags };
    features::assemble(&features::FeatureFlags {
        speaker: f.speaker,
        accelerometer: f.accelerometer,
        button: f.button,
        battery: f.battery,
        usb: f.usb,
        haptic: f.haptic,
        offline_storage: f.offline_storage,
        user_events: f.user_events,
        imu_gestures: f.imu_gestures,
        hw_vad: f.hw_vad,
        ble_sleep_cmd: f.ble_sleep_cmd,
        capture_state: f.capture_state,
        device_name_rw: f.device_name_rw,
    })
}

#[repr(C)]
pub struct OmiRustOfflinePackerStep {
    pub action: u8,
    pub prefix_offset: u16,
    pub data_offset: u16,
    pub trailing_prefix_offset: u16,
    pub flush_size: u16,
    pub new_buffer_offset: u16,
}

static mut OFFLINE_PACKER: offline_packer::OfflinePacker = offline_packer::OfflinePacker::new();

/// Advance the offline SD batching FSM for one Opus frame.
///
/// # Safety
///
/// `out` must be null or point at a writable `omi_rust_offline_packer_step_t`.
#[no_mangle]
pub unsafe extern "C" fn omi_rust_offline_packer_step(
    tx_buffer_size: u8,
    out: *mut OmiRustOfflinePackerStep,
) {
    if out.is_null() {
        return;
    }
    // SAFETY: pusher thread is the only caller; no concurrent access.
    let step = unsafe {
        (&raw mut OFFLINE_PACKER)
            .as_mut()
            .unwrap_unchecked()
            .step(tx_buffer_size)
    };
    // SAFETY: caller guarantees writable `out`.
    unsafe {
        *out = OmiRustOfflinePackerStep {
            action: step.action as u8,
            prefix_offset: step.prefix_offset,
            data_offset: step.data_offset,
            trailing_prefix_offset: step.trailing_prefix_offset,
            flush_size: step.flush_size,
            new_buffer_offset: step.new_buffer_offset,
        };
    }
}

#[no_mangle]
pub extern "C" fn omi_rust_offline_packer_reset() {
    // SAFETY: same single-threaded pusher caller as omi_rust_offline_packer_step.
    unsafe {
        (&raw mut OFFLINE_PACKER)
            .as_mut()
            .unwrap_unchecked()
            .reset();
    }
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
