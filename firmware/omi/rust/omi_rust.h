#ifndef OMI_RUST_H
#define OMI_RUST_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int omi_rust_selftest(void);
void omi_rust_ring_header(uint16_t len, uint8_t *out);
void omi_rust_packet_header(uint16_t id, uint8_t index, uint8_t *out);

uint8_t omi_rust_battery_raw_percentage(uint16_t battery_millivolt, bool is_charging);
uint8_t omi_rust_battery_ema_step(uint32_t current_ema, uint8_t new_value, bool is_charging);

typedef enum {
    OMI_RUST_GESTURE_NONE = 0,
    OMI_RUST_GESTURE_MOTION = 1,
    OMI_RUST_GESTURE_DOUBLE_TAP = 2,
} omi_rust_gesture_t;

uint8_t omi_rust_imu_classify(uint8_t wake_src, uint8_t tap_src, bool double_tap_enabled);

typedef struct {
    uint8_t ctrl1_xl_odr;
    uint8_t tap_cfg;
    uint8_t wake_ths;
    uint8_t int_dur2;
    uint8_t md1_cfg;
} omi_rust_imu_registers_t;

void omi_rust_imu_program_registers(bool double_tap, uint8_t wake_threshold, uint8_t tap_duration,
                                    uint8_t tap_quiet, uint8_t tap_shock,
                                    omi_rust_imu_registers_t *out);
uint8_t omi_rust_imu_merge_wake_up_dur(uint8_t existing, uint8_t wake_duration);

typedef enum {
    OMI_RUST_BUTTON_EVENT_NONE = 0,
    OMI_RUST_BUTTON_EVENT_SINGLE_TAP = 1,
    OMI_RUST_BUTTON_EVENT_DOUBLE_TAP = 2,
    OMI_RUST_BUTTON_EVENT_LONG_PRESS = 3,
    OMI_RUST_BUTTON_EVENT_RELEASE = 4,
} omi_rust_button_event_t;

uint8_t omi_rust_button_step(bool pressed);
void omi_rust_button_reset(void);

uint32_t omi_rust_haptic_duration_from_ble(uint8_t value);
uint32_t omi_rust_haptic_clamp_duration(uint32_t duration);

uint32_t omi_rust_led_pulse_width_ns(uint32_t period_ns, uint8_t level);

typedef enum {
    OMI_RUST_ERROR_SETTINGS = 0,
    OMI_RUST_ERROR_LED_DRIVER = 1,
    OMI_RUST_ERROR_BATTERY_INIT = 2,
    OMI_RUST_ERROR_BATTERY_CHARGE = 3,
    OMI_RUST_ERROR_BUTTON = 4,
    OMI_RUST_ERROR_HAPTIC = 5,
    OMI_RUST_ERROR_SD_CARD = 6,
    OMI_RUST_ERROR_STORAGE = 7,
    OMI_RUST_ERROR_TRANSPORT = 8,
    OMI_RUST_ERROR_CODEC = 9,
    OMI_RUST_ERROR_MICROPHONE = 10,
} omi_rust_error_kind_t;

typedef struct {
    bool red;
    bool green;
    bool blue;
    uint8_t blinks;
} omi_rust_error_pattern_t;

bool omi_rust_feedback_error_pattern(uint8_t kind, omi_rust_error_pattern_t *out);

#ifdef __cplusplus
}
#endif

#endif
