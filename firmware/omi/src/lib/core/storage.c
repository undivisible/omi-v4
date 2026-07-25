#include "storage.h"

#include <errno.h>
#include <string.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/l2cap.h>
#include <zephyr/bluetooth/services/bas.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/atomic.h>

#include "rtc.h"
#include "sd_card.h"
#include "transport.h"
#include "utils.h"
#include "omi_rust.h"
#ifdef CONFIG_OMI_ENABLE_WIFI
#include "wifi.h"
#include "mic.h"
#endif

LOG_MODULE_REGISTER(storage, CONFIG_LOG_DEFAULT_LEVEL);


#define STORAGE_DEFERRED 0xFF

#define INVALID_COMMAND 6
#define STORAGE_NOT_READY 9
#define SEQ_OUT_OF_RANGE 10

#define STORAGE_IDLE_POLL_MS_OFFLINE 2000
#define STORAGE_IDLE_POLL_MS_CONNECTED 1
#define STORAGE_WRITE_NOTIFY_ATTR_IDX 2
#define STORAGE_STATUS_REFRESH_MS 250

#define STORAGE_CHUNK_COUNT 36U
#define STORAGE_BUFFER_SIZE (RAW_AUDIO_PACKET_BYTES * STORAGE_CHUNK_COUNT)
#define STORAGE_CONTROL_NOTIFY_SIZE 32
#define STORAGE_NOTIFY_VALUE_MAX_LEN ((CONFIG_BT_L2CAP_TX_MTU > 3U) ? (CONFIG_BT_L2CAP_TX_MTU - 3U) : 20U)

#define SYNC_SPEED_LOG_INTERVAL_MS (2 * 1000)

static void storage_config_changed_handler(const struct bt_gatt_attr *attr, uint16_t value);
static ssize_t storage_write_handler(struct bt_conn *conn,
                                     const struct bt_gatt_attr *attr,
                                     const void *buf,
                                     uint16_t len,
                                     uint16_t offset,
                                     uint8_t flags);
static ssize_t storage_read_characteristic(struct bt_conn *conn,
                                           const struct bt_gatt_attr *attr,
                                           void *buf,
                                           uint16_t len,
                                           uint16_t offset);

static struct bt_uuid_128 storage_service_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x30295780, 0x4301, 0xEABD, 0x2904, 0x2849ADFEAE43));
static struct bt_uuid_128 storage_write_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x30295781, 0x4301, 0xEABD, 0x2904, 0x2849ADFEAE43));
static struct bt_uuid_128 storage_read_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x30295782, 0x4301, 0xEABD, 0x2904, 0x2849ADFEAE43));
#ifdef CONFIG_OMI_ENABLE_WIFI
static struct bt_uuid_128 storage_wifi_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x30295783, 0x4301, 0xEABD, 0x2904, 0x2849ADFEAE43));
#endif

K_THREAD_STACK_DEFINE(storage_stack, 4096);
static struct k_thread storage_thread;

static struct bt_gatt_attr storage_service_attr[] = {
    BT_GATT_PRIMARY_SERVICE(&storage_service_uuid),
    BT_GATT_CHARACTERISTIC(&storage_write_uuid.uuid,
                           BT_GATT_CHRC_WRITE | BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_WRITE,
                           NULL,
                           storage_write_handler,
                           NULL),
    BT_GATT_CCC(storage_config_changed_handler, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
    BT_GATT_CHARACTERISTIC(&storage_read_uuid.uuid,
                           BT_GATT_CHRC_READ | BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_READ,
                           storage_read_characteristic,
                           NULL,
                           NULL),
    BT_GATT_CCC(storage_config_changed_handler, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
#ifdef CONFIG_OMI_ENABLE_WIFI
    BT_GATT_CHARACTERISTIC(&storage_wifi_uuid.uuid,
                           BT_GATT_CHRC_WRITE | BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_WRITE_ENCRYPT,
                           NULL,
                           storage_wifi_handler,
                           NULL),
    BT_GATT_CCC(storage_config_changed_handler,
                BT_GATT_PERM_READ_ENCRYPT | BT_GATT_PERM_WRITE_ENCRYPT),
#endif
};

struct bt_gatt_service storage_service = BT_GATT_SERVICE(storage_service_attr);

static uint8_t storage_buffer[STORAGE_BUFFER_SIZE];
static uint8_t data_notify_buf[STORAGE_NOTIFY_VALUE_MAX_LEN];
static uint8_t control_notify_buf[STORAGE_CONTROL_NOTIFY_SIZE];

bool storage_is_on = false;

static uint8_t info_requested;
static uint8_t clear_requested;
static uint8_t read_request_pending;
static uint8_t advance_request_pending;
static uint8_t stop_requested;
#ifdef CONFIG_OMI_ENABLE_WIFI
static uint8_t wifi_sync_all_requested;
static bool wifi_transfer_active;
static uint64_t wifi_read_seq;
static uint64_t wifi_end_seq;
static bool wifi_header_sent;
#define WIFI_CFG_ERR_INVALID_PWD_LEN 4
#define WIFI_NOTIFY_ATTR_IDX 8
static ssize_t storage_wifi_handler(struct bt_conn *conn,
                                    const struct bt_gatt_attr *attr,
                                    const void *buf,
                                    uint16_t len,
                                    uint16_t offset,
                                    uint8_t flags);
static void wifi_start_work_handler(struct k_work *work);
static struct k_work wifi_start_work;
#endif

/* On connect the SD may still be remounting. Hold a sync request and wait up to
 * this long for the card to become ready, then read -- instead of replying
 * "not ready" (the app only triggers sync once, so it would give up). */
#define STORAGE_SD_READY_TIMEOUT_MS 5000
static int64_t info_deadline;
static int64_t read_deadline;

static uint64_t pending_start_seq;
static uint32_t pending_packet_count;
static uint64_t pending_advance_seq;

static atomic_t storage_status_used_bytes = ATOMIC_INIT(0);
static atomic_t storage_status_unread_packets = ATOMIC_INIT(0);
static atomic_t storage_status_free_bytes = ATOMIC_INIT(0);
static atomic_t storage_status_rtc_valid = ATOMIC_INIT(0);
static int64_t storage_status_refresh_deadline_ms;

typedef enum {
    SYNC_SPEED_MODE_NONE = 0,
    SYNC_SPEED_MODE_BLE,
#ifdef CONFIG_OMI_ENABLE_WIFI
    SYNC_SPEED_MODE_WIFI,
#endif
} sync_speed_mode_t;

/* Sync-speed metering is purely a logging aid. Compile it out entirely when
 * logging is disabled (release build) so it costs nothing on the transfer hot
 * path. */
#if defined(CONFIG_LOG)
static sync_speed_mode_t sync_speed_mode = SYNC_SPEED_MODE_NONE;
static int64_t sync_speed_window_start_ms;
static uint64_t sync_speed_window_bytes;

static void sync_speed_reset(sync_speed_mode_t mode)
{
    sync_speed_mode = mode;
    sync_speed_window_start_ms = k_uptime_get();
    sync_speed_window_bytes = 0;
}

static void sync_speed_add_bytes(uint32_t bytes)
{
    if (sync_speed_mode == SYNC_SPEED_MODE_NONE || bytes == 0U) {
        return;
    }

    sync_speed_window_bytes += bytes;
    int64_t now = k_uptime_get();
    int64_t elapsed_ms = now - sync_speed_window_start_ms;

    if (elapsed_ms >= SYNC_SPEED_LOG_INTERVAL_MS) {
        uint64_t kbps = (sync_speed_window_bytes * 1000U) / (elapsed_ms * 1024U);
        const char *mode_str =
#ifdef CONFIG_OMI_ENABLE_WIFI
            (sync_speed_mode == SYNC_SPEED_MODE_WIFI) ? "WiFi" :
#endif
            "BLE";
        LOG_INF("Sync speed (%s): %u KB/s", mode_str, (uint32_t) kbps);
        sync_speed_window_start_ms = now;
        sync_speed_window_bytes = 0;
    }
}
#else
static inline void sync_speed_reset(sync_speed_mode_t mode)
{
    ARG_UNUSED(mode);
}
static inline void sync_speed_add_bytes(uint32_t bytes)
{
    ARG_UNUSED(bytes);
}
#endif /* CONFIG_LOG */

static void storage_status_cache_set(const sd_ring_info_t *info)
{
    if (!info) {
        return;
    }

    uint64_t unread_packets = info->write_seq - info->read_seq;
    uint64_t used_bytes = unread_packets * RAW_AUDIO_PACKET_BYTES;
    uint64_t free_bytes = ((uint64_t) info->capacity_packets - unread_packets) * RAW_AUDIO_PACKET_BYTES;

    atomic_set(&storage_status_used_bytes, (atomic_val_t) MIN(used_bytes, (uint64_t) UINT32_MAX));
    atomic_set(&storage_status_unread_packets, (atomic_val_t) MIN(unread_packets, (uint64_t) UINT32_MAX));
    atomic_set(&storage_status_free_bytes, (atomic_val_t) MIN(free_bytes, (uint64_t) UINT32_MAX));
    atomic_set(&storage_status_rtc_valid, rtc_is_valid() ? 1 : 0);
}

static void storage_status_cache_refresh(void)
{
    sd_ring_info_t info;

    if (sd_ring_get_info(&info) == 0) {
        storage_status_cache_set(&info);
    }
}

static void storage_status_cache_maybe_refresh(bool force)
{
    int64_t now = k_uptime_get();

    if (!force && now < storage_status_refresh_deadline_ms) {
        return;
    }

    storage_status_refresh_deadline_ms = now + STORAGE_STATUS_REFRESH_MS;
    storage_status_cache_refresh();
}

static bool storage_notify_ready(struct bt_conn *conn)
{
    return conn &&
           bt_gatt_is_subscribed(conn, &storage_service.attrs[STORAGE_WRITE_NOTIFY_ATTR_IDX], BT_GATT_CCC_NOTIFY);
}

static int storage_notify(struct bt_conn *conn, const void *data, uint16_t len)
{
    if (!storage_notify_ready(conn)) {
        return -EAGAIN;
    }

    return bt_gatt_notify(conn, &storage_service.attrs[STORAGE_WRITE_NOTIFY_ATTR_IDX], data, len);
}

static void storage_data_tx_done(struct bt_conn *conn, void *user_data)
{
    ARG_UNUSED(conn);
    ARG_UNUSED(user_data);
    transport_bulk_tx_release();
}

/* Send a bulk DATA notification through the shared TX throttle so the sync
 * stream never consumes the TX buffers reserved for short control notifications
 * (battery / charging / status). Returns the same codes as storage_notify():
 * 0 on success, -EAGAIN if unsubscribed, -ENOMEM if no throttle slot / no buffer
 * (caller yields and retries). */
static int storage_notify_data(struct bt_conn *conn, const void *data, uint16_t len)
{
    if (!storage_notify_ready(conn)) {
        return -EAGAIN;
    }

    /* Reserve a shared slot; short timeout so a stalled link doesn't hang the
     * transfer -> falls back to the -ENOMEM yield/retry path. */
    if (transport_bulk_tx_acquire(K_MSEC(200)) != 0) {
        return -ENOMEM;
    }

    struct bt_gatt_notify_params params = {
        .attr = &storage_service.attrs[STORAGE_WRITE_NOTIFY_ATTR_IDX],
        .data = data,
        .len = len,
        .func = storage_data_tx_done,
        .user_data = NULL,
    };

    int err = bt_gatt_notify_cb(conn, &params);
    if (err) {
        /* Callback will not fire -> release the slot we just took. */
        transport_bulk_tx_release();
    }
    return err;
}

static void storage_config_changed_handler(const struct bt_gatt_attr *attr, uint16_t value)
{
    ARG_UNUSED(attr);

    storage_is_on = true;
    if (value == BT_GATT_CCC_NOTIFY) {
        LOG_INF("Client subscribed for storage notifications");
    } else if (value == 0) {
        LOG_INF("Client unsubscribed from storage notifications");
    } else {
        LOG_ERR("Invalid storage CCC value: %u", value);
    }
}

static uint8_t storage_status_from_error(int err, uint8_t fallback_status)
{
    return omi_rust_storage_status_from_error(err, fallback_status);
}

static uint16_t get_ble_data_chunk_size(struct bt_conn *conn)
{
    uint16_t mtu = 0;

    if (conn) {
        mtu = bt_gatt_get_mtu(conn);
    }

    return omi_rust_storage_ble_chunk_size(mtu);
}

static int send_ack(struct bt_conn *conn, uint8_t status)
{
    uint16_t len = omi_rust_storage_encode_ack(status, control_notify_buf);
    return storage_notify(conn, control_notify_buf, len);
}

static int send_done(struct bt_conn *conn, uint8_t status, uint64_t next_seq)
{
    uint16_t len = omi_rust_storage_encode_done(
        status, next_seq, omi_rust_storage_transfer_data_crc(), control_notify_buf);
    return storage_notify(conn, control_notify_buf, len);
}

static int send_ring_info_response(struct bt_conn *conn)
{
    sd_ring_info_t info;
    int ret = sd_ring_get_info(&info);
    if (ret < 0) {
        return send_ack(conn, storage_status_from_error(ret, STORAGE_NOT_READY));
    }

    storage_status_cache_set(&info);

    omi_rust_ring_info_fields_t fields = {
        .read_seq = info.read_seq,
        .write_seq = info.write_seq,
        .capacity_packets = info.capacity_packets,
        .dropped_packets = info.dropped_packets,
        .packet_bytes = RAW_AUDIO_PACKET_BYTES,
    };
    uint16_t len = omi_rust_storage_encode_ring_info(&fields, control_notify_buf);
    return storage_notify(conn, control_notify_buf, len);
}

static void reset_transfer_state(void)
{
    omi_rust_storage_transfer_reset();
    transport_conn_params_reevaluate();
}

void storage_stop_transfer(void)
{
    reset_transfer_state();
#ifdef CONFIG_OMI_ENABLE_WIFI
    wifi_transfer_active = false;
    wifi_header_sent = false;
    wifi_sync_all_requested = 0;
#endif
}

bool storage_transfer_active(void)
{
    return omi_rust_storage_transfer_active();
}

static bool consume_stop_request(void)
{
    if (!stop_requested) {
        return false;
    }

    stop_requested = 0;
    storage_stop_transfer();
    return true;
}

static int start_pending_read(struct bt_conn *conn)
{
    sd_ring_info_t info;
    int ret = sd_ring_get_info(&info);
    if (ret < 0) {
        return send_ack(conn, storage_status_from_error(ret, STORAGE_NOT_READY));
    }

    if (pending_start_seq < info.read_seq || pending_start_seq > info.write_seq) {
        return send_ack(conn, SEQ_OUT_OF_RANGE);
    }

    storage_status_cache_set(&info);

    uint64_t available_packets = info.write_seq - pending_start_seq;
    uint32_t requested_packets = pending_packet_count;
    if (requested_packets == 0U || (uint64_t) requested_packets > available_packets) {
        requested_packets = (available_packets > UINT32_MAX) ? UINT32_MAX : (uint32_t) available_packets;
    }

    omi_rust_storage_transfer_start(pending_start_seq, requested_packets);
    sync_speed_reset(SYNC_SPEED_MODE_NONE);
    transport_conn_params_reevaluate();

    return 0;
}

static void write_to_gatt(struct bt_conn *conn)
{
    if (!omi_rust_storage_transfer_active() || omi_rust_storage_transfer_done_pending()) {
        return;
    }

    if (consume_stop_request()) {
        return;
    }

    if (!omi_rust_storage_transfer_read_begin_sent()) {
        uint16_t len = omi_rust_storage_encode_read_begin(
            omi_rust_storage_transfer_start_seq(),
            omi_rust_storage_transfer_remaining_packets(),
            control_notify_buf);

        int err = storage_notify(conn, control_notify_buf, len);
        if (err == -ENOMEM) {
            k_yield();
            consume_stop_request();
            return;
        }
        if (err == -EAGAIN) {
            storage_stop_transfer();
            return;
        }
        if (err) {
            omi_rust_storage_transfer_complete(storage_status_from_error(err, STORAGE_NOT_READY));
            return;
        }

        omi_rust_storage_transfer_mark_read_begin_sent();
    }

    if (omi_rust_storage_transfer_remaining_packets() == 0U) {
        omi_rust_storage_transfer_complete(0);
        return;
    }

#if defined(CONFIG_LOG)
    if (sync_speed_mode != SYNC_SPEED_MODE_BLE) {
        sync_speed_reset(SYNC_SPEED_MODE_BLE);
    }
#endif

    uint16_t ble_chunk = get_ble_data_chunk_size(conn);

    while (omi_rust_storage_transfer_remaining_packets() > 0U) {
        if (consume_stop_request()) {
            return;
        }

        uint32_t packets_to_read = MIN(omi_rust_storage_transfer_remaining_packets(), (uint32_t) STORAGE_CHUNK_COUNT);
        uint32_t bytes_read = 0;
        uint32_t packets_read = 0;
        int ret = sd_ring_read(
            omi_rust_storage_transfer_current_seq(),
            storage_buffer,
            packets_to_read * RAW_AUDIO_PACKET_BYTES,
            &bytes_read,
            &packets_read);
        if (ret < 0) {
            omi_rust_storage_transfer_complete(storage_status_from_error(ret, STORAGE_NOT_READY));
            return;
        }
        if (packets_read == 0U || bytes_read == 0U) {
            omi_rust_storage_transfer_complete(0);
            return;
        }

        uint32_t bytes_sent = 0;
        while (bytes_sent < bytes_read) {
            if (consume_stop_request()) {
                return;
            }

            uint32_t payload = MIN(bytes_read - bytes_sent, (uint32_t) ble_chunk);
            uint16_t len = omi_rust_storage_encode_data(
                storage_buffer + bytes_sent, payload, data_notify_buf);

            int err = storage_notify_data(conn, data_notify_buf, len);
            if (err == -ENOMEM) {
                k_yield();
                if (consume_stop_request()) {
                    return;
                }
                continue;
            }
            if (err == -EAGAIN) {
                storage_stop_transfer();
                return;
            }
            if (err) {
                omi_rust_storage_transfer_complete(storage_status_from_error(err, STORAGE_NOT_READY));
                return;
            }

            bytes_sent += payload;
            for (uint32_t i = bytes_sent - payload; i < bytes_sent; i++) {
                omi_rust_storage_transfer_update_crc_byte(storage_buffer[i]);
            }
            sync_speed_add_bytes(payload);
        }

        omi_rust_storage_transfer_note_packets_read(packets_read);

    }
}

static ssize_t storage_read_characteristic(struct bt_conn *conn,
                                           const struct bt_gatt_attr *attr,
                                           void *buf,
                                           uint16_t len,
                                           uint16_t offset)
{
    uint32_t payload[4] = {
        (uint32_t) atomic_get(&storage_status_used_bytes),
        (uint32_t) atomic_get(&storage_status_unread_packets),
        (uint32_t) atomic_get(&storage_status_free_bytes),
        (uint32_t) atomic_get(&storage_status_rtc_valid),
    };

    return bt_gatt_attr_read(conn, attr, buf, len, offset, payload, sizeof(payload));
}

static uint8_t parse_storage_command(void *buf, uint16_t len)
{
    omi_rust_storage_parsed_t parsed;
    uint8_t status = omi_rust_storage_parse_command(buf, len, &parsed);

    if (status == INVALID_COMMAND || parsed.command == OMI_RUST_STORAGE_CMD_INVALID) {
        return INVALID_COMMAND;
    }

    switch (parsed.command) {
    case OMI_RUST_STORAGE_CMD_RING_INFO:
        info_requested = 1;
        break;
    case OMI_RUST_STORAGE_CMD_RING_READ:
        pending_start_seq = parsed.start_seq;
        pending_packet_count = parsed.packet_count;
        read_request_pending = 1;
        break;
    case OMI_RUST_STORAGE_CMD_RING_ADVANCE:
        pending_advance_seq = parsed.advance_seq;
        advance_request_pending = 1;
        break;
    case OMI_RUST_STORAGE_CMD_RING_CLEAR:
        clear_requested = 1;
        break;
    case OMI_RUST_STORAGE_CMD_STOP_SYNC:
        stop_requested = 1;
        break;
    default:
        return INVALID_COMMAND;
    }

    return status;
}

static ssize_t storage_write_handler(struct bt_conn *conn,
                                     const struct bt_gatt_attr *attr,
                                     const void *buf,
                                     uint16_t len,
                                     uint16_t offset,
                                     uint8_t flags)
{
    ARG_UNUSED(attr);
    ARG_UNUSED(offset);
    ARG_UNUSED(flags);

    if (len < 1U) {
        (void) send_ack(conn, INVALID_COMMAND);
        return len;
    }

    uint8_t result = parse_storage_command((void *) buf, len);
    if (result != STORAGE_DEFERRED) {
        (void) send_ack(conn, result);
    }

    return len;
}


#ifdef CONFIG_OMI_ENABLE_WIFI
static void wifi_start_work_handler(struct k_work *work)
{
    ARG_UNUSED(work);
    mic_pause();
    (void)wifi_turn_on();
}

static void wifi_notify_result(struct bt_conn *conn, uint8_t code)
{
    if (!conn) {
        return;
    }
    (void)bt_gatt_notify(conn, &storage_service.attrs[WIFI_NOTIFY_ATTR_IDX], &code, 1);
}

static ssize_t storage_wifi_handler(struct bt_conn *conn,
                                    const struct bt_gatt_attr *attr,
                                    const void *buf,
                                    uint16_t len,
                                    uint16_t offset,
                                    uint8_t flags)
{
    ARG_UNUSED(attr);
    ARG_UNUSED(offset);
    ARG_UNUSED(flags);
    uint8_t result = 0;

    if (len < 1U) {
        wifi_notify_result(conn, 1);
        return len;
    }

    if (!wifi_is_hw_available()) {
        wifi_notify_result(conn, omi_rust_wifi_err_hw_unavailable());
        return len;
    }

    const uint8_t *bytes = buf;
    const uint8_t cmd = bytes[0];

    switch (omi_rust_wifi_classify_command(cmd)) {
    case 0x01: {
        if (len < 2U) {
            result = 2;
            break;
        }
        uint16_t idx = 1;
        uint8_t ssid_len = bytes[idx++];
        if (ssid_len == 0 || ssid_len > WIFI_MAX_SSID_LEN || idx + ssid_len > len) {
            result = 3;
            break;
        }
        char ssid[WIFI_MAX_SSID_LEN + 1] = {0};
        memcpy(ssid, &bytes[idx], ssid_len);
        idx += ssid_len;
        if (idx >= len) {
            result = WIFI_CFG_ERR_INVALID_PWD_LEN;
            break;
        }
        uint8_t pwd_len = bytes[idx++];
        if (pwd_len < WIFI_MIN_PASSWORD_LEN || pwd_len > WIFI_MAX_PASSWORD_LEN ||
            idx + pwd_len > len) {
            result = WIFI_CFG_ERR_INVALID_PWD_LEN;
            break;
        }
        char pwd[WIFI_MAX_PASSWORD_LEN + 1] = {0};
        memcpy(pwd, &bytes[idx], pwd_len);
        result = setup_wifi_credentials(ssid, pwd) == 0 ? 0 : 3;
        break;
    }
    case 0x02:
        if (is_wifi_on()) {
            result = 5;
            break;
        }
        if (!wifi_softap_credentials_ready()) {
            /* SoftAP requires a prior WIFI_SETUP (0x01) write. */
            result = 3;
            break;
        }
        wifi_sync_all_requested = 1;
        k_work_submit(&wifi_start_work);
        result = 0;
        break;
    case 0x03:
        storage_stop_transfer();
        wifi_turn_off();
        mic_resume();
        result = 0;
        break;
    case 0x04: {
        storage_stop_transfer();
        int err = clear_audio_directory();
        result = err ? 0x10 : 0;
        break;
    }
#ifdef CONFIG_OMI_ENABLE_WIFI_HOME_STA
    case 0x10: {
        if (len < 2U) {
            result = 2;
            break;
        }
        uint16_t idx = 1;
        uint8_t ssid_len = bytes[idx++];
        if (ssid_len == 0 || ssid_len > WIFI_MAX_SSID_LEN || idx + ssid_len > len) {
            result = 3;
            break;
        }
        char ssid[WIFI_MAX_SSID_LEN + 1] = {0};
        memcpy(ssid, &bytes[idx], ssid_len);
        idx += ssid_len;
        if (idx >= len) {
            result = WIFI_CFG_ERR_INVALID_PWD_LEN;
            break;
        }
        uint8_t pwd_len = bytes[idx++];
        if (pwd_len < WIFI_MIN_PASSWORD_LEN || pwd_len > WIFI_MAX_PASSWORD_LEN ||
            idx + pwd_len > len) {
            result = WIFI_CFG_ERR_INVALID_PWD_LEN;
            break;
        }
        char pwd[WIFI_MAX_PASSWORD_LEN + 1] = {0};
        memcpy(pwd, &bytes[idx], pwd_len);
        result = wifi_home_set_credentials(ssid, pwd) == 0 ? 0 : 3;
        break;
    }
    case 0x11:
        wifi_home_clear_credentials();
        result = 0;
        break;
    case 0x12: {
        if (len < 2U) {
            result = 0x21;
            break;
        }
        uint16_t idx = 1;
        uint8_t host_len = bytes[idx++];
        if (host_len == 0 || idx + host_len >= len) {
            result = 0x21;
            break;
        }
        char host[129] = {0};
        if (host_len > 128) {
            result = 0x21;
            break;
        }
        memcpy(host, &bytes[idx], host_len);
        idx += host_len;
        if (idx >= len) {
            result = 0x21;
            break;
        }
        uint8_t device_id_len = bytes[idx++];
        if (device_id_len == 0 || device_id_len > 64 || idx + device_id_len >= len) {
            result = 0x21;
            break;
        }
        char device_id[65] = {0};
        memcpy(device_id, &bytes[idx], device_id_len);
        idx += device_id_len;
        uint8_t token_len = bytes[idx++];
        if (token_len == 0 || token_len > 96 || idx + token_len > len) {
            result = 0x21;
            break;
        }
        char token[97] = {0};
        memcpy(token, &bytes[idx], token_len);
        result = wifi_home_set_cloud_token(host, device_id, token) == 0 ? 0 : 0x21;
        break;
    }
#else
    case 0x10:
    case 0x11:
    case 0x12:
        result = 0x20;
        break;
#endif
    default:
        result = 0xFF;
        break;
    }

    wifi_notify_result(conn, result);
    return len;
}

static void wifi_write_ring(void)
{
    if (!wifi_transfer_active || !is_wifi_on() || !is_wifi_transport_ready()) {
        return;
    }

    if (!wifi_header_sent) {
        uint8_t hdr[24];
        uint16_t hdr_len = omi_rust_wifi_encode_softap_header(
            wifi_read_seq, wifi_end_seq, RAW_AUDIO_PACKET_BYTES, hdr);
        size_t sent = 0;
        while (sent < hdr_len && is_wifi_on()) {
            int n = wifi_send_data(hdr + sent, hdr_len - sent);
            if (n <= 0) {
                k_msleep(10);
                break;
            }
            sent += (size_t)n;
        }
        if (sent != hdr_len) {
            return;
        }
        wifi_header_sent = true;
#if defined(CONFIG_LOG)
        sync_speed_reset(SYNC_SPEED_MODE_WIFI);
#endif
    }

    while (wifi_read_seq < wifi_end_seq && is_wifi_on() && is_wifi_transport_ready()) {
        uint32_t packets_to_read = MIN((uint32_t)(wifi_end_seq - wifi_read_seq),
                                       (uint32_t)STORAGE_CHUNK_COUNT);
        uint32_t bytes_read = 0;
        uint32_t packets_read = 0;
        int ret = sd_ring_read(wifi_read_seq, storage_buffer,
                               packets_to_read * RAW_AUDIO_PACKET_BYTES,
                               &bytes_read, &packets_read);
        if (ret < 0 || packets_read == 0U) {
            break;
        }
        size_t sent = 0;
        while (sent < bytes_read && is_wifi_on()) {
            int n = wifi_send_data(storage_buffer + sent, bytes_read - sent);
            if (n <= 0) {
                k_msleep(5);
                break;
            }
            sent += (size_t)n;
            sync_speed_add_bytes((uint32_t)n);
        }
        if (sent != bytes_read) {
            return;
        }
        wifi_read_seq += packets_read;
        (void)sd_ring_advance(wifi_read_seq);
    }

    if (wifi_read_seq >= wifi_end_seq) {
        uint8_t done[10];
        uint16_t done_len = omi_rust_wifi_encode_softap_done(wifi_read_seq, 0, done);
        size_t sent = 0;
        while (sent < done_len && is_wifi_on()) {
            int n = wifi_send_data(done + sent, done_len - sent);
            if (n <= 0) {
                break;
            }
            sent += (size_t)n;
        }
        if (sent != done_len) {
            return;
        }
        wifi_transfer_active = false;
        wifi_header_sent = false;
        LOG_INF("WiFi ring sync complete at seq %llu", (unsigned long long)wifi_read_seq);
        wifi_turn_off();
        mic_resume();
    }
}
#endif

static void storage_write(void)
{
    while (1) {
        struct bt_conn *conn = get_current_connection();

        if (consume_stop_request()) {
            storage_status_cache_maybe_refresh(true);
        }

        if (info_requested) {
            if (!conn) {
                info_requested = 0;
                info_deadline = 0;
            } else if (sd_is_ready()) {
                int ret = send_ring_info_response(conn);
                if (ret == -ENOMEM) {
                    /* No TX buffer right now. Keep the request pending and retry
                     * until the same deadline the SD-ready wait uses, instead of
                     * dropping it: the app only asks once per sync. */
                    if (info_deadline == 0) {
                        info_deadline = k_uptime_get() + STORAGE_SD_READY_TIMEOUT_MS;
                    } else if (k_uptime_get() >= info_deadline) {
                        info_requested = 0;
                        info_deadline = 0;
                    }
                    k_yield();
                } else {
                    info_requested = 0;
                    info_deadline = 0;
                }
            } else {
                /* SD still remounting after connect: wait for it, up to timeout. */
                if (info_deadline == 0) {
                    info_deadline = k_uptime_get() + STORAGE_SD_READY_TIMEOUT_MS;
                } else if (k_uptime_get() >= info_deadline) {
                    (void) send_ack(conn, STORAGE_NOT_READY);
                    info_requested = 0;
                    info_deadline = 0;
                }
            }
        }

        if (clear_requested) {
            clear_requested = 0;
            if (conn) {
                int ret = sd_ring_clear();
                if (ret >= 0) {
                    storage_status_cache_maybe_refresh(true);
                }
                (void) send_ack(conn, ret < 0 ? storage_status_from_error(ret, STORAGE_NOT_READY) : 0);
            }
        }

        if (advance_request_pending) {
            advance_request_pending = 0;
            if (conn) {
                int ret = sd_ring_advance(pending_advance_seq);
                if (ret >= 0) {
                    storage_status_cache_maybe_refresh(true);
                }
                (void) send_ack(conn, ret < 0 ? storage_status_from_error(ret, SEQ_OUT_OF_RANGE) : 0);
            }
        }

        if (read_request_pending) {
            if (!conn) {
                read_request_pending = 0;
                read_deadline = 0;
            } else if (sd_is_ready()) {
                int ret = start_pending_read(conn);
                if (ret < 0) {
                    (void) send_ack(conn, storage_status_from_error(ret, STORAGE_NOT_READY));
                }
                read_request_pending = 0;
                read_deadline = 0;
            } else {
                if (read_deadline == 0) {
                    read_deadline = k_uptime_get() + STORAGE_SD_READY_TIMEOUT_MS;
                } else if (k_uptime_get() >= read_deadline) {
                    (void) send_ack(conn, STORAGE_NOT_READY);
                    read_request_pending = 0;
                    read_deadline = 0;
                }
            }
        }

        if (omi_rust_storage_transfer_active()) {
            if (conn == NULL) {
                storage_stop_transfer();
            } else if (omi_rust_storage_transfer_done_pending()) {
                int err = send_done(
                    conn,
                    omi_rust_storage_transfer_end_status(),
                    omi_rust_storage_transfer_current_seq());
                if (err == -ENOMEM) {
                    k_yield();
                } else {
                    reset_transfer_state();
                }
            } else {
                write_to_gatt(conn);
            }
        }


#ifdef CONFIG_OMI_ENABLE_WIFI
        if (wifi_sync_all_requested && is_wifi_on() && is_wifi_transport_ready() &&
            !wifi_transfer_active && !omi_rust_storage_transfer_active()) {
            wifi_sync_all_requested = 0;
            sd_ring_info_t info;
            if (sd_ring_get_info(&info) == 0 && info.write_seq > info.read_seq) {
                wifi_read_seq = info.read_seq;
                wifi_end_seq = info.write_seq;
                wifi_header_sent = false;
                wifi_transfer_active = true;
                LOG_INF("WiFi ready - syncing ring %llu..%llu",
                        (unsigned long long)wifi_read_seq,
                        (unsigned long long)wifi_end_seq);
            } else {
                LOG_INF("WiFi ready - nothing to sync");
            }
        }
        if (wifi_transfer_active) {
            if (!is_wifi_on()) {
                LOG_WRN("WiFi dropped mid ring sync — aborting");
                storage_stop_transfer();
                mic_resume();
            } else {
                wifi_write_ring();
            }
        }
#endif
        if (!omi_rust_storage_transfer_active()) {
            if (conn) {
                storage_status_cache_maybe_refresh(false);
            }
            uint32_t idle_sleep_ms = conn ? STORAGE_IDLE_POLL_MS_CONNECTED : STORAGE_IDLE_POLL_MS_OFFLINE;
            k_msleep(idle_sleep_ms);
        } else {
            k_yield();
        }
    }
}

int storage_init()
{
#ifdef CONFIG_OMI_ENABLE_WIFI
    k_work_init(&wifi_start_work, wifi_start_work_handler);
#endif
    k_thread_create(&storage_thread,
                    storage_stack,
                    K_THREAD_STACK_SIZEOF(storage_stack),
                    (k_thread_entry_t) storage_write,
                    NULL,
                    NULL,
                    NULL,
                    K_PRIO_PREEMPT(7),
                    0,
                    K_NO_WAIT);
    return 0;
}
