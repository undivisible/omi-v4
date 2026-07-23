#include "omi_ext.h"

#include <string.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/byteorder.h>

#include "button.h"
#include "transport.h"

LOG_MODULE_REGISTER(omi_ext, CONFIG_LOG_DEFAULT_LEVEL);

extern bool is_connected;
#ifdef CONFIG_OMI_ENABLE_USB
extern bool usb_charge;
#endif
#ifdef CONFIG_OMI_ENABLE_CAPTURE_LED
bool is_capturing = false;
#endif

/* ---- volatile UTC clock ---- */

static uint64_t rtc_base_epoch_ms;
static int64_t rtc_base_uptime_ms;
static bool rtc_valid;

uint32_t omi_rtc_get_utc(void)
{
    if (!rtc_valid) {
        return 0U;
    }
    uint64_t now_ms = rtc_base_epoch_ms + (uint64_t) (k_uptime_get() - rtc_base_uptime_ms);
    return (uint32_t) (now_ms / 1000ULL);
}

bool omi_rtc_is_valid(void)
{
    return rtc_valid;
}

static void omi_rtc_set_utc(uint32_t epoch_s)
{
    rtc_base_epoch_ms = (uint64_t) epoch_s * 1000ULL;
    rtc_base_uptime_ms = k_uptime_get();
    rtc_valid = true;
}

/* ---- user events ---- */

struct omi_user_event_record {
    uint8_t code;
    uint8_t source;
    uint16_t seq;
    uint32_t epoch_s;
};

static struct omi_user_event_record user_event_queue[CONFIG_OMI_USER_EVENT_QUEUE_LEN];
static uint8_t user_event_head;
static uint8_t user_event_count;
static uint16_t user_event_next_seq;
static uint8_t user_event_last[OMI_USER_EVENT_PAYLOAD_LEN];
static K_MUTEX_DEFINE(user_event_lock);

static struct bt_gatt_attr *user_event_value_attr(void);

static void user_event_encode(const struct omi_user_event_record *rec, uint8_t *out)
{
    out[0] = rec->code;
    out[1] = rec->source;
    sys_put_le16(rec->seq, out + 2);
    sys_put_le32(rec->epoch_s, out + 4);
}

static bool user_event_try_notify(const struct omi_user_event_record *rec)
{
    struct bt_conn *conn = get_current_connection();
    struct bt_gatt_attr *attr = user_event_value_attr();

    if (conn == NULL || attr == NULL) {
        return false;
    }
    if (!bt_gatt_is_subscribed(conn, attr, BT_GATT_CCC_NOTIFY)) {
        return false;
    }

    uint8_t payload[OMI_USER_EVENT_PAYLOAD_LEN];
    user_event_encode(rec, payload);

    int err = bt_gatt_notify(conn, attr, payload, sizeof(payload));
    if (err) {
        LOG_WRN("User event notify failed: %d", err);
        return false;
    }
    return true;
}

static void user_event_queue_push(const struct omi_user_event_record *rec)
{
    if (user_event_count == CONFIG_OMI_USER_EVENT_QUEUE_LEN) {
        user_event_head = (user_event_head + 1U) % CONFIG_OMI_USER_EVENT_QUEUE_LEN;
        user_event_count--;
    }

    uint8_t tail = (user_event_head + user_event_count) % CONFIG_OMI_USER_EVENT_QUEUE_LEN;
    user_event_queue[tail] = *rec;
    user_event_count++;
}

void omi_user_event_emit(uint8_t code, uint8_t source)
{
    struct omi_user_event_record rec = {
        .code = code,
        .source = source,
        .epoch_s = omi_rtc_get_utc(),
    };

    k_mutex_lock(&user_event_lock, K_FOREVER);
    rec.seq = user_event_next_seq++;
    user_event_encode(&rec, user_event_last);

    if (user_event_count > 0U || !user_event_try_notify(&rec)) {
        user_event_queue_push(&rec);
    }
    k_mutex_unlock(&user_event_lock);

    LOG_INF("User event 0x%02x from source 0x%02x (seq %u)", code, source, rec.seq);
}

void omi_user_event_flush(void)
{
    k_mutex_lock(&user_event_lock, K_FOREVER);
    while (user_event_count > 0U) {
        if (!user_event_try_notify(&user_event_queue[user_event_head])) {
            break;
        }
        user_event_head = (user_event_head + 1U) % CONFIG_OMI_USER_EVENT_QUEUE_LEN;
        user_event_count--;
    }
    k_mutex_unlock(&user_event_lock);
}

static void user_event_ccc_config_changed_handler(const struct bt_gatt_attr *attr, uint16_t value)
{
    ARG_UNUSED(attr);

    if (value == BT_GATT_CCC_NOTIFY) {
        LOG_INF("Client subscribed for user event notifications");
        omi_user_event_flush();
    } else if (value == 0) {
        LOG_INF("Client unsubscribed from user event notifications");
    }
}

static ssize_t settings_user_event_read_handler(struct bt_conn *conn,
                                                const struct bt_gatt_attr *attr,
                                                void *buf,
                                                uint16_t len,
                                                uint16_t offset)
{
    return bt_gatt_attr_read(conn, attr, buf, len, offset, user_event_last, sizeof(user_event_last));
}

/* ---- settings service ---- */

static struct bt_uuid_128 settings_service_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10010, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));
#ifdef CONFIG_OMI_ENABLE_USB
static struct bt_uuid_128 settings_charging_status_characteristic_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10013, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));
#endif
#ifdef CONFIG_OMI_ENABLE_BLE_SLEEP_CMD
static struct bt_uuid_128 settings_sleep_cmd_characteristic_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10014, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));
#endif
#ifdef CONFIG_OMI_ENABLE_CAPTURE_LED
static struct bt_uuid_128 settings_capture_state_characteristic_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10015, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));
#endif
static struct bt_uuid_128 settings_user_event_characteristic_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10017, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));

#ifdef CONFIG_OMI_ENABLE_USB
static ssize_t settings_charging_status_read_handler(struct bt_conn *conn,
                                                     const struct bt_gatt_attr *attr,
                                                     void *buf,
                                                     uint16_t len,
                                                     uint16_t offset)
{
    uint8_t charging_status = usb_charge ? 1U : 0U;
    return bt_gatt_attr_read(conn, attr, buf, len, offset, &charging_status, sizeof(charging_status));
}

static void charging_status_ccc_config_changed_handler(const struct bt_gatt_attr *attr, uint16_t value)
{
    ARG_UNUSED(attr);
    ARG_UNUSED(value);
}
#endif

#ifdef CONFIG_OMI_ENABLE_BLE_SLEEP_CMD
#define OMI_SLEEP_CMD_MAGIC 0x01

static void sleep_cmd_work_handler(struct k_work *work)
{
    ARG_UNUSED(work);
    omi_user_event_emit(OMI_USER_EVENT_POWER_OFF, OMI_USER_EVENT_SRC_SYSTEM);
    k_msleep(200);
    bt_off();
    turnoff_all();
}

static K_WORK_DEFINE(sleep_cmd_work, sleep_cmd_work_handler);

static ssize_t settings_sleep_cmd_write_handler(struct bt_conn *conn,
                                                const struct bt_gatt_attr *attr,
                                                const void *buf,
                                                uint16_t len,
                                                uint16_t offset,
                                                uint8_t flags)
{
    if (len != 1) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    }

    if (((const uint8_t *) buf)[0] == OMI_SLEEP_CMD_MAGIC) {
        LOG_INF("Sleep command received; powering off");
        k_work_submit(&sleep_cmd_work);
    }

    return len;
}
#endif

#ifdef CONFIG_OMI_ENABLE_CAPTURE_LED
static ssize_t settings_capture_state_write_handler(struct bt_conn *conn,
                                                    const struct bt_gatt_attr *attr,
                                                    const void *buf,
                                                    uint16_t len,
                                                    uint16_t offset,
                                                    uint8_t flags)
{
    if (len != 1) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    }

    is_capturing = ((const uint8_t *) buf)[0] != 0;
    return len;
}

static ssize_t settings_capture_state_read_handler(struct bt_conn *conn,
                                                   const struct bt_gatt_attr *attr,
                                                   void *buf,
                                                   uint16_t len,
                                                   uint16_t offset)
{
    uint8_t value = is_capturing ? 1U : 0U;
    return bt_gatt_attr_read(conn, attr, buf, len, offset, &value, sizeof(value));
}
#endif

static struct bt_gatt_attr settings_service_attr[] = {
    BT_GATT_PRIMARY_SERVICE(&settings_service_uuid),
#ifdef CONFIG_OMI_ENABLE_USB
    BT_GATT_CHARACTERISTIC(&settings_charging_status_characteristic_uuid.uuid,
                           BT_GATT_CHRC_READ | BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_READ,
                           settings_charging_status_read_handler,
                           NULL,
                           NULL),
    BT_GATT_CCC(charging_status_ccc_config_changed_handler, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
#endif
#ifdef CONFIG_OMI_ENABLE_BLE_SLEEP_CMD
    BT_GATT_CHARACTERISTIC(&settings_sleep_cmd_characteristic_uuid.uuid,
                           BT_GATT_CHRC_WRITE,
                           BT_GATT_PERM_WRITE,
                           NULL,
                           settings_sleep_cmd_write_handler,
                           NULL),
#endif
#ifdef CONFIG_OMI_ENABLE_CAPTURE_LED
    BT_GATT_CHARACTERISTIC(&settings_capture_state_characteristic_uuid.uuid,
                           BT_GATT_CHRC_READ | BT_GATT_CHRC_WRITE,
                           BT_GATT_PERM_READ | BT_GATT_PERM_WRITE,
                           settings_capture_state_read_handler,
                           settings_capture_state_write_handler,
                           NULL),
#endif
    BT_GATT_CHARACTERISTIC(&settings_user_event_characteristic_uuid.uuid,
                           BT_GATT_CHRC_READ | BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_READ,
                           settings_user_event_read_handler,
                           NULL,
                           NULL),
    BT_GATT_CCC(user_event_ccc_config_changed_handler, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
};

static struct bt_gatt_service settings_service = BT_GATT_SERVICE(settings_service_attr);

static struct bt_gatt_attr *user_event_value_attr(void)
{
    return &settings_service_attr[ARRAY_SIZE(settings_service_attr) - 2U];
}

/* ---- features service ---- */

#define OMI_FEATURE_SPEAKER (1U << 0)
#define OMI_FEATURE_ACCELEROMETER (1U << 1)
#define OMI_FEATURE_BUTTON (1U << 2)
#define OMI_FEATURE_BATTERY (1U << 3)
#define OMI_FEATURE_USB (1U << 4)
#define OMI_FEATURE_HAPTIC (1U << 5)
#define OMI_FEATURE_OFFLINE_STORAGE (1U << 6)
#define OMI_FEATURE_LED_DIMMING (1U << 7)
#define OMI_FEATURE_MIC_GAIN (1U << 8)
#define OMI_FEATURE_CHARGING_STATE (1U << 9)
#define OMI_FEATURE_USER_EVENTS (1U << 10)
#define OMI_FEATURE_IMU_GESTURES (1U << 11)
#define OMI_FEATURE_HW_VAD (1U << 12)
#define OMI_FEATURE_BLE_SLEEP_CMD (1U << 13)
#define OMI_FEATURE_CAPTURE_STATE (1U << 14)
#define OMI_FEATURE_DEVICE_NAME_RW (1U << 15)

static struct bt_uuid_128 features_service_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10020, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));
static struct bt_uuid_128 features_characteristic_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10021, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));

static ssize_t
features_read_handler(struct bt_conn *conn, const struct bt_gatt_attr *attr, void *buf, uint16_t len, uint16_t offset)
{
    uint32_t features = OMI_FEATURE_USER_EVENTS;

#ifdef CONFIG_OMI_ENABLE_SPEAKER
    features |= OMI_FEATURE_SPEAKER;
#endif
#ifdef CONFIG_OMI_ENABLE_ACCELEROMETER
    features |= OMI_FEATURE_ACCELEROMETER;
#endif
#ifdef CONFIG_OMI_ENABLE_BUTTON
    features |= OMI_FEATURE_BUTTON;
#endif
#ifdef CONFIG_OMI_ENABLE_BATTERY
    features |= OMI_FEATURE_BATTERY;
#endif
#ifdef CONFIG_OMI_ENABLE_USB
    features |= OMI_FEATURE_USB | OMI_FEATURE_CHARGING_STATE;
#endif
#ifdef CONFIG_OMI_ENABLE_HAPTIC
    features |= OMI_FEATURE_HAPTIC;
#endif
#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
    features |= OMI_FEATURE_OFFLINE_STORAGE;
#endif
#ifdef CONFIG_OMI_ENABLE_BLE_SLEEP_CMD
    features |= OMI_FEATURE_BLE_SLEEP_CMD;
#endif
#ifdef CONFIG_OMI_ENABLE_CAPTURE_LED
    features |= OMI_FEATURE_CAPTURE_STATE;
#endif

    return bt_gatt_attr_read(conn, attr, buf, len, offset, &features, sizeof(features));
}

static struct bt_gatt_attr features_service_attr[] = {
    BT_GATT_PRIMARY_SERVICE(&features_service_uuid),
    BT_GATT_CHARACTERISTIC(&features_characteristic_uuid.uuid,
                           BT_GATT_CHRC_READ,
                           BT_GATT_PERM_READ,
                           features_read_handler,
                           NULL,
                           NULL),
};

static struct bt_gatt_service features_service = BT_GATT_SERVICE(features_service_attr);

/* ---- time sync service ---- */

static struct bt_uuid_128 time_sync_service_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10030, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));
static struct bt_uuid_128 time_sync_write_characteristic_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10031, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));
static struct bt_uuid_128 time_sync_read_characteristic_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10032, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));

static ssize_t time_sync_write_handler(struct bt_conn *conn,
                                       const struct bt_gatt_attr *attr,
                                       const void *buf,
                                       uint16_t len,
                                       uint16_t offset,
                                       uint8_t flags)
{
    if (len != sizeof(uint32_t)) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    }

    uint32_t epoch_s;
    memcpy(&epoch_s, buf, sizeof(epoch_s));
    omi_rtc_set_utc(epoch_s);
    LOG_INF("Time synchronized: %u", epoch_s);
    return len;
}

static ssize_t
time_sync_read_handler(struct bt_conn *conn, const struct bt_gatt_attr *attr, void *buf, uint16_t len, uint16_t offset)
{
    uint32_t epoch_s = omi_rtc_get_utc();
    return bt_gatt_attr_read(conn, attr, buf, len, offset, &epoch_s, sizeof(epoch_s));
}

static struct bt_gatt_attr time_sync_service_attr[] = {
    BT_GATT_PRIMARY_SERVICE(&time_sync_service_uuid),
    BT_GATT_CHARACTERISTIC(&time_sync_write_characteristic_uuid.uuid,
                           BT_GATT_CHRC_WRITE,
                           BT_GATT_PERM_WRITE,
                           NULL,
                           time_sync_write_handler,
                           NULL),
    BT_GATT_CHARACTERISTIC(&time_sync_read_characteristic_uuid.uuid,
                           BT_GATT_CHRC_READ,
                           BT_GATT_PERM_READ,
                           time_sync_read_handler,
                           NULL,
                           NULL),
};

static struct bt_gatt_service time_sync_service = BT_GATT_SERVICE(time_sync_service_attr);

void omi_ext_register(void)
{
    bt_gatt_service_register(&settings_service);
    bt_gatt_service_register(&features_service);
    bt_gatt_service_register(&time_sync_service);
    LOG_INF("Omi extension services registered");
}
