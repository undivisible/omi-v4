#ifndef USER_EVENT_H
#define USER_EVENT_H

#include <stdbool.h>
#include <stdint.h>

/**
 * @file
 * @brief Device-originated user/system event stream.
 *
 * Events are delivered to the companion app over the settings service
 * characteristic 19B10017-E8F2-537E-4F6C-D104768A1214 (read + notify).
 *
 * Wire format, 8 bytes, little-endian:
 *
 *   offset 0 : uint8_t  code    - one of OMI_USER_EVENT_*
 *   offset 1 : uint8_t  source  - one of OMI_USER_EVENT_SRC_*
 *   offset 2 : uint16_t seq     - monotonic counter, wraps at 65535
 *   offset 4 : uint32_t epoch_s - UTC seconds, 0 when the RTC is not synced
 *
 * A read of the characteristic returns the most recently emitted event, or an
 * all-zero payload if none has been emitted since boot.
 */

#define OMI_USER_EVENT_PAYLOAD_LEN 8

#define OMI_USER_EVENT_NONE 0x00
/** Single button tap: "mark this moment". */
#define OMI_USER_EVENT_BOOKMARK 0x01
/** Double button tap: "talk to the assistant". */
#define OMI_USER_EVENT_ASSISTANT 0x02
/** The device is about to enter system off. */
#define OMI_USER_EVENT_POWER_OFF 0x03
/** Microphone entered T5838 hardware AAD sleep; audio stops flowing. */
#define OMI_USER_EVENT_MIC_SLEEP 0x10
/** Microphone left hardware AAD sleep on acoustic activity. */
#define OMI_USER_EVENT_MIC_WAKE 0x11
/** IMU detected motion above the wake threshold. */
#define OMI_USER_EVENT_IMU_MOTION 0x20
/** IMU detected a double tap on the pendant body. */
#define OMI_USER_EVENT_IMU_DOUBLE_TAP 0x21

#define OMI_USER_EVENT_SRC_NONE 0x00
#define OMI_USER_EVENT_SRC_BUTTON 0x01
#define OMI_USER_EVENT_SRC_MIC 0x02
#define OMI_USER_EVENT_SRC_IMU 0x03
#define OMI_USER_EVENT_SRC_SYSTEM 0x04

/**
 * @brief Emit a user event.
 *
 * Notifies immediately when a central is subscribed. Otherwise the event is
 * queued (oldest dropped on overflow) and flushed when a central subscribes.
 * Safe to call from thread and workqueue context; not from an ISR.
 */
void omi_user_event_emit(uint8_t code, uint8_t source);

/**
 * @brief Flush any queued events to the subscribed central.
 */
void omi_user_event_flush(void);

/**
 * @brief Reset the idle auto-sleep timer because the user interacted.
 *
 * Implemented in main.c next to the idle timer it drives. A no-op when
 * CONFIG_OMI_ENABLE_IDLE_SLEEP is disabled.
 */
void omi_note_user_activity(void);

#endif // USER_EVENT_H
