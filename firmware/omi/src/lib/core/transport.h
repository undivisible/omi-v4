#ifndef TRANSPORT_H
#define TRANSPORT_H

#include <zephyr/drivers/sensor.h>
#include <zephyr/kernel.h>
#ifdef CONFIG_OMI_ENABLE_BATTERY
extern uint8_t battery_percentage;
#endif
/**
 * @brief Initialize the BLE transport logic
 *
 * Initializes the BLE Logic
 *
 * @return 0 if successful, negative errno code if error
 */
int transport_start();

/**
 * @brief Turn off the BLE transport
 *
 * @return 0 if successful, negative errno code if error
 */
int transport_off();

/**
 * @brief Broadcast audio packets over BLE
 *
 * @param buffer Buffer containing audio data
 * @param size Size of the audio data
 * @return 0 if successful, negative errno code if error
 */
int broadcast_audio_packets(uint8_t *buffer, size_t size);

/**
 * @brief Get the current BLE connection
 *
 * @return Pointer to current connection, or NULL if not connected
 */
struct bt_conn *get_current_connection();

/**
 * @brief Check whether the current central is subscribed to audio notifications
 *
 * @return true if a central is connected and has enabled audio notifications
 */
bool transport_is_audio_subscribed(void);

/**
 * @brief Acquire / release a shared BLE TX-throttle slot.
 *
 * The audio pusher and the storage-sync path both take a slot before each bulk
 * notification, capping their COMBINED in-flight count at
 * (CONFIG_BT_CONN_TX_MAX - reserved) so a couple of TX buffers always stay free
 * for short control notifications (battery / charging / status). The slot is
 * released from the notification's bt_gatt_notify_cb completion callback.
 *
 * @return acquire: 0 on success, negative errno on timeout.
 */
int transport_bulk_tx_acquire(k_timeout_t timeout);
void transport_bulk_tx_release(void);

/**
 * @brief Push a charging-state change to the subscribed central.
 *
 * Notifies characteristic 19B10013 (1 byte, 0 = not charging, 1 = charging)
 * from the system workqueue, deduplicated against the last notified value.
 * Safe to call from the charge-detect GPIO interrupt.
 */
void transport_notify_charging_changed(void);

/**
 * @brief Re-evaluate the preferred connection parameters.
 *
 * With CONFIG_OMI_ENABLE_ADAPTIVE_CONN_PARAMS the link runs at the fast
 * interval while audio is subscribed or an offline sync is in flight, and at
 * the idle interval (with peripheral latency) otherwise. Without it this is a
 * no-op and the link stays at the fast interval for the whole connection.
 * Call whenever audio subscription or transfer state changes.
 */
void transport_conn_params_reevaluate(void);

#endif // TRANSPORT_H
