#ifndef OMI_IMU_H_
#define OMI_IMU_H_

#include <stdint.h>

/**
 * @brief Prepare IMU timestamping so time can be estimated across system_off.
 *
 * Stores a (UTC epoch seconds, IMU timestamp counter) base into settings.
 *
 * Safe to call even if the IMU or UTC time is not available.
 */
void lsm6dsl_time_prepare_for_system_off(void);

/**
 * @brief On boot, adjust UTC epoch using IMU timestamp delta.
 *
 * If a valid base was stored before system_off, reads current IMU timestamp and
 * adds the elapsed time to the persisted UTC epoch via rtc_set_utc_time().
 *
 * @return 1 if an adjustment was applied, 0 if not applicable, negative errno on failure.
 */
int lsm6dsl_time_boot_adjust_rtc(void);

#ifdef CONFIG_OMI_ENABLE_IMU_GESTURES
/**
 * @brief Configure LSM6DS3TR-C activity (and optional double-tap) detection.
 *
 * Programs the embedded-function registers, routes them to INT1 latched, and
 * registers a GPIO callback that emits user events and resets the idle
 * auto-sleep timer. Safe to call repeatedly.
 *
 * @return 0 on success, negative errno otherwise.
 */
int imu_gesture_init(void);

/**
 * @brief Re-arm INT1 as a level-sensed wake source before sys_poweroff().
 *
 * Clears any latched interrupt source, re-applies the detection registers
 * (src/imu.c drops the accelerometer to 12.5 Hz on the way down) and switches
 * INT1 to a level interrupt so the nRF5340 GPIO SENSE block can wake the SoC
 * out of system off. No-op if imu_gesture_init() never succeeded.
 */
void imu_gesture_arm_system_off(void);
#endif

#endif
