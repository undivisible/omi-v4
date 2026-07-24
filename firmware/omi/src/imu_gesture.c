#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/i2c.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/util.h>

#include "imu.h"
#include "lib/core/user_event.h"

#include "omi_rust.h"

LOG_MODULE_REGISTER(imu_gesture, CONFIG_LOG_DEFAULT_LEVEL);

/* LSM6DS3TR-C embedded-function registers used for wake-up (activity) and tap
 * detection. Addresses per the ST datasheet; the accelerometer control and
 * timestamp registers touched by src/imu.c are deliberately left alone except
 * for CTRL1_XL, which both features need.
 */
#define LSM6DS_REG_CTRL1_XL 0x10
#define LSM6DS_REG_WAKE_UP_SRC 0x1B
#define LSM6DS_REG_TAP_SRC 0x1C
#define LSM6DS_REG_TAP_CFG 0x58
#define LSM6DS_REG_TAP_THS_6D 0x59
#define LSM6DS_REG_INT_DUR2 0x5A
#define LSM6DS_REG_WAKE_UP_THS 0x5B
#define LSM6DS_REG_WAKE_UP_DUR 0x5C
#define LSM6DS_REG_MD1_CFG 0x5E

#define LSM6DS_CTRL1_XL_ODR_26HZ 0x20
#define LSM6DS_CTRL1_XL_ODR_416HZ 0x60

#define LSM6DS_TAP_CFG_INTERRUPTS_ENABLE BIT(7)
#define LSM6DS_TAP_CFG_TAP_X_EN BIT(3)
#define LSM6DS_TAP_CFG_TAP_Y_EN BIT(2)
#define LSM6DS_TAP_CFG_TAP_Z_EN BIT(1)
#define LSM6DS_TAP_CFG_LIR BIT(0)

#define LSM6DS_WAKE_UP_THS_SINGLE_DOUBLE_TAP BIT(7)
#define LSM6DS_WAKE_UP_THS_WK_THS_MASK 0x3F

#define LSM6DS_WAKE_UP_DUR_WAKE_DUR_SHIFT 5
#define LSM6DS_WAKE_UP_DUR_WAKE_DUR_MASK 0x60

#define LSM6DS_MD1_CFG_INT1_WU BIT(5)
#define LSM6DS_MD1_CFG_INT1_DOUBLE_TAP BIT(3)

#define LSM6DS_WAKE_UP_SRC_WU BIT(3)
#define LSM6DS_TAP_SRC_DOUBLE_TAP BIT(4)

static const struct i2c_dt_spec imu_i2c = I2C_DT_SPEC_GET(DT_ALIAS(lsm6dsl));
static const struct gpio_dt_spec imu_int1 = GPIO_DT_SPEC_GET(DT_ALIAS(lsm6dsl), irq_gpios);

static struct gpio_callback imu_int1_cb;
static bool imu_gesture_ready;

static void imu_gesture_work_handler(struct k_work *work);
static K_WORK_DEFINE(imu_gesture_work, imu_gesture_work_handler);

static int imu_clear_sources(void)
{
    uint8_t scratch;
    int err = i2c_reg_read_byte_dt(&imu_i2c, LSM6DS_REG_WAKE_UP_SRC, &scratch);
    if (err) {
        return err;
    }
    return i2c_reg_read_byte_dt(&imu_i2c, LSM6DS_REG_TAP_SRC, &scratch);
}

static void imu_gesture_work_handler(struct k_work *work)
{
    ARG_UNUSED(work);

    uint8_t wake_src = 0;
    uint8_t tap_src = 0;

    if (i2c_reg_read_byte_dt(&imu_i2c, LSM6DS_REG_WAKE_UP_SRC, &wake_src)) {
        LOG_WRN("Failed to read WAKE_UP_SRC");
    }
    if (i2c_reg_read_byte_dt(&imu_i2c, LSM6DS_REG_TAP_SRC, &tap_src)) {
        LOG_WRN("Failed to read TAP_SRC");
    }

    uint8_t gesture =
        omi_rust_imu_classify(wake_src, tap_src, IS_ENABLED(CONFIG_OMI_ENABLE_IMU_DOUBLE_TAP));
    if (gesture == OMI_RUST_GESTURE_DOUBLE_TAP) {
        LOG_INF("IMU double tap (TAP_SRC 0x%02x)", tap_src);
        omi_note_user_activity();
        omi_user_event_emit(OMI_USER_EVENT_IMU_DOUBLE_TAP, OMI_USER_EVENT_SRC_IMU);
        return;
    }
    if (gesture == OMI_RUST_GESTURE_MOTION) {
        LOG_DBG("IMU motion (WAKE_UP_SRC 0x%02x)", wake_src);
        omi_note_user_activity();
        omi_user_event_emit(OMI_USER_EVENT_IMU_MOTION, OMI_USER_EVENT_SRC_IMU);
    }
}

static void imu_int1_isr(const struct device *dev, struct gpio_callback *cb, uint32_t pins)
{
    ARG_UNUSED(dev);
    ARG_UNUSED(cb);
    ARG_UNUSED(pins);
    k_work_submit(&imu_gesture_work);
}

static int imu_program_registers(void)
{
    int err;
    omi_rust_imu_registers_t regs;
    omi_rust_imu_program_registers(IS_ENABLED(CONFIG_OMI_ENABLE_IMU_DOUBLE_TAP),
                                   (uint8_t) CONFIG_OMI_IMU_WAKE_THRESHOLD,
                                   (uint8_t) CONFIG_OMI_IMU_TAP_DURATION,
                                   (uint8_t) CONFIG_OMI_IMU_TAP_QUIET,
                                   (uint8_t) CONFIG_OMI_IMU_TAP_SHOCK,
                                   &regs);
    uint8_t tap_cfg = regs.tap_cfg;
    uint8_t wake_ths = regs.wake_ths;
    uint8_t md1_cfg = regs.md1_cfg;
    uint8_t odr = regs.ctrl1_xl_odr;
    uint8_t int_dur2 = regs.int_dur2;

    err = i2c_reg_write_byte_dt(&imu_i2c, LSM6DS_REG_CTRL1_XL, odr);
    if (err) {
        LOG_ERR("Failed to write CTRL1_XL (err %d)", err);
        return err;
    }

    if (IS_ENABLED(CONFIG_OMI_ENABLE_IMU_DOUBLE_TAP)) {
        err = i2c_reg_write_byte_dt(&imu_i2c, LSM6DS_REG_TAP_THS_6D, (uint8_t) CONFIG_OMI_IMU_TAP_THRESHOLD);
        if (err) {
            LOG_ERR("Failed to write TAP_THS_6D (err %d)", err);
            return err;
        }

        err = i2c_reg_write_byte_dt(&imu_i2c, LSM6DS_REG_INT_DUR2, int_dur2);
        if (err) {
            LOG_ERR("Failed to write INT_DUR2 (err %d)", err);
            return err;
        }
    }

    err = i2c_reg_write_byte_dt(&imu_i2c, LSM6DS_REG_WAKE_UP_THS, wake_ths);
    if (err) {
        LOG_ERR("Failed to write WAKE_UP_THS (err %d)", err);
        return err;
    }

    uint8_t wake_up_dur;
    err = i2c_reg_read_byte_dt(&imu_i2c, LSM6DS_REG_WAKE_UP_DUR, &wake_up_dur);
    if (err) {
        LOG_ERR("Failed to read WAKE_UP_DUR (err %d)", err);
        return err;
    }
    wake_up_dur = omi_rust_imu_merge_wake_up_dur(wake_up_dur, (uint8_t) CONFIG_OMI_IMU_WAKE_DURATION);
    err = i2c_reg_write_byte_dt(&imu_i2c, LSM6DS_REG_WAKE_UP_DUR, wake_up_dur);
    if (err) {
        LOG_ERR("Failed to write WAKE_UP_DUR (err %d)", err);
        return err;
    }

    err = i2c_reg_write_byte_dt(&imu_i2c, LSM6DS_REG_TAP_CFG, tap_cfg);
    if (err) {
        LOG_ERR("Failed to write TAP_CFG (err %d)", err);
        return err;
    }

    err = i2c_reg_write_byte_dt(&imu_i2c, LSM6DS_REG_MD1_CFG, md1_cfg);
    if (err) {
        LOG_ERR("Failed to write MD1_CFG (err %d)", err);
        return err;
    }

    return imu_clear_sources();
}

int imu_gesture_init(void)
{
    int err;

    if (!device_is_ready(imu_i2c.bus)) {
        LOG_WRN("IMU i2c bus not ready; gestures disabled");
        return -ENODEV;
    }
    if (!gpio_is_ready_dt(&imu_int1)) {
        LOG_WRN("IMU INT1 gpio not ready; gestures disabled");
        return -ENODEV;
    }

    err = imu_program_registers();
    if (err) {
        return err;
    }

    err = gpio_pin_configure_dt(&imu_int1, GPIO_INPUT);
    if (err) {
        LOG_ERR("Failed to configure IMU INT1 as input (err %d)", err);
        return err;
    }

    if (!imu_gesture_ready) {
        gpio_init_callback(&imu_int1_cb, imu_int1_isr, BIT(imu_int1.pin));
        err = gpio_add_callback(imu_int1.port, &imu_int1_cb);
        if (err) {
            LOG_ERR("Failed to add IMU INT1 callback (err %d)", err);
            return err;
        }
    }

    err = gpio_pin_interrupt_configure_dt(&imu_int1, GPIO_INT_EDGE_RISING);
    if (err) {
        LOG_ERR("Failed to configure IMU INT1 interrupt (err %d)", err);
        return err;
    }

    imu_gesture_ready = true;
    LOG_INF("IMU gestures armed: wake_ths=%d wake_dur=%d double_tap=%d",
            CONFIG_OMI_IMU_WAKE_THRESHOLD,
            CONFIG_OMI_IMU_WAKE_DURATION,
            IS_ENABLED(CONFIG_OMI_ENABLE_IMU_DOUBLE_TAP));
    return 0;
}

void imu_gesture_arm_system_off(void)
{
    if (!imu_gesture_ready) {
        return;
    }

    if (imu_program_registers()) {
        LOG_WRN("IMU re-arm before system off failed; button wake only");
        return;
    }

    int err = gpio_pin_interrupt_configure_dt(&imu_int1, GPIO_INT_LEVEL_HIGH);
    if (err) {
        LOG_WRN("Failed to arm IMU INT1 as a system-off wake source (err %d)", err);
        return;
    }

    LOG_INF("IMU INT1 armed as system-off wake source");
}
