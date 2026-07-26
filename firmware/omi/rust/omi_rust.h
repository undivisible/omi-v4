#ifndef OMI_RUST_H
#define OMI_RUST_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int omi_rust_selftest(void);
void omi_rust_ring_header(uint16_t len, uint8_t *out);
uint16_t omi_rust_ring_header_decode(const uint8_t *bytes);
void omi_rust_packet_header(uint16_t id, uint8_t index, uint8_t *out);

uint8_t omi_rust_battery_raw_percentage(uint16_t battery_millivolt, bool is_charging);
uint8_t omi_rust_battery_ema_step(uint32_t current_ema, uint8_t new_value, bool is_charging);
int32_t omi_rust_battery_median_i16(int16_t *samples, size_t n);
int32_t omi_rust_battery_apply_charge_skew(int32_t adc_pin_mv, bool is_charging);
uint16_t omi_rust_battery_divider_mv(int32_t adc_pin_mv);
bool omi_rust_battery_consume_first_measurement(void);
uint8_t omi_rust_battery_percentage_step(uint8_t raw_percentage, bool is_charging);

int omi_rust_gpio_bat_read_enable_path(void);
int omi_rust_gpio_bat_read_restore_input(void);
int omi_rust_gpio_sd_en_set(bool on);
int omi_rust_gpio_rfsw_on(void);
int omi_rust_gpio_rfsw_off(void);
int omi_rust_gpio_pdm_en_init(void);
int omi_rust_gpio_pdm_en_set(bool on);

uint64_t omi_rust_sd_ring_used_packets(uint64_t write_seq, uint64_t read_seq,
                                       bool current_batch_loaded, uint32_t current_batch_packets,
                                       uint64_t current_batch_base_seq);
uint64_t omi_rust_sd_ring_used_bytes(uint64_t write_seq, uint64_t read_seq,
                                     bool current_batch_loaded, uint32_t current_batch_packets,
                                     uint64_t current_batch_base_seq);
uint32_t omi_rust_sd_batch_sector(uint64_t base_seq, uint32_t data_batch_count);
bool omi_rust_sd_meta_valid(uint32_t magic, uint16_t version, uint64_t write_seq, uint64_t read_seq,
                            uint32_t capacity_packets);
bool omi_rust_sd_batch_header_valid(uint32_t magic, uint16_t version, uint16_t packet_count,
                                    uint64_t start_seq);
typedef struct {
    uint64_t read_seq;
    uint64_t write_seq;
    uint64_t dropped_packets;
} omi_rust_sd_flush_state_t;
void omi_rust_sd_apply_flush(omi_rust_sd_flush_state_t *state, uint64_t current_batch_base_seq,
                             uint32_t current_batch_packets, uint32_t capacity_packets);
size_t omi_rust_sd_format_timestamp_name(uint32_t timestamp, uint8_t *out, size_t out_len);

typedef enum {
    OMI_RUST_GESTURE_NONE = 0,
    OMI_RUST_GESTURE_MOTION = 1,
    OMI_RUST_GESTURE_DOUBLE_TAP = 2,
} omi_rust_gesture_t;

uint8_t omi_rust_imu_classify(uint8_t wake_src, uint8_t tap_src, bool double_tap_enabled);

typedef struct {
    uint8_t ctrl1_xl_odr;
    uint8_t tap_cfg;
    uint8_t wake_ths;
    uint8_t int_dur2;
    uint8_t md1_cfg;
} omi_rust_imu_registers_t;

void omi_rust_imu_program_registers(bool double_tap, uint8_t wake_threshold, uint8_t tap_duration,
                                    uint8_t tap_quiet, uint8_t tap_shock,
                                    omi_rust_imu_registers_t *out);
uint8_t omi_rust_imu_merge_wake_up_dur(uint8_t existing, uint8_t wake_duration);

typedef enum {
    OMI_RUST_BUTTON_EVENT_NONE = 0,
    OMI_RUST_BUTTON_EVENT_SINGLE_TAP = 1,
    OMI_RUST_BUTTON_EVENT_DOUBLE_TAP = 2,
    OMI_RUST_BUTTON_EVENT_LONG_PRESS = 3,
    OMI_RUST_BUTTON_EVENT_RELEASE = 4,
} omi_rust_button_event_t;

uint8_t omi_rust_button_step(bool pressed);
void omi_rust_button_reset(void);

uint32_t omi_rust_haptic_duration_from_ble(uint8_t value);
uint32_t omi_rust_haptic_clamp_duration(uint32_t duration);
int omi_rust_haptic_motor_init(void);
int omi_rust_haptic_motor_set(bool on);

uint32_t omi_rust_led_pulse_width_ns(uint32_t period_ns, uint8_t level);

typedef enum {
    OMI_RUST_METRIC_GATT_NOTIFY = 0,
    OMI_RUST_METRIC_MIC_BUFFER = 1,
    OMI_RUST_METRIC_BROADCAST_AUDIO = 2,
    OMI_RUST_METRIC_BROADCAST_AUDIO_FAILED = 3,
    OMI_RUST_METRIC_TX_QUEUE_WRITE = 4,
    OMI_RUST_METRIC_STORAGE_WRITE = 5,
} omi_rust_metric_t;

void omi_rust_metrics_reset(void);
void omi_rust_metrics_increment(uint8_t metric);
uint32_t omi_rust_metrics_read(uint8_t metric);

typedef enum {
    OMI_RUST_ERROR_SETTINGS = 0,
    OMI_RUST_ERROR_LED_DRIVER = 1,
    OMI_RUST_ERROR_BATTERY_INIT = 2,
    OMI_RUST_ERROR_BATTERY_CHARGE = 3,
    OMI_RUST_ERROR_BUTTON = 4,
    OMI_RUST_ERROR_HAPTIC = 5,
    OMI_RUST_ERROR_SD_CARD = 6,
    OMI_RUST_ERROR_STORAGE = 7,
    OMI_RUST_ERROR_TRANSPORT = 8,
    OMI_RUST_ERROR_CODEC = 9,
    OMI_RUST_ERROR_MICROPHONE = 10,
} omi_rust_error_kind_t;

typedef struct {
    bool red;
    bool green;
    bool blue;
    uint8_t blinks;
} omi_rust_error_pattern_t;

bool omi_rust_feedback_error_pattern(uint8_t kind, omi_rust_error_pattern_t *out);

typedef enum {
    OMI_RUST_STORAGE_CMD_INVALID = 0,
    OMI_RUST_STORAGE_CMD_RING_INFO = 1,
    OMI_RUST_STORAGE_CMD_RING_READ = 2,
    OMI_RUST_STORAGE_CMD_RING_ADVANCE = 3,
    OMI_RUST_STORAGE_CMD_RING_CLEAR = 4,
    OMI_RUST_STORAGE_CMD_STOP_SYNC = 5,
} omi_rust_storage_command_t;

typedef struct {
    omi_rust_storage_command_t command;
    uint64_t start_seq;
    uint32_t packet_count;
    uint64_t advance_seq;
} omi_rust_storage_parsed_t;

typedef struct {
    uint64_t read_seq;
    uint64_t write_seq;
    uint32_t capacity_packets;
    uint64_t dropped_packets;
    uint16_t packet_bytes;
} omi_rust_ring_info_fields_t;

uint8_t omi_rust_storage_parse_command(const uint8_t *buf, uint16_t len,
                                       omi_rust_storage_parsed_t *out);
uint8_t omi_rust_storage_status_from_error(int err, uint8_t fallback_status);
uint16_t omi_rust_storage_ble_chunk_size(uint16_t mtu);
uint32_t omi_rust_storage_crc32_update_byte(uint32_t crc, uint8_t byte);
void omi_rust_storage_transfer_reset(void);
void omi_rust_storage_transfer_start(uint64_t start_seq, uint32_t packet_count);
bool omi_rust_storage_transfer_active(void);
bool omi_rust_storage_transfer_read_begin_sent(void);
void omi_rust_storage_transfer_mark_read_begin_sent(void);
bool omi_rust_storage_transfer_done_pending(void);
void omi_rust_storage_transfer_complete(uint8_t status);
uint64_t omi_rust_storage_transfer_start_seq(void);
uint64_t omi_rust_storage_transfer_current_seq(void);
uint32_t omi_rust_storage_transfer_remaining_packets(void);
uint8_t omi_rust_storage_transfer_end_status(void);
uint32_t omi_rust_storage_transfer_data_crc(void);
void omi_rust_storage_transfer_note_packets_read(uint32_t packets_read);
void omi_rust_storage_transfer_update_crc_byte(uint8_t byte);
uint16_t omi_rust_storage_encode_ack(uint8_t status, uint8_t *out);
uint16_t omi_rust_storage_encode_done(uint8_t status, uint64_t next_seq, uint32_t crc, uint8_t *out);
uint16_t omi_rust_storage_encode_ring_info(const omi_rust_ring_info_fields_t *info, uint8_t *out);
uint16_t omi_rust_storage_encode_read_begin(uint64_t start_seq, uint32_t packet_count, uint8_t *out);
uint16_t omi_rust_storage_encode_data(const uint8_t *payload, uint16_t payload_len, uint8_t *out);

uint32_t omi_rust_audio_chunk_size(uint16_t mtu, uint32_t remaining);
int8_t omi_rust_ble_conn_params_reevaluate(bool audio_subscribed, bool storage_transfer_active);
void omi_rust_ble_conn_params_reset(void);
bool omi_rust_ble_charging_should_notify(bool charging, bool force);
void omi_rust_ble_charging_mark_notified(bool charging);
void omi_rust_ble_charging_reset(void);
typedef struct {
    bool request_exchange;
    bool reschedule;
    bool negotiated;
    uint8_t attempt;
} omi_rust_mtu_recheck_decision_t;
void omi_rust_ble_mtu_recheck_reset(void);
bool omi_rust_ble_mtu_recheck_can_schedule(void);
omi_rust_mtu_recheck_decision_t omi_rust_ble_mtu_recheck_step(bool connection_present, uint16_t mtu);
void omi_rust_audio_stereo_to_mono(const int16_t *interleaved, size_t frames, int16_t *mono_out);
size_t omi_rust_audio_stereo_frame_count(size_t byte_len, size_t max_frames);
uint32_t omi_rust_audio_avg_abs_amplitude(const int16_t *buf, size_t n);
void omi_rust_audio_aad_reset(int64_t now_ms);
void omi_rust_audio_aad_mark_woke(void);
bool omi_rust_audio_aad_should_sleep(const int16_t *buf, size_t n, int64_t now_ms,
                                     uint32_t threshold, int64_t hold_ms,
                                     bool storage_transfer_active);

uint8_t omi_rust_settings_clamp_dim_ratio(uint8_t value);
uint8_t omi_rust_settings_clamp_mic_gain(uint8_t value);
uint8_t omi_rust_mic_hw_gain(uint8_t level);

typedef struct {
    uint64_t epoch_s;
    uint32_t ts;
    uint32_t reserved;
} omi_rust_lsm6dsl_time_base_t;

int omi_rust_settings_parse_lsm6dsl_time_base(const uint8_t *buf, size_t len,
                                              omi_rust_lsm6dsl_time_base_t *out);

uint64_t omi_rust_rtc_extrapolate_ms(uint64_t base_epoch_ms, int64_t base_uptime_ms,
                                     int64_t now_uptime_ms);
uint32_t omi_rust_rtc_seconds_clamped(uint64_t now_ms);
int omi_rust_rtc_format_utc_datetime(uint64_t utc_epoch_s, uint8_t *out, size_t out_len);
uint64_t omi_rust_imu_boot_epoch_ms(uint64_t base_epoch_s, uint32_t base_ts, uint32_t ts_now);

void omi_rust_rtc_clock_init(void);
bool omi_rust_rtc_is_valid(void);
uint64_t omi_rust_rtc_get_utc_ms(void);
uint32_t omi_rust_rtc_get_utc_s(void);
int omi_rust_rtc_set_utc_ms(uint64_t utc_epoch_ms);
void omi_rust_rtc_set_pending_persist(uint64_t epoch_s);
uint64_t omi_rust_rtc_take_pending_persist(void);
void omi_rust_rtc_restore_from_epoch_s(uint64_t saved_epoch_s);
void omi_rust_rtc_invalidate(void);

void omi_rust_user_event_encode(uint8_t code, uint8_t source, uint16_t seq, uint32_t epoch_s,
                                uint8_t *out);
uint16_t omi_rust_user_event_alloc_seq(void);
void omi_rust_user_event_queue_push(uint8_t code, uint8_t source, uint16_t seq, uint32_t epoch_s);
bool omi_rust_user_event_queue_peek(uint8_t *out_code, uint8_t *out_source, uint16_t *out_seq,
                                    uint32_t *out_epoch);
bool omi_rust_user_event_queue_pop(void);
uint8_t omi_rust_user_event_queue_len(void);

typedef struct {
    bool speaker;
    bool accelerometer;
    bool button;
    bool battery;
    bool usb;
    bool haptic;
    bool offline_storage;
    bool user_events;
    bool imu_gestures;
    bool hw_vad;
    bool ble_sleep_cmd;
    bool capture_state;
    bool device_name_rw;
    bool wifi;
} omi_rust_feature_flags_t;

uint32_t omi_rust_features_assemble(const omi_rust_feature_flags_t *flags);

uint16_t omi_rust_wifi_encode_softap_header(uint64_t read_seq, uint64_t write_seq,
                                           uint16_t packet_bytes, uint8_t *out);
uint16_t omi_rust_wifi_encode_softap_done(uint64_t next_seq, uint8_t status, uint8_t *out);
typedef struct {
    uint8_t command;
    uint16_t first_offset;
    uint8_t first_len;
    uint16_t second_offset;
    uint8_t second_len;
    uint16_t third_offset;
    uint8_t third_len;
} omi_rust_wifi_parsed_t;
uint8_t omi_rust_wifi_parse_command(const uint8_t *buf, uint16_t len, bool home_enabled,
                                    omi_rust_wifi_parsed_t *out);
uint8_t omi_rust_wifi_err_hw_unavailable(void);

typedef enum {
    OMI_RUST_PACKER_APPEND = 0,
    OMI_RUST_PACKER_FLUSH_EXACT = 1,
    OMI_RUST_PACKER_FLUSH_OVERFLOW = 2,
} omi_rust_packer_action_t;

typedef struct {
    omi_rust_packer_action_t action;
    uint16_t prefix_offset;
    uint16_t data_offset;
    uint16_t trailing_prefix_offset;
    uint16_t flush_size;
    uint16_t new_buffer_offset;
} omi_rust_offline_packer_step_t;

void omi_rust_offline_packer_step(uint8_t tx_buffer_size, omi_rust_offline_packer_step_t *out);
void omi_rust_offline_packer_reset(void);

#ifdef __cplusplus
}
#endif

#endif
