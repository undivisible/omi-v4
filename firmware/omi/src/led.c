#include "lib/core/led.h"

#include <errno.h>
#include <zephyr/drivers/pwm.h>
#include <zephyr/logging/log.h>

#include "lib/core/settings.h"
#include "lib/core/utils.h"
#include "omi_rust.h"

LOG_MODULE_REGISTER(led, CONFIG_LOG_DEFAULT_LEVEL);

// Define LED PWM specs from device tree
static const struct pwm_dt_spec led_red = PWM_DT_SPEC_GET(DT_NODELABEL(led_red));
static const struct pwm_dt_spec led_green = PWM_DT_SPEC_GET(DT_NODELABEL(led_green));
static const struct pwm_dt_spec led_blue = PWM_DT_SPEC_GET(DT_NODELABEL(led_blue));

int led_start()
{
    ASSERT_TRUE(pwm_is_ready_dt(&led_red));
    ASSERT_TRUE(pwm_is_ready_dt(&led_green));
    ASSERT_TRUE(pwm_is_ready_dt(&led_blue));
    LOG_INF("LEDs (PWM) started");
    return 0;
}

static void set_led_on_off(const struct pwm_dt_spec *led, bool on)
{
    if (!pwm_is_ready_dt(led)) {
        LOG_ERR("LED PWM device not ready");
        return;
    }

    uint32_t pulse_width_ns = 0;
    if (on) {
        uint8_t ratio = app_settings_get_dim_ratio();
        pulse_width_ns = omi_rust_led_pulse_width_ns(led->period, ratio);
    }

    pwm_set_pulse_dt(led, pulse_width_ns);
}

void set_led_red(bool on)
{
    set_led_on_off(&led_red, on);
}

void set_led_green(bool on)
{
    set_led_on_off(&led_green, on);
}

void set_led_blue(bool on)
{
    set_led_on_off(&led_blue, on);
}

void set_led_pwm(led_color_t color, uint8_t level)
{
    const struct pwm_dt_spec *led;

    switch (color) {
    case LED_RED:
        led = &led_red;
        break;
    case LED_GREEN:
        led = &led_green;
        break;
    case LED_BLUE:
        led = &led_blue;
        break;
    default:
        LOG_ERR("Invalid LED color");
        return;
    }

    if (!pwm_is_ready_dt(led)) {
        LOG_ERR("LED PWM device not ready");
        return;
    }

    uint32_t pulse_width_ns = omi_rust_led_pulse_width_ns(led->period, level);
    pwm_set_pulse_dt(led, pulse_width_ns);
}

void led_off(void)
{
    set_led_red(false);
    k_msleep(10);
    set_led_green(false);
    k_msleep(10);
    set_led_blue(false);
}

// Identify runs on its own delayable work rather than inside the main loop:
// that loop ticks once a second, which is far too slow to read as a deliberate
// blink when the owner is holding three identical pendants and looking for the
// one that answered.
#define LED_IDENTIFY_HALF_PERIOD_MS 250
#define LED_IDENTIFY_BLINKS 12

// Six colours, because the LED has exactly three channels: the primaries plus
// their pairwise mixes are everything the hardware can actually show, and the
// app palette (PendantIdentity) is indexed the same way.
static const bool led_identify_channels[][3] = {
    {true, false, false},  // red
    {false, true, false},  // green
    {false, false, true},  // blue
    {true, true, false},   // yellow
    {false, true, true},   // cyan
    {true, false, true},   // magenta
};

static uint8_t identify_color;
static uint8_t identify_remaining;
static bool identify_on;

static void led_identify_work_handler(struct k_work *work);
static K_WORK_DELAYABLE_DEFINE(led_identify_work, led_identify_work_handler);

static void led_identify_work_handler(struct k_work *work)
{
    ARG_UNUSED(work);

    if (identify_remaining == 0) {
        led_off();
        identify_on = false;
        return;
    }

    identify_on = !identify_on;
    if (identify_on) {
        const bool *channels = led_identify_channels[identify_color];
        set_led_red(channels[0]);
        set_led_green(channels[1]);
        set_led_blue(channels[2]);
    } else {
        led_off();
        identify_remaining--;
    }

    k_work_schedule(&led_identify_work, K_MSEC(LED_IDENTIFY_HALF_PERIOD_MS));
}

bool led_identify_active(void)
{
    return identify_remaining > 0;
}

int led_identify(uint8_t color)
{
    if (color >= ARRAY_SIZE(led_identify_channels)) {
        return -EINVAL;
    }

    identify_color = color;
    identify_remaining = LED_IDENTIFY_BLINKS;
    identify_on = false;
    k_work_reschedule(&led_identify_work, K_NO_WAIT);
    return 0;
}
