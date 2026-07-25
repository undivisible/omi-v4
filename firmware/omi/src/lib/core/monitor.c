#include "monitor.h"

#include <zephyr/logging/log.h>

#include "omi_rust.h"

LOG_MODULE_REGISTER(monitor, CONFIG_LOG_DEFAULT_LEVEL);

// Metric counters
enum {
    GATT_NOTIFY_COUNT,
    TOTAL_MIC_BUFFER_BYTES,
    BROADCAST_AUDIO_COUNT,
    BROADCAST_AUDIO_FAILED_COUNT,
    WRITE_TO_TX_QUEUE_COUNT,
    STORAGE_WRITE_COUNT,
};

int monitor_init(void)
{
    LOG_INF("Monitor system initialized");
    monitor_reset();
    return 0;
}

void monitor_inc_gatt_notify(void)
{
    omi_rust_metrics_increment(GATT_NOTIFY_COUNT);
}

void monitor_inc_mic_buffer(void)
{
    omi_rust_metrics_increment(TOTAL_MIC_BUFFER_BYTES);
}

void monitor_inc_broadcast_audio(void)
{
    omi_rust_metrics_increment(BROADCAST_AUDIO_COUNT);
}

void monitor_inc_broadcast_audio_failed(void)
{
    omi_rust_metrics_increment(BROADCAST_AUDIO_FAILED_COUNT);
}

void monitor_inc_tx_queue_write(void)
{
    omi_rust_metrics_increment(WRITE_TO_TX_QUEUE_COUNT);
}

void monitor_inc_storage_write(void)
{
    omi_rust_metrics_increment(STORAGE_WRITE_COUNT);
}

void monitor_log_metrics(void)
{
    LOG_INF("Metrics: Mic buffers: %u, GATT notify: %u, Broadcast: %u, Broadcast failed: %u, TX queue: %u, Storage: %u",
            omi_rust_metrics_read(TOTAL_MIC_BUFFER_BYTES),
            omi_rust_metrics_read(GATT_NOTIFY_COUNT),
            omi_rust_metrics_read(BROADCAST_AUDIO_COUNT),
            omi_rust_metrics_read(BROADCAST_AUDIO_FAILED_COUNT),
            omi_rust_metrics_read(WRITE_TO_TX_QUEUE_COUNT),
            omi_rust_metrics_read(STORAGE_WRITE_COUNT));
}

void monitor_reset(void)
{
    omi_rust_metrics_reset();
    LOG_DBG("All metrics reset");
}
