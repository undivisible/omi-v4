#include "lib/core/haptic.h"

#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include "omi_rust.h"

LOG_MODULE_REGISTER(haptic, CONFIG_LOG_DEFAULT_LEVEL);

#define MAX_HAPTIC_DURATION 5000

static struct k_work_delayable haptic_off_work;

static void haptic_off_work_handler(struct k_work *work)
{
    haptic_off();
    LOG_INF("Haptic turned off by work handler");
}

static void haptic_ccc_cfg_changed(const struct bt_gatt_attr *attr, uint16_t value);
static ssize_t haptic_write_handler(struct bt_conn *conn,
                                    const struct bt_gatt_attr *attr,
                                    const void *buf,
                                    uint16_t len,
                                    uint16_t offset,
                                    uint8_t flags);

static struct bt_uuid_128 haptic_service_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0xCAB1AB95, 0x2EA5, 0x4F4D, 0xBB56, 0x874B72CFC984));
static struct bt_uuid_128 haptic_char_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0xCAB1AB96, 0x2EA5, 0x4F4D, 0xBB56, 0x874B72CFC984));

static struct bt_gatt_attr haptic_attrs[] = {
    BT_GATT_PRIMARY_SERVICE(&haptic_service_uuid),
    BT_GATT_CHARACTERISTIC(&haptic_char_uuid.uuid,
                           BT_GATT_CHRC_WRITE,
                           BT_GATT_PERM_WRITE,
                           NULL,
                           haptic_write_handler,
                           NULL),
};

static struct bt_gatt_service haptic_service = BT_GATT_SERVICE(haptic_attrs);

static ssize_t haptic_write_handler(struct bt_conn *conn,
                                    const struct bt_gatt_attr *attr,
                                    const void *buf,
                                    uint16_t len,
                                    uint16_t offset,
                                    uint8_t flags)
{
    if (len < 1) {
        LOG_WRN("Haptic write: Invalid length %d", len);
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    }

    uint8_t value = ((uint8_t *) buf)[0];
    LOG_INF("Haptic write received: value %d", value);

    uint32_t duration = omi_rust_haptic_duration_from_ble(value);
    if (duration == 0) {
        LOG_WRN("Haptic write: Invalid value %d", value);
        return len;
    }
    play_haptic_milli(duration);

    return len;
}

int haptic_init(void)
{
    int err = omi_rust_haptic_motor_init();
    if (err) {
        LOG_ERR("Haptic motor init failed (err %d)", err);
        return err;
    }

    k_work_init_delayable(&haptic_off_work, haptic_off_work_handler);

    LOG_INF("Haptic system initialized");
    return 0;
}

void play_haptic_milli(uint32_t duration)
{
    k_work_cancel_delayable(&haptic_off_work);

    if (duration == 0) {
        omi_rust_haptic_motor_set(false);
        LOG_INF("Haptic explicitly stopped (duration 0)");
        return;
    }

    if (duration > MAX_HAPTIC_DURATION) {
        LOG_WRN("Requested haptic duration %u exceeds max %d, capping.", duration, MAX_HAPTIC_DURATION);
        duration = omi_rust_haptic_clamp_duration(duration);
    }

    LOG_INF("Playing haptic for %u ms", duration);
    if (omi_rust_haptic_motor_set(true)) {
        LOG_ERR("Failed to enable haptic motor");
        return;
    }
    k_work_schedule(&haptic_off_work, K_MSEC(duration));
}

void register_haptic_service(void)
{
    int err = bt_gatt_service_register(&haptic_service);
    if (err) {
        LOG_ERR("Failed to register Haptic GATT service (err %d)", err);
    } else {
        LOG_INF("Haptic GATT service registered");
    }
}

void haptic_off()
{
    omi_rust_haptic_motor_set(false);
}
