#include "button.h"

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/l2cap.h>
#include <zephyr/bluetooth/services/bas.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/input/input.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/pm/device_runtime.h>
#include <zephyr/sys/atomic.h>
#include <zephyr/sys/poweroff.h>

#include "haptic.h"
#include "imu.h"
#include "led.h"
#include "mic.h"
#include "speaker.h"
#include "transport.h"
#include "user_event.h"
#include "wdog_facade.h"
#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
#include "sd_card.h"
#endif
#include "omi_rust.h"
#ifdef CONFIG_OMI_ENABLE_WIFI
#include "wifi.h"
#endif

LOG_MODULE_REGISTER(button, CONFIG_LOG_DEFAULT_LEVEL);

extern bool is_off;

static void button_ccc_config_changed_handler(const struct bt_gatt_attr *attr, uint16_t value)
{
    if (value == BT_GATT_CCC_NOTIFY) {
        LOG_INF("Client subscribed for notifications");
    } else if (value == 0) {
        LOG_INF("Client unsubscribed from notifications");
    } else {
        LOG_ERR("Invalid CCC value: %u", value);
    }
}
static const struct device *const buttons = DEVICE_DT_GET(DT_ALIAS(buttons));
static const struct gpio_dt_spec usr_btn = GPIO_DT_SPEC_GET_OR(DT_NODELABEL(usr_btn), gpios, {0});

static bool was_pressed = false;

// Using GPIO callback due to the lower priority of the input subsystem vs. storage.c's thread that prevents the
// callback from working properly.
#define BUTTON_CHECK_INTERVAL 40 // 0.04 seconds, 25 Hz

void check_button_level(struct k_work *work_item);

K_WORK_DELAYABLE_DEFINE(button_work, check_button_level);

#define DEFAULT_STATE 0
#define SINGLE_TAP 1
#define DOUBLE_TAP 2
#define LONG_TAP 3
#define BUTTON_PRESS 4
#define BUTTON_RELEASE 5

// 4 is button down, 5 is button up
static FSM_STATE_T current_button_state = IDLE;
static uint32_t inc_count_1 = 0;
static uint32_t inc_count_0 = 0;

const static int threshold = 10;

static void reset_count()
{
    inc_count_0 = 0;
    inc_count_1 = 0;
}
static inline void notify_press()
{
    LOG_INF("Button pressed");
    button_notify(BUTTON_PRESS);
}

static inline void notify_unpress()
{
    LOG_INF("Button released");
    button_notify(BUTTON_RELEASE);
}

static inline void notify_tap()
{
    LOG_INF("Button single tap");
    button_notify(SINGLE_TAP);
}

static inline void notify_double_tap()
{
    LOG_INF("Button double tap");
    button_notify(DOUBLE_TAP); // button press
}

static inline void notify_long_tap()
{
    LOG_INF("Button long tap");
    button_notify(LONG_TAP); // button press
}

#define BUTTON_PRESSED 1
#define BUTTON_RELEASED 0

#define TAP_THRESHOLD 300     // 300 ms for single tap
#define DOUBLE_TAP_WINDOW 600 // 600 ms maximum for double-tap
#define LONG_PRESS_TIME 3000  // 3000 ms for long press (power off)

typedef enum {
    BUTTON_EVENT_NONE,
    BUTTON_EVENT_SINGLE_TAP,
    BUTTON_EVENT_DOUBLE_TAP,
    BUTTON_EVENT_LONG_PRESS,
    BUTTON_EVENT_RELEASE
} ButtonEvent;

void check_button_level(struct k_work *work_item)
{
    ARG_UNUSED(work_item);

    uint8_t rust_event = omi_rust_button_step(was_pressed);
    ButtonEvent event = (ButtonEvent) rust_event;

    if (event == BUTTON_EVENT_SINGLE_TAP) {
        LOG_INF("single tap detected\n");
        notify_tap();
#ifdef CONFIG_OMI_ENABLE_USER_EVENTS
        omi_note_user_activity();
        omi_user_event_emit(OMI_USER_EVENT_BOOKMARK, OMI_USER_EVENT_SRC_BUTTON);
#endif
    }

    if (event == BUTTON_EVENT_DOUBLE_TAP) {
        LOG_INF("double tap detected\n");
        notify_double_tap();
#ifdef CONFIG_OMI_ENABLE_USER_EVENTS
        omi_note_user_activity();
        omi_user_event_emit(OMI_USER_EVENT_ASSISTANT, OMI_USER_EVENT_SRC_BUTTON);
#endif
    }

    if (event == BUTTON_EVENT_LONG_PRESS) {
        LOG_INF("long press detected\n");
        turnoff_all();
    }

    if (event == BUTTON_EVENT_RELEASE) {
        LOG_PRINTK("release detected\n");
        notify_unpress();
        current_button_state = GRACE;
    }

    k_work_reschedule(&button_work, K_MSEC(BUTTON_CHECK_INTERVAL));
}

static struct gpio_callback button_cb_data;

static void button_gpio_callback(const struct device *dev, struct gpio_callback *cb, uint32_t pins)
{
    was_pressed = (gpio_pin_get_dt(&usr_btn) == 1);
    LOG_INF("Button %s (GPIO callback)", was_pressed ? "pressed" : "released");
}

int button_regist_callback()
{
    int ret;

    // Configure GPIO as input with pull-up
    ret = gpio_pin_configure_dt(&usr_btn, GPIO_INPUT);
    if (ret < 0) {
        LOG_ERR("Failed to configure button GPIO (%d)", ret);
        return ret;
    }

    // Setup interrupt on both edges
    ret = gpio_pin_interrupt_configure_dt(&usr_btn, GPIO_INT_EDGE_BOTH);
    if (ret < 0) {
        LOG_ERR("Failed to configure button interrupt (%d)", ret);
        return ret;
    }

    // Register callback
    gpio_init_callback(&button_cb_data, button_gpio_callback, BIT(usr_btn.pin));
    gpio_add_callback(usr_btn.port, &button_cb_data);

    LOG_INF("Button initialized with GPIO interrupt");

    return 0;
}

int button_init()
{
    int ret;

    // Initialize the buttons device from evt
    if (!device_is_ready(buttons)) {
        LOG_ERR("Buttons device not ready");
        return -ENODEV;
    }

    // Enable runtime power management for the buttons device
    ret = pm_device_runtime_get(buttons);
    if (ret < 0) {
        LOG_ERR("Failed to enable buttons device (%d)", ret);
        return ret;
    }

    // Regist callback
    ret = button_regist_callback();
    if (ret < 0) {
        LOG_ERR("Failed to register buttons callback (%d)", ret);
        return ret;
    }

    return 0;
}

void activate_button_work()
{
    k_work_schedule(&button_work, K_MSEC(BUTTON_CHECK_INTERVAL));
}

FSM_STATE_T get_current_button_state()
{
    return current_button_state;
}

void turnoff_all()
{
    int rc;
    static atomic_t turnoff_in_progress = ATOMIC_INIT(0);

    if (!atomic_cas(&turnoff_in_progress, 0, 1)) {
        LOG_WRN("turnoff_all() already in progress; ignoring re-entry");
        return;
    }

#ifdef CONFIG_OMI_ENABLE_USER_EVENTS
    omi_user_event_emit(OMI_USER_EVENT_POWER_OFF, OMI_USER_EVENT_SRC_SYSTEM);
#endif

    // Immediate feedback: LED off and haptic
    led_off();
    // Set is_off immediately so set_led_state() keeps LEDs off
    is_off = true;

#ifdef CONFIG_OMI_ENABLE_HAPTIC
    play_haptic_milli(100);
    k_msleep(300);
    haptic_off();
#endif

    // Delays for stability
    k_msleep(1000);

#ifdef CONFIG_OMI_ENABLE_WIFI
    wifi_turn_off();
#endif

    // // Enter the low power mode
    transport_off();
    k_msleep(300);

    // Always turn off microphone
    mic_off();
    k_msleep(100);

    // Turn off speaker if enabled
#ifdef CONFIG_OMI_ENABLE_SPEAKER
    speaker_off();
    k_msleep(100);
#endif

    // Turn off accelerometer if enabled
#ifdef CONFIG_OMI_ENABLE_ACCELEROMETER
    accel_off();
    k_msleep(100);
#endif

    if (is_sd_on()) {
        app_sd_off();
    }
    k_msleep(300);

    // Put the buttons device to sleep if button is enabled
#ifdef CONFIG_OMI_ENABLE_BUTTON
    pm_device_runtime_put(buttons);
    k_msleep(100);
#endif

    // Disable USB if enabled
#ifdef CONFIG_OMI_ENABLE_USB
    NRF_USBD->INTENCLR = 0xFFFFFFFF;
#endif

    // Log system power off
    LOG_INF("System powering off");

    // Configure usr_btn as input with interrupt to allow wake-up
    rc = gpio_pin_configure_dt(&usr_btn, GPIO_INPUT);
    if (rc < 0) {
        LOG_ERR("Could not configure usr_btn GPIO (%d)", rc);
    }

    rc = gpio_pin_interrupt_configure_dt(&usr_btn, GPIO_INT_LEVEL_LOW);
    if (rc < 0) {
        LOG_ERR("Could not configure usr_btn GPIO interrupt (%d)", rc);
    }
    rc = watchdog_deinit();
    if (rc < 0) {
        LOG_ERR("Failed to deinitialize watchdog (%d)", rc);
    }

    /* Persist an IMU timestamp base so we can estimate time across system_off. */
    lsm6dsl_time_prepare_for_system_off();
    k_msleep(1000);
    LOG_INF("Entering system off; press usr_btn to restart");
#ifdef CONFIG_OMI_ENABLE_IMU_GESTURES
    imu_gesture_arm_system_off();
#endif

    // Power off the system using sys_poweroff
    sys_poweroff();
}

void force_button_state(FSM_STATE_T state)
{
    current_button_state = state;
}
