#include <zephyr/logging/log.h>
#include <zephyr/kernel.h>

#include <errno.h>
#include <stdio.h>

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

// Debug functions to format UTC datetime strings
#ifdef CONFIG_LOG
static void civil_from_days(int64_t z_days, int32_t *year, uint8_t *month, uint8_t *day)
{
    /*
     * Howard Hinnant's algorithm: convert days since 1970-01-01 into Y-M-D.
     * Works for a wide range of dates with only integer math.
     */
    int64_t z = z_days + 719468;
    int64_t era = (z >= 0) ? (z / 146097) : ((z - 146096) / 146097);
    uint32_t doe = (uint32_t)(z - era * 146097);
    uint32_t yoe = (doe - doe / 1460U + doe / 36524U - doe / 146096U) / 365U;
    int32_t y = (int32_t)yoe + (int32_t)era * 400;
    uint32_t doy = doe - (365U * yoe + yoe / 4U - yoe / 100U);
    uint32_t mp = (5U * doy + 2U) / 153U;
    uint32_t d = doy - (153U * mp + 2U) / 5U + 1U;
    uint32_t m = mp + ((mp < 10U) ? 3U : (uint32_t)-9);
    y += (m <= 2U);

    *year = y;
    *month = (uint8_t)m;
    *day = (uint8_t)d;
}

static int rtc_format_utc_datetime(int64_t utc_epoch_s, char *out, size_t out_len)
{
    if (out == NULL) {
        return -EINVAL;
    }
    if (out_len < RTC_UTC_DATETIME_STRLEN) {
        out[0] = '\0';
        return -ENOSPC;
    }
    if (utc_epoch_s < 0) {
        out[0] = '\0';
        return -EINVAL;
    }

    int64_t days = utc_epoch_s / 86400;
    int64_t sod = utc_epoch_s % 86400;
    if (sod < 0) {
        sod += 86400;
        days -= 1;
    }

    int32_t year;
    uint8_t month;
    uint8_t day;
    civil_from_days(days, &year, &month, &day);

    uint8_t hour = (uint8_t)(sod / 3600);
    uint8_t minute = (uint8_t)((sod % 3600) / 60);
    uint8_t second = (uint8_t)(sod % 60);

    (void)snprintf(out, out_len, "%04d-%02u-%02u %02u:%02u:%02u",
                   year, month, day, hour, minute, second);
    return 0;
}

int rtc_format_now_utc_datetime(char *out, size_t out_len)
{
    uint64_t now_s = get_utc_time();
    if (now_s == 0) {
        if (out && out_len) {
            out[0] = '\0';
        }
        return -ENODATA;
    }
    return rtc_format_utc_datetime((int64_t)now_s, out, out_len);
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
