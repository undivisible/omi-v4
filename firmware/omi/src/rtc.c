#include <zephyr/logging/log.h>
#include <zephyr/kernel.h>

#include "rtc.h"
#include "lib/core/settings.h"
#include "lib/core/sd_card.h"
#include "omi_rust.h"

LOG_MODULE_REGISTER(rtc, CONFIG_LOG_DEFAULT_LEVEL);

static uint64_t pending_epoch_to_persist;
static struct k_work rtc_persist_work;

static void rtc_persist_work_handler(struct k_work *work)
{
    ARG_UNUSED(work);

    uint64_t epoch_s = omi_rust_rtc_take_pending_persist();
    if (epoch_s == 0) {
        epoch_s = pending_epoch_to_persist;
    }

#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
    sd_notify_time_synced((uint32_t)epoch_s);
#endif

    int err = app_settings_save_rtc_epoch(epoch_s);
    if (err) {
        LOG_ERR("Failed to persist rtc_epoch (err %d)", err);
    }
}

#ifdef CONFIG_LOG
// Debug functions to format UTC datetime strings
int rtc_format_now_utc_datetime(char *out, size_t out_len)
{
    uint64_t now_s = get_utc_time();
    if (now_s == 0) {
        if (out && out_len) {
            out[0] = '\0';
        }
        return -ENODATA;
    }
    return omi_rust_rtc_format_utc_datetime(now_s, (uint8_t *)out, out_len);
}
#endif

bool rtc_is_valid(void)
{
    return omi_rust_rtc_is_valid();
}

uint64_t rtc_get_utc_time_ms(void)
{
    return omi_rust_rtc_get_utc_ms();
}

int rtc_set_utc_time(uint64_t utc_epoch_s)
{
    if (utc_epoch_s == 0) {
        return -EINVAL;
    }

    int err = rtc_set_utc_time_ms(utc_epoch_s * 1000ULL);
    if (err) {
        return err;
    }

    pending_epoch_to_persist = utc_epoch_s;
    omi_rust_rtc_set_pending_persist(utc_epoch_s);

    /*
     * Defer persistence and SD rename to system workqueue so BLE GATT callback
     * stack stays small and cannot overflow on filesystem/settings operations.
     */
    k_work_submit(&rtc_persist_work);

    return 0;
}

int rtc_set_utc_time_ms(uint64_t utc_epoch_ms)
{
    return omi_rust_rtc_set_utc_ms(utc_epoch_ms);
}

uint32_t get_utc_time(void)
{
    return omi_rust_rtc_get_utc_s();
}

void init_rtc(void)
{
    static bool initialized;
    if (!initialized) {
        omi_rust_rtc_clock_init();
        k_work_init(&rtc_persist_work, rtc_persist_work_handler);
        initialized = true;
    }

    uint64_t saved_epoch_s = app_settings_get_rtc_epoch();
    LOG_INF("RTC init: persisted rtc_epoch=%llu", saved_epoch_s);
    if (saved_epoch_s == 0) {
        omi_rust_rtc_invalidate();
        LOG_WRN("RTC not synchronized yet (no persisted epoch)");
        return;
    }

    omi_rust_rtc_restore_from_epoch_s(saved_epoch_s);
    LOG_INF("RTC restored from persisted epoch");
}
