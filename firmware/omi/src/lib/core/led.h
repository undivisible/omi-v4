#ifndef LED_H
#define LED_H

#include <zephyr/drivers/gpio.h>
#include <zephyr/kernel.h>

// LED color enum for PWM control
typedef enum {
    LED_RED,
    LED_GREEN,
    LED_BLUE
} led_color_t;

/**
 * @brief Initialize the LEDs
 *
 * Initializes the LEDs
 *
 * @return 0 if successful, negative errno code if error
 */
int led_start();
void set_led_red(bool on);
void set_led_green(bool on);
void set_led_blue(bool on);
void set_led_pwm(led_color_t color, uint8_t level);
void led_off(void);

/**
 * @brief Blink one identify colour so this pendant can be told from another
 *
 * The colour index is one of six the three-channel LED can reproduce (the RGB
 * primaries plus their pairwise mixes); anything else is rejected rather than
 * silently shown as some other colour, because the app row promises the owner
 * a specific one.
 *
 * @return 0 if successful, -EINVAL if the colour index is out of range
 */
int led_identify(uint8_t color);

/**
 * @brief Whether an identify blink is currently owning the LED
 *
 * The status logic must not repaint over it, or the blink the owner is
 * watching for would be erased on the next status tick.
 */
bool led_identify_active(void);

#endif
