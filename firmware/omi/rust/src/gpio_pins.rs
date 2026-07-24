// Thin nordic,gpio-pins shells owned by the zephyr crate. Interrupt
// registration, ADC, SD PM, and FAKE2C bitbang stay in C.

#[cfg(target_os = "none")]
mod pins {
    use core::cell::UnsafeCell;
    use core::sync::atomic::{AtomicBool, Ordering};

    use zephyr::device::gpio::GpioPin;
    use zephyr::raw::{ZR_GPIO_INPUT, ZR_GPIO_OUTPUT, ZR_GPIO_OUTPUT_ACTIVE, ENODEV};

    /// Nordic `NRF_GPIO_DRIVE_S0H1` (standard 0, high 1) from nordic-nrf-gpio.h.
    const NRF_GPIO_DRIVE_S0H1: u32 = 0x0200;

    struct Slot(UnsafeCell<Option<GpioPin>>);
    // SAFETY: access is gated by INIT and only from cooperative contexts that
    // already serialized the matching C API.
    unsafe impl Sync for Slot {}

    fn take_pin(
        slot: &Slot,
        init: &AtomicBool,
        get: fn() -> Option<GpioPin>,
        flags: u32,
    ) -> i32 {
        if init.load(Ordering::Acquire) {
            return 0;
        }
        let Some(mut pin) = get() else {
            return -(ENODEV as i32);
        };
        pin.configure(flags);
        // SAFETY: first init only; Unique.once() already consumed above.
        unsafe {
            *slot.0.get() = Some(pin);
        }
        init.store(true, Ordering::Release);
        0
    }

    fn with_pin(slot: &Slot, init: &AtomicBool, f: impl FnOnce(&mut GpioPin)) -> i32 {
        if !init.load(Ordering::Acquire) {
            return -(ENODEV as i32);
        }
        // SAFETY: INIT guarantees the Option is Some.
        unsafe {
            if let Some(pin) = (*slot.0.get()).as_mut() {
                f(pin);
                0
            } else {
                -(ENODEV as i32)
            }
        }
    }

    static BAT_READ: Slot = Slot(UnsafeCell::new(None));
    static BAT_READ_INIT: AtomicBool = AtomicBool::new(false);
    static SD_EN: Slot = Slot(UnsafeCell::new(None));
    static SD_EN_INIT: AtomicBool = AtomicBool::new(false);
    static RFSW: Slot = Slot(UnsafeCell::new(None));
    static RFSW_INIT: AtomicBool = AtomicBool::new(false);
    static PDM_EN: Slot = Slot(UnsafeCell::new(None));
    static PDM_EN_INIT: AtomicBool = AtomicBool::new(false);

    pub fn bat_read_enable_path() -> i32 {
        let err = take_pin(
            &BAT_READ,
            &BAT_READ_INIT,
            zephyr::devicetree::labels::bat_read_pin::get_instance,
            ZR_GPIO_OUTPUT | NRF_GPIO_DRIVE_S0H1,
        );
        if err != 0 {
            return err;
        }
        with_pin(&BAT_READ, &BAT_READ_INIT, |pin| {
            pin.configure(ZR_GPIO_OUTPUT | NRF_GPIO_DRIVE_S0H1);
            pin.set(false);
        })
    }

    pub fn bat_read_restore_input() -> i32 {
        let err = take_pin(
            &BAT_READ,
            &BAT_READ_INIT,
            zephyr::devicetree::labels::bat_read_pin::get_instance,
            ZR_GPIO_INPUT,
        );
        if err != 0 {
            return err;
        }
        with_pin(&BAT_READ, &BAT_READ_INIT, |pin| pin.configure(ZR_GPIO_INPUT))
    }

    pub fn sd_en_set(on: bool) -> i32 {
        let err = take_pin(
            &SD_EN,
            &SD_EN_INIT,
            zephyr::devicetree::labels::sdcard_en_pin::get_instance,
            ZR_GPIO_OUTPUT,
        );
        if err != 0 {
            return err;
        }
        with_pin(&SD_EN, &SD_EN_INIT, |pin| {
            pin.configure(ZR_GPIO_OUTPUT);
            pin.set(on);
        })
    }

    pub fn rfsw_on() -> i32 {
        let err = take_pin(
            &RFSW,
            &RFSW_INIT,
            zephyr::devicetree::labels::rfsw_en_pin::get_instance,
            ZR_GPIO_OUTPUT | NRF_GPIO_DRIVE_S0H1,
        );
        if err != 0 {
            return err;
        }
        with_pin(&RFSW, &RFSW_INIT, |pin| {
            pin.configure(ZR_GPIO_OUTPUT | NRF_GPIO_DRIVE_S0H1);
            pin.set(true);
        })
    }

    pub fn rfsw_off() -> i32 {
        if !RFSW_INIT.load(Ordering::Acquire) {
            return 0;
        }
        with_pin(&RFSW, &RFSW_INIT, |pin| pin.set(false))
    }

    pub fn pdm_en_init() -> i32 {
        take_pin(
            &PDM_EN,
            &PDM_EN_INIT,
            zephyr::devicetree::labels::pdm_en_pin::get_instance,
            ZR_GPIO_OUTPUT_ACTIVE,
        )
    }

    pub fn pdm_en_set(on: bool) -> i32 {
        if !PDM_EN_INIT.load(Ordering::Acquire) {
            let err = pdm_en_init();
            if err != 0 {
                return err;
            }
        }
        with_pin(&PDM_EN, &PDM_EN_INIT, |pin| pin.set(on))
    }
}

#[cfg(target_os = "none")]
pub use pins::{
    bat_read_enable_path, bat_read_restore_input, pdm_en_init, pdm_en_set, rfsw_off, rfsw_on,
    sd_en_set,
};
