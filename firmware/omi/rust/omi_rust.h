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

#ifdef __cplusplus
}
#endif

#endif
