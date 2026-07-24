#include "lib/core/feedback.h"

#include <zephyr/kernel.h>

#include "lib/core/led.h"
#include "omi_rust.h"

/**
 * @brief Show error indication with color-coded pattern
 *
 * @param r Red LED state for pattern
 * @param g Green LED state for pattern
 * @param b Blue LED state for pattern
 * @param blinks Number of blinks in the pattern (1-3)
 */
static void show_error(bool r, bool g, bool b, int blinks)
{
    // FIRST: RED blink = "ERROR!"
    set_led_red(true);
    k_msleep(300);
    led_off();
    k_msleep(500); // Longer pause to separate alert from pattern

    // THEN: Colored pattern = "Which component"
    for (int i = 0; i < blinks; i++) {
        set_led_red(r);
        set_led_green(g);
        set_led_blue(b);
        k_msleep(300);
        led_off();
        k_msleep(200);
    }
    k_msleep(1000); // Final pause before returning
}

static void show_error_kind(omi_rust_error_kind_t kind)
{
    omi_rust_error_pattern_t pattern;
    if (!omi_rust_feedback_error_pattern((uint8_t) kind, &pattern)) {
        return;
    }
    show_error(pattern.red, pattern.green, pattern.blue, pattern.blinks);
}

void error_settings(void)
{
    show_error_kind(OMI_RUST_ERROR_SETTINGS);
}

void error_led_driver(void)
{
    show_error_kind(OMI_RUST_ERROR_LED_DRIVER);
}

void error_battery_init(void)
{
    show_error_kind(OMI_RUST_ERROR_BATTERY_INIT);
}

void error_battery_charge(void)
{
    show_error_kind(OMI_RUST_ERROR_BATTERY_CHARGE);
}

void error_button(void)
{
    show_error_kind(OMI_RUST_ERROR_BUTTON);
}

void error_haptic(void)
{
    show_error_kind(OMI_RUST_ERROR_HAPTIC);
}

void error_sd_card(void)
{
    show_error_kind(OMI_RUST_ERROR_SD_CARD);
}

void error_storage(void)
{
    show_error_kind(OMI_RUST_ERROR_STORAGE);
}

void error_transport(void)
{
    show_error_kind(OMI_RUST_ERROR_TRANSPORT);
}

void error_codec(void)
{
    show_error_kind(OMI_RUST_ERROR_CODEC);
}

void error_microphone(void)
{
    show_error_kind(OMI_RUST_ERROR_MICROPHONE);
}
