#include "mic.h"

#include <haly/nrfy_gpio.h>
#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include "config.h"
#include "led.h"
#include "nrfx_clock.h"
#include "nrfx_pdm.h"
#include "utils.h"

LOG_MODULE_REGISTER(mic, CONFIG_LOG_DEFAULT_LEVEL);

//
// Port of this code: https://github.com/Seeed-Studio/Seeed_Arduino_Mic/blob/master/src/hardware/nrf52840_adc.cpp
//

static int16_t _buffer_0[MIC_BUFFER_SAMPLES];
static int16_t _buffer_1[MIC_BUFFER_SAMPLES];
static volatile uint8_t _next_buffer_index = 0;
static volatile mix_handler _callback = NULL;

static nrfx_pdm_t _pdm = NRFX_PDM_INSTANCE(NRF_PDM_BASE);

ISR_DIRECT_DECLARE(pdm_isr)
{
    nrfx_pdm_irq_handler(&_pdm);
    return 1;
}

static void pdm_irq_handler(nrfx_pdm_evt_t const *event)
{
    // Ignore error (how to handle?)
    if (event->error) {
        LOG_ERR("PDM error: %d", event->error);
        return;
    }

    // Assign buffer
    if (event->buffer_requested) {
        LOG_DBG("Audio buffer requested");
        if (_next_buffer_index == 0) {
            nrfx_pdm_buffer_set(&_pdm, _buffer_0, MIC_BUFFER_SAMPLES);
            _next_buffer_index = 1;
        } else {
            nrfx_pdm_buffer_set(&_pdm, _buffer_1, MIC_BUFFER_SAMPLES);
            _next_buffer_index = 0;
        }
    }

    // Release buffer
    if (event->buffer_released) {
        LOG_DBG("Audio buffer requested");
        if (_callback) {
            _callback(event->buffer_released);
        }
    }
}

int mic_start()
{

    // Start the high frequency clock
    nrf_clock_hfclk_t hfclk_src = NRF_CLOCK_HFCLK_LOW_ACCURACY;
    if (!nrf_clock_is_running(NRF_CLOCK, NRF_CLOCK_DOMAIN_HFCLK, &hfclk_src) ||
        hfclk_src != NRF_CLOCK_HFCLK_HIGH_ACCURACY) {
        nrf_clock_task_trigger(NRF_CLOCK, NRF_CLOCK_TASK_HFCLKSTART);
    }

    // Configure PDM
    nrfx_pdm_config_t pdm_config = NRFX_PDM_DEFAULT_CONFIG(PDM_CLK_PIN, PDM_DIN_PIN);
    pdm_config.gain_l = MIC_GAIN;
    pdm_config.gain_r = MIC_GAIN;
    pdm_config.interrupt_priority = MIC_IRC_PRIORITY;
    pdm_config.prescalers.clock_freq = NRF_PDM_FREQ_1280K;
    pdm_config.mode = NRF_PDM_MODE_MONO;
    pdm_config.edge = NRF_PDM_EDGE_LEFTFALLING;
    pdm_config.prescalers.ratio = NRF_PDM_RATIO_80X;
    IRQ_DIRECT_CONNECT(PDM_IRQn, 5, pdm_isr, 0); // IMPORTANT!
    if (nrfx_pdm_init(&_pdm, &pdm_config, pdm_irq_handler) != 0) {
        LOG_ERR("Audio unable to initialize PDM");
        return -1;
    }

    // Power on Mic
    nrfy_gpio_cfg_output(PDM_PWR_PIN);
    nrfy_gpio_pin_set(PDM_PWR_PIN);

    // Start PDM
    if (nrfx_pdm_start(&_pdm) != 0) {
        LOG_ERR("Audio unable to start PDM");
        return -1;
    }

    LOG_INF("Audio microphone started");
    return 0;
}

void set_mic_callback(mix_handler callback)
{
    _callback = callback;
}

void mic_off()
{
    nrfy_gpio_pin_clear(PDM_PWR_PIN);
}

void mic_on()
{
    nrfy_gpio_pin_set(PDM_PWR_PIN);
}
