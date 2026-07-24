// Pure bit-manipulation ported from firmware/omi/src/imu_gesture.c: the LSM6DS3TR-C
// register-field packing done in `imu_program_registers`, and the wake/tap source
// decode done in `imu_gesture_work_handler`. The I2C transfers, the GPIO INT1
// wiring and the Zephyr work queue stay in C. The register addresses and bit
// masks are reproduced from the same ST datasheet values the C uses.

pub const LSM6DS_CTRL1_XL_ODR_26HZ: u8 = 0x20;
pub const LSM6DS_CTRL1_XL_ODR_416HZ: u8 = 0x60;

pub const LSM6DS_TAP_CFG_INTERRUPTS_ENABLE: u8 = 1 << 7;
pub const LSM6DS_TAP_CFG_TAP_X_EN: u8 = 1 << 3;
pub const LSM6DS_TAP_CFG_TAP_Y_EN: u8 = 1 << 2;
pub const LSM6DS_TAP_CFG_TAP_Z_EN: u8 = 1 << 1;
pub const LSM6DS_TAP_CFG_LIR: u8 = 1 << 0;

pub const LSM6DS_WAKE_UP_THS_SINGLE_DOUBLE_TAP: u8 = 1 << 7;
pub const LSM6DS_WAKE_UP_THS_WK_THS_MASK: u8 = 0x3F;

pub const LSM6DS_WAKE_UP_DUR_WAKE_DUR_SHIFT: u8 = 5;
pub const LSM6DS_WAKE_UP_DUR_WAKE_DUR_MASK: u8 = 0x60;

pub const LSM6DS_MD1_CFG_INT1_WU: u8 = 1 << 5;
pub const LSM6DS_MD1_CFG_INT1_DOUBLE_TAP: u8 = 1 << 3;

pub const LSM6DS_WAKE_UP_SRC_WU: u8 = 1 << 3;
pub const LSM6DS_TAP_SRC_DOUBLE_TAP: u8 = 1 << 4;

/// The register values `imu_program_registers` writes, computed from the same
/// Kconfig inputs. Keeping the field packing in one place makes it testable
/// without an I2C bus, and keeps the two INT_DUR2 / WAKE_UP_DUR shift-and-mask
/// expressions from drifting.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct ImuRegisters {
    pub ctrl1_xl_odr: u8,
    pub tap_cfg: u8,
    pub wake_ths: u8,
    pub int_dur2: u8,
    pub md1_cfg: u8,
}

/// Mirrors the register computation in `imu_program_registers`. `double_tap` is
/// `IS_ENABLED(CONFIG_OMI_ENABLE_IMU_DOUBLE_TAP)`; the rest are the matching
/// `CONFIG_OMI_IMU_*` integers.
pub fn program_registers(
    double_tap: bool,
    wake_threshold: u8,
    tap_duration: u8,
    tap_quiet: u8,
    tap_shock: u8,
) -> ImuRegisters {
    let mut tap_cfg = LSM6DS_TAP_CFG_INTERRUPTS_ENABLE | LSM6DS_TAP_CFG_LIR;
    let mut wake_ths = wake_threshold & LSM6DS_WAKE_UP_THS_WK_THS_MASK;
    let mut md1_cfg = LSM6DS_MD1_CFG_INT1_WU;
    let mut odr = LSM6DS_CTRL1_XL_ODR_26HZ;
    let mut int_dur2 = 0u8;

    if double_tap {
        tap_cfg |= LSM6DS_TAP_CFG_TAP_X_EN | LSM6DS_TAP_CFG_TAP_Y_EN | LSM6DS_TAP_CFG_TAP_Z_EN;
        wake_ths |= LSM6DS_WAKE_UP_THS_SINGLE_DOUBLE_TAP;
        md1_cfg |= LSM6DS_MD1_CFG_INT1_DOUBLE_TAP;
        odr = LSM6DS_CTRL1_XL_ODR_416HZ;

        int_dur2 = ((tap_duration & 0x0F) << 4) | ((tap_quiet & 0x03) << 2) | (tap_shock & 0x03);
    }

    ImuRegisters {
        ctrl1_xl_odr: odr,
        tap_cfg,
        wake_ths,
        int_dur2,
        md1_cfg,
    }
}

/// Merges the wake-duration field into a read-back WAKE_UP_DUR value, exactly as
/// the C does: clear the two duration bits, OR the shifted-and-masked new value.
pub fn merge_wake_up_dur(existing: u8, wake_duration: u8) -> u8 {
    let cleared = existing & !LSM6DS_WAKE_UP_DUR_WAKE_DUR_MASK;
    cleared
        | ((wake_duration << LSM6DS_WAKE_UP_DUR_WAKE_DUR_SHIFT) & LSM6DS_WAKE_UP_DUR_WAKE_DUR_MASK)
}

/// What `imu_gesture_work_handler` decided from the two source registers. Double
/// tap wins over motion, and is only considered when double-tap is enabled, both
/// matching the C ordering.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum Gesture {
    None,
    DoubleTap,
    Motion,
}

/// Ports the classification in `imu_gesture_work_handler`. `double_tap_enabled`
/// is `IS_ENABLED(CONFIG_OMI_ENABLE_IMU_DOUBLE_TAP)`.
pub fn classify(wake_src: u8, tap_src: u8, double_tap_enabled: bool) -> Gesture {
    if double_tap_enabled && (tap_src & LSM6DS_TAP_SRC_DOUBLE_TAP) != 0 {
        return Gesture::DoubleTap;
    }
    if (wake_src & LSM6DS_WAKE_UP_SRC_WU) != 0 {
        return Gesture::Motion;
    }
    Gesture::None
}

pub fn selftest() -> i32 {
    let mut failures = 0;
    let r = program_registers(false, 32, 7, 3, 3);
    if r.md1_cfg != LSM6DS_MD1_CFG_INT1_WU || r.int_dur2 != 0 {
        failures += 1;
    }
    let r = program_registers(true, 32, 7, 3, 3);
    if r.int_dur2 != 0x7F
        || r.md1_cfg != (LSM6DS_MD1_CFG_INT1_WU | LSM6DS_MD1_CFG_INT1_DOUBLE_TAP)
    {
        failures += 1;
    }
    if merge_wake_up_dur(0x1F, 3) != (0x1F | 0x60) {
        failures += 1;
    }
    if classify(LSM6DS_WAKE_UP_SRC_WU, 0, true) != Gesture::Motion {
        failures += 1;
    }
    failures
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn registers_without_double_tap() {
        // Kconfig defaults: wake threshold 32, double tap off.
        let r = program_registers(false, 32, 7, 3, 3);
        assert_eq!(r.ctrl1_xl_odr, LSM6DS_CTRL1_XL_ODR_26HZ);
        assert_eq!(
            r.tap_cfg,
            LSM6DS_TAP_CFG_INTERRUPTS_ENABLE | LSM6DS_TAP_CFG_LIR
        );
        assert_eq!(r.wake_ths, 32);
        assert_eq!(r.int_dur2, 0);
        assert_eq!(r.md1_cfg, LSM6DS_MD1_CFG_INT1_WU);
    }

    #[test]
    fn registers_with_double_tap_defaults() {
        // Kconfig defaults: wake 32, tap duration 7, quiet 3, shock 3.
        let r = program_registers(true, 32, 7, 3, 3);
        assert_eq!(r.ctrl1_xl_odr, LSM6DS_CTRL1_XL_ODR_416HZ);
        assert_eq!(
            r.tap_cfg,
            LSM6DS_TAP_CFG_INTERRUPTS_ENABLE
                | LSM6DS_TAP_CFG_LIR
                | LSM6DS_TAP_CFG_TAP_X_EN
                | LSM6DS_TAP_CFG_TAP_Y_EN
                | LSM6DS_TAP_CFG_TAP_Z_EN
        );
        assert_eq!(r.wake_ths, 32 | LSM6DS_WAKE_UP_THS_SINGLE_DOUBLE_TAP);
        // (7<<4) | (3<<2) | 3 = 0x70 | 0x0C | 0x03 = 0x7F.
        assert_eq!(r.int_dur2, 0x7F);
        assert_eq!(
            r.md1_cfg,
            LSM6DS_MD1_CFG_INT1_WU | LSM6DS_MD1_CFG_INT1_DOUBLE_TAP
        );
    }

    #[test]
    fn wake_threshold_is_masked_to_six_bits() {
        let r = program_registers(false, 0xFF, 0, 0, 0);
        assert_eq!(r.wake_ths, 0x3F);
    }

    #[test]
    fn wake_up_dur_merge_preserves_other_bits() {
        // Existing 0x1F, duration 3 -> clear 0x60, OR (3<<5)&0x60 = 0x60.
        assert_eq!(merge_wake_up_dur(0x1F, 3), 0x1F | 0x60);
        // Duration 0 clears the field and leaves the rest.
        assert_eq!(merge_wake_up_dur(0x7F, 0), 0x1F);
    }

    #[test]
    fn double_tap_beats_motion_and_needs_enable() {
        let both = LSM6DS_TAP_SRC_DOUBLE_TAP;
        assert_eq!(
            classify(LSM6DS_WAKE_UP_SRC_WU, both, true),
            Gesture::DoubleTap
        );
        // Disabled: the tap bit is ignored, the wake bit still fires motion.
        assert_eq!(
            classify(LSM6DS_WAKE_UP_SRC_WU, both, false),
            Gesture::Motion
        );
        assert_eq!(classify(LSM6DS_WAKE_UP_SRC_WU, 0, true), Gesture::Motion);
        assert_eq!(classify(0, 0, true), Gesture::None);
    }
}
