#ifndef FEATURES_H
#define FEATURES_H

#include <stdint.h>

/**
 * @brief Defines the bitmask for available Omi features.
 */
typedef enum {
    OMI_FEATURE_SPEAKER = (1 << 0),
    OMI_FEATURE_ACCELEROMETER = (1 << 1),
    OMI_FEATURE_BUTTON = (1 << 2),
    OMI_FEATURE_BATTERY = (1 << 3),
    OMI_FEATURE_USB = (1 << 4),
    OMI_FEATURE_HAPTIC = (1 << 5),
    OMI_FEATURE_OFFLINE_STORAGE = (1 << 6),
    OMI_FEATURE_LED_DIMMING = (1 << 7),
    OMI_FEATURE_MIC_GAIN = (1 << 8),
    OMI_FEATURE_CHARGING_STATE = (1 << 9),
    OMI_FEATURE_USER_EVENTS = (1 << 10),
    OMI_FEATURE_IMU_GESTURES = (1 << 11),
    OMI_FEATURE_HW_VAD = (1 << 12),
    OMI_FEATURE_BLE_SLEEP_CMD = (1 << 13),
    OMI_FEATURE_CAPTURE_STATE = (1 << 14),
    OMI_FEATURE_DEVICE_NAME_RW = (1 << 15),
} omi_feature_t;

#endif // FEATURES_H
