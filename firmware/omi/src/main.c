#include <app_version.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/pm/device_runtime.h>

#include "lib/core/button.h"
#include "lib/core/codec.h"
#include "lib/core/config.h"
#include "lib/core/feedback.h"
#include "lib/core/haptic.h"
#include "lib/core/led.h"
#include "lib/core/lib/battery/battery.h"
#include "lib/core/mic.h"
#include "lib/core/settings.h"
#include "lib/core/transport.h"
#include "lib/core/user_event.h"
#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
#include "lib/core/storage.h"
#endif
#include <hal/nrf_reset.h>

#include "omi_rust.h"
#ifdef CONFIG_OMI_ENABLE_WIFI
#include "wifi.h"
#endif

#include "imu.h"
#include "lib/core/sd_card.h"
#include "rtc.h"
#include "spi_flash.h"
#include "wdog_facade.h"

LOG_MODULE_REGISTER(main, CONFIG_LOG_DEFAULT_LEVEL);

/* The zephyr crate's panic handler calls this instead of k_panic() directly.
 * rust_cargo_application() would have provided it via the module main.c; we
 * keep omi/src/main.c and supply the same symbol here.
 */
void rust_panic_wrap(void)
{
    k_panic();
}

#ifdef CONFIG_OMI_ENABLE_BATTERY
#define BATTERY_FULL_THRESHOLD_PERCENT 98 // 98%
extern uint8_t battery_percentage;
#endif
bool is_connected = false;
bool is_charging = false;
bool is_off = false;
bool blink_toggle = false;
#ifdef CONFIG_OMI_ENABLE_CAPTURE_LED
bool is_capturing = false;
#endif

static void print_reset_reason(void)
{
    uint32_t reas;

    reas = nrf_reset_resetreas_get(NRF_RESET);
    nrf_reset_resetreas_clear(NRF_RESET, reas);

    if (reas & NRF_RESET_RESETREAS_DOG0_MASK) {
        printk("Reset by WATCHDOG\n");
    } else if (reas & NRF_RESET_RESETREAS_NFC_MASK) {
        printk("Wake up by NFC field detect\n");
    } else if (reas & NRF_RESET_RESETREAS_RESETPIN_MASK) {
        printk("Reset by pin-reset\n");
    } else if (reas & NRF_RESET_RESETREAS_SREQ_MASK) {
        printk("Reset by soft-reset\n");
    } else if (reas & NRF_RESET_RESETREAS_LOCKUP_MASK) {
        printk("Reset by CPU LOCKUP\n");
    } else if (reas) {
        printk("Reset by a different source (0x%08X)\n", reas);
    } else {
        printk("Power-on-reset\n");
    }
}

static void codec_handler(uint8_t *data, size_t len)
{
#ifdef CONFIG_OMI_ENABLE_MONITOR
    omi_rust_metrics_increment(OMI_RUST_METRIC_BROADCAST_AUDIO);
#endif
    int err = broadcast_audio_packets(data, len);
    if (err) {
#ifdef CONFIG_OMI_ENABLE_MONITOR
        omi_rust_metrics_increment(OMI_RUST_METRIC_BROADCAST_AUDIO_FAILED);
#endif
    }
}

static void mic_handler(int16_t *buffer)
{
#ifdef CONFIG_OMI_ENABLE_MONITOR
    // Track total bytes processed (each sample is 2 bytes)
    omi_rust_metrics_increment(OMI_RUST_METRIC_MIC_BUFFER);
#endif

    // Hardware AAD (T5838) is handled inside mic.c; the mic callback only
    // forwards audio to the codec here.
    int err = codec_receive_pcm(buffer, MIC_BUFFER_SAMPLES);
    if (err) {
        LOG_ERR("Failed to process PCM data: %d", err);
    }
}

static void boot_led_sequence(void)
{
    // Quick blue pulse = "I'm alive, booting..."
    set_led_blue(true);
    k_msleep(300);
    led_off();
}

static void boot_ready_sequence(void)
{
    const int steps = 50;
    const int delay_ms = 10;

    // Smooth green fade in/out 2 times = "Ready!"
    for (int cycle = 0; cycle < 2; cycle++) {
        // Fade in: ease-in-out
        for (int i = 0; i <= steps; i++) {
            float t = (float) i / steps;
            // Ease-in-out quadratic
            float eased = t < 0.5f ? 2.0f * t * t : 1.0f - 2.0f * (1.0f - t) * (1.0f - t);
            uint8_t level = (uint8_t) (eased * 50.0f);
            set_led_pwm(LED_GREEN, level);
            k_msleep(delay_ms);
        }

        // Fade out: ease-in-out
        for (int i = 0; i <= steps; i++) {
            float t = (float) i / steps;
            float eased = t < 0.5f ? 2.0f * t * t : 1.0f - 2.0f * (1.0f - t) * (1.0f - t);
            uint8_t level = (uint8_t) ((1.0f - eased) * 70.0f);
            set_led_pwm(LED_GREEN, level);
            k_msleep(delay_ms);
        }
    }
    k_msleep(10);
    led_off();
    k_msleep(10);
}

void set_led_state()
{
    // If device is off, turn off all LEDs immediately
    if (is_off) {
        led_off();
        return;
    }

    // An identify blink owns the LED while it runs; repainting status over it
    // would erase the very blink the owner is watching for.
    if (led_identify_active()) {
        return;
    }

#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
    // If RTC not synced, blink red to warn user to connect phone app
    if (!rtc_is_valid()) {
        set_led_green(is_charging);
        set_led_blue(!blink_toggle && is_connected);
        set_led_red(blink_toggle);
        blink_toggle = !blink_toggle;
        return;
    }
#endif

    bool green = false;
    bool blue = false;
    bool red = false;

    if (is_charging) {
#ifdef CONFIG_OMI_ENABLE_BATTERY
        // Solid green if battery is full (>= BATTERY_FULL_THRESHOLD_PERCENT)
        if (battery_percentage >= BATTERY_FULL_THRESHOLD_PERCENT) {
            green = true;
        } else
#endif
        {
            green = blink_toggle;
            blue = !blink_toggle && is_connected;
            red = !blink_toggle && !is_connected;
            blink_toggle = !blink_toggle;
        }
    } else {
#ifdef CONFIG_OMI_ENABLE_CAPTURE_LED
        // Blue while a central is actively capturing (audio subscribed), red otherwise
        blue = is_connected && is_capturing && !mic_in_aad_sleep();
        red = !blue;
#else
        blue = is_connected;
        red = !is_connected;
#endif
#if defined(CONFIG_OMI_ENABLE_BATTERY) && defined(CONFIG_OMI_ENABLE_BATTERY_LOW_LED)
        if (battery_percentage > 0 && battery_percentage <= CONFIG_OMI_BATTERY_LOW_THRESHOLD) {
            // Low battery warning: blink red regardless of connection state
            blue = false;
            red = blink_toggle;
            blink_toggle = !blink_toggle;
        }
#endif
    }

    set_led_green(green);
    set_led_blue(blue);
    set_led_red(red);
}

#ifdef CONFIG_OMI_ENABLE_IDLE_SLEEP
#define IDLE_SLEEP_TIMEOUT_SEC (CONFIG_OMI_IDLE_SLEEP_TIMEOUT_MIN * 60)
static uint32_t idle_seconds = 0;

void omi_note_user_activity(void)
{
    idle_seconds = 0;
}

static void update_idle_sleep(void)
{
    // Streaming audio to a subscribed central, or charging, holds the device awake.
    bool active = is_charging || (is_connected && transport_is_audio_subscribed());

    if (active) {
        idle_seconds = 0;
        return;
    }

    idle_seconds++;
    if (idle_seconds >= IDLE_SLEEP_TIMEOUT_SEC) {
        LOG_INF("Idle for %u s; entering system off", idle_seconds);
        turnoff_all();
    }
}
#else
void omi_note_user_activity(void) {}
#endif

static int suspend_unused_modules(void)
{
    int err = flash_off();
    if (err) {
        LOG_ERR("Can not suspend the spi flash module: %d", err);
    }

    return 0;
}

int main(void)
{
    int ret;
    printk("Starting omi %s ...\n", APP_VERSION_STRING);

    // print reset reason at startup
    print_reset_reason();

#ifdef CONFIG_OMI_RUST_SELFTEST_AT_BOOT
    {
        int rust_failures = omi_rust_selftest();
        if (rust_failures) {
            LOG_ERR("Rust framing self-test failed (%d cases)", rust_failures);
        } else {
            LOG_INF("Rust framing self-test passed");
        }
    }
#endif

    // Initialize watchdog first to catch any early freezes
    ret = watchdog_init();
    if (ret) {
        LOG_WRN("Watchdog init failed (err %d), continuing without watchdog", ret);
    }

    // Initialize Haptic driver first; this is building up for future of omi turn on sequence - long press to turn on
    // instead of short press
#ifdef CONFIG_OMI_ENABLE_HAPTIC
    ret = haptic_init();
    if (ret) {
        LOG_ERR("Failed to initialize Haptic driver (err %d)", ret);
        error_haptic();
        // Non-critical, continue boot
    } else {
        LOG_INF("Haptic driver initialized");
        play_haptic_milli(100);
    }
#endif

    // Initialize LEDs
    LOG_INF("Initializing LEDs...\n");

    ret = led_start();
    if (ret) {
        LOG_ERR("Failed to initialize LEDs (err %d)", ret);
        error_led_driver();
        return ret;
    }

    // Suspend unused modules
    LOG_PRINTK("\n");
    LOG_INF("Suspending unused modules...\n");
    ret = suspend_unused_modules();
    if (ret) {
        LOG_ERR("Failed to suspend unused modules (err %d)", ret);
        ret = 0;
    }

    // Initialize settings
    LOG_INF("Initializing settings...\n");
    int setting_ret = app_settings_init();
    if (setting_ret) {
        LOG_ERR("Failed to initialize settings (err %d)", setting_ret);
    }

    // Initialize RTC from saved epoch
    init_rtc();
    if (!rtc_is_valid()) {
        LOG_WRN("UTC time not synchronized yet");
    }

    (void) lsm6dsl_time_boot_adjust_rtc();

#ifdef CONFIG_OMI_ENABLE_IMU_GESTURES
    ret = imu_gesture_init();
    if (ret) {
        LOG_WRN("IMU gesture init failed (err %d); button wake only", ret);
    }
#endif

#ifdef CONFIG_OMI_ENABLE_MONITOR
    // Initialize monitoring system
    LOG_INF("Initializing monitoring system...\n");
    omi_rust_metrics_reset();
#endif

    if (setting_ret) {
        error_settings();
        app_settings_save_dim_ratio(30);
    }

    // Initialize battery
#ifdef CONFIG_OMI_ENABLE_BATTERY
    ret = battery_init();
    if (ret) {
        LOG_ERR("Battery init failed (err %d)", ret);
        error_battery_init();
        return ret;
    }

    ret = battery_charge_start();
    if (ret) {
        LOG_ERR("Battery failed to start (err %d)", ret);
        error_battery_charge();
        return ret;
    }
    LOG_INF("Battery initialized");
#endif

    // Initialize button
#ifdef CONFIG_OMI_ENABLE_BUTTON
    ret = button_init();
    if (ret) {
        LOG_ERR("Failed to initialize Button (err %d)", ret);
        error_button();
        return ret;
    }
    LOG_INF("Button initialized");
    activate_button_work();
#endif

    // SD Card
    ret = app_sd_init();
    if (ret) {
        LOG_ERR("Failed to initialize SD Card (err %d)", ret);
        error_sd_card();
        return ret;
    }

#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
    // Initialize storage service for offline audio
    ret = storage_init();
    if (ret) {
        LOG_ERR("Failed to initialize storage service (err %d)", ret);
        error_storage();
        // Non-critical, continue boot
    } else {
        LOG_INF("Storage service initialized");
    }
#endif

#ifdef CONFIG_OMI_ENABLE_WIFI
    ret = wifi_init();
    if (ret) {
        LOG_WRN("WiFi init failed (err %d); SoftAP sync unavailable", ret);
    } else {
        LOG_INF("WiFi SoftAP sync initialized (hw probe runs async)");
    }
#endif

    // Indicate transport initialization
    LOG_PRINTK("\n");
    LOG_INF("Initializing transport...\n");

    // Start transport
    int transportErr;
    transportErr = transport_start();
    if (transportErr) {
        LOG_ERR("Failed to start transport (err %d)", transportErr);
        error_transport();
        return transportErr;
    }

    // Initialize codec
    LOG_INF("Initializing codec...\n");

    // Set codec callback
    set_codec_callback(codec_handler);
    ret = codec_start();
    if (ret) {
        LOG_ERR("Failed to start codec: %d", ret);
        error_codec();
        return ret;
    }

    // Initialize microphone
    LOG_INF("Initializing microphone...\n");
    set_mic_callback(mic_handler);
    ret = mic_start();
    if (ret) {
        LOG_ERR("Failed to start microphone: %d", ret);
        error_microphone();
        return ret;
    }
    // Hardware AAD (T5838) is started inside mic_start().

    LOG_INF("Device initialized successfully\n");

    while (1) {
        watchdog_feed();
#ifdef CONFIG_OMI_ENABLE_MONITOR
        LOG_INF("Metrics: Mic buffers: %u, GATT notify: %u, Broadcast: %u, Broadcast failed: %u, TX queue: %u, Storage: %u",
                omi_rust_metrics_read(OMI_RUST_METRIC_MIC_BUFFER),
                omi_rust_metrics_read(OMI_RUST_METRIC_GATT_NOTIFY),
                omi_rust_metrics_read(OMI_RUST_METRIC_BROADCAST_AUDIO),
                omi_rust_metrics_read(OMI_RUST_METRIC_BROADCAST_AUDIO_FAILED),
                omi_rust_metrics_read(OMI_RUST_METRIC_TX_QUEUE_WRITE),
                omi_rust_metrics_read(OMI_RUST_METRIC_STORAGE_WRITE));
#endif

        set_led_state();
#ifdef CONFIG_OMI_ENABLE_IDLE_SLEEP
        update_idle_sleep();
#endif
#if defined(CONFIG_OMI_ENABLE_WIFI_HOME_STA)
        if (is_charging) {
            (void)wifi_home_try_autosync();
        }
#endif
        k_msleep(1000);
    }

    printk("Exiting omi...");
    return 0;
}
