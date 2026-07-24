#ifndef _WIFI_H_
#define _WIFI_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <zephyr/kernel.h>

#define WIFI_MAX_SSID_LEN        32
#define WIFI_MAX_PASSWORD_LEN    64
#define WIFI_MIN_PASSWORD_LEN    8

typedef enum {
	OMI_WIFI_STATE_OFF,
	OMI_WIFI_STATE_SHUTDOWN,
	OMI_WIFI_STATE_ON,
	OMI_WIFI_STATE_CONNECTING,
	OMI_WIFI_STATE_CONNECT
} omi_wifi_state_t;

int wifi_init(void);
void wifi_turn_off(void);
int wifi_turn_on(void);
bool wifi_is_hw_available(void);
int setup_wifi_credentials(const char *ssid, const char *password);
int wifi_send_data(const uint8_t *data, size_t len);
bool is_wifi_transport_ready(void);
bool is_wifi_on(void);

#ifdef CONFIG_OMI_ENABLE_WIFI_HOME_STA
int wifi_home_set_credentials(const char *ssid, const char *password);
void wifi_home_clear_credentials(void);
int wifi_home_set_cloud_token(const char *host, const char *token);
int wifi_home_try_autosync(void);
bool wifi_home_configured(void);
#endif

#endif
