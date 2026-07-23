#![cfg_attr(target_os = "none", no_std)]

pub mod framing;

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
