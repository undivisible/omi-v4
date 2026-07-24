#include "wifi.h"

#include <errno.h>
#include <string.h>
#include <zephyr/logging/log.h>

LOG_MODULE_REGISTER(wifi_home, LOG_LEVEL_INF);

#if defined(CONFIG_OMI_ENABLE_WIFI) && defined(CONFIG_OMI_ENABLE_WIFI_HOME_STA)

#define WIFI_CLOUD_HOST_MAX 128
#define WIFI_TOKEN_MAX 96

static char home_ssid[WIFI_MAX_SSID_LEN + 1];
static char home_password[WIFI_MAX_PASSWORD_LEN + 1];
static char cloud_host[WIFI_CLOUD_HOST_MAX + 1];
static char cloud_token[WIFI_TOKEN_MAX + 1];
static bool home_creds_set;
static bool cloud_token_set;

int wifi_home_set_credentials(const char *ssid, const char *password)
{
	if (!ssid || !password) {
		return -EINVAL;
	}

	size_t ssid_len = strlen(ssid);
	size_t pwd_len = strlen(password);
	if (ssid_len == 0 || ssid_len > WIFI_MAX_SSID_LEN) {
		return -EINVAL;
	}
	if (pwd_len < WIFI_MIN_PASSWORD_LEN || pwd_len > WIFI_MAX_PASSWORD_LEN) {
		return -EINVAL;
	}

	memcpy(home_ssid, ssid, ssid_len);
	home_ssid[ssid_len] = '\0';
	memcpy(home_password, password, pwd_len);
	home_password[pwd_len] = '\0';
	home_creds_set = true;
	LOG_INF("Home STA credentials stored (ssid len=%u)", (unsigned)ssid_len);
	return 0;
}

void wifi_home_clear_credentials(void)
{
	memset(home_ssid, 0, sizeof(home_ssid));
	memset(home_password, 0, sizeof(home_password));
	home_creds_set = false;
}

int wifi_home_set_cloud_token(const char *host, const char *token)
{
	if (!host || !token) {
		return -EINVAL;
	}

	size_t host_len = strlen(host);
	size_t token_len = strlen(token);
	if (host_len == 0 || host_len > WIFI_CLOUD_HOST_MAX) {
		return -EINVAL;
	}
	if (token_len == 0 || token_len > WIFI_TOKEN_MAX) {
		return -EINVAL;
	}

	memcpy(cloud_host, host, host_len);
	cloud_host[host_len] = '\0';
	memcpy(cloud_token, token, token_len);
	cloud_token[token_len] = '\0';
	cloud_token_set = true;
	LOG_INF("Cloud device token stored (host len=%u)", (unsigned)host_len);
	return 0;
}

bool wifi_home_configured(void)
{
	return home_creds_set && cloud_token_set && wifi_is_hw_available();
}

int wifi_home_try_autosync(void)
{
	if (!wifi_home_configured()) {
		return -ENOENT;
	}

	LOG_INF("Home STA autosync stub: host=%s (not yet connected)", cloud_host);
	return -ENOTSUP;
}

#endif
