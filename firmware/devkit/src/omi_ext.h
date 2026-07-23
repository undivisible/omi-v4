#ifndef OMI_EXT_H
#define OMI_EXT_H

#include <stdbool.h>
#include <stdint.h>

/**
 * @file
 * @brief DevKit port of the CV1 settings / features / time-sync / user-event
 *        BLE surface.
 *
 * The CV1 pendant (../omi) implements these inside its transport.c. The DevKit
 * has a separate, older transport.c, so the portable subset is collected here
 * and registered from transport_start(). Only the characteristics the XIAO
 * nRF52840 Sense can actually back are implemented; see
 * ../BLE_CONTRACTS.md for the per-device support matrix.
 *
 * Wire formats are byte-identical to the CV1 firmware.
 */

#define OMI_USER_EVENT_PAYLOAD_LEN 8

#define OMI_USER_EVENT_NONE 0x00
#define OMI_USER_EVENT_BOOKMARK 0x01
#define OMI_USER_EVENT_ASSISTANT 0x02
#define OMI_USER_EVENT_POWER_OFF 0x03
#define OMI_USER_EVENT_MIC_SLEEP 0x10
#define OMI_USER_EVENT_MIC_WAKE 0x11

#define OMI_USER_EVENT_SRC_NONE 0x00
#define OMI_USER_EVENT_SRC_BUTTON 0x01
#define OMI_USER_EVENT_SRC_MIC 0x02
#define OMI_USER_EVENT_SRC_IMU 0x03
#define OMI_USER_EVENT_SRC_SYSTEM 0x04

/**
 * @brief Register the extension services with the GATT database.
 *
 * Call from transport_start() after bt_enable() and before advertising.
 */
void omi_ext_register(void);

/**
 * @brief Emit a user event (notify now, or queue until a central subscribes).
 *
 * Safe from thread and workqueue context; not from an ISR.
 */
void omi_user_event_emit(uint8_t code, uint8_t source);

/**
 * @brief Flush queued user events. Called automatically on subscribe.
 */
void omi_user_event_flush(void);

/**
 * @brief Reset the idle auto-sleep timer because the user interacted.
 *
 * No-op when CONFIG_OMI_ENABLE_IDLE_SLEEP is disabled.
 */
void omi_note_user_activity(void);

/**
 * @brief Current UTC epoch seconds, or 0 when the clock has never been set.
 *
 * DevKit timekeeping is volatile: the app sets it over 19B10031 and the value
 * is carried forward with k_uptime_get(). It is not persisted, so it is lost
 * on reboot or system off. The CV1 build persists a base in NVS instead.
 */
uint32_t omi_rtc_get_utc(void);

/** @brief True when the clock has been set at least once since boot. */
bool omi_rtc_is_valid(void);

#endif // OMI_EXT_H
