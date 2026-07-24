# WiFi sync (SoftAP + home cloud self-sync)

Restored from upstream BasedHardware/omi SoftAP work (last complete state
around `878b7f3830`, removed at `dfcbb8ca97`). omi-v4 ports protocol/logic into
Rust (`firmware/omi/rust/src/wifi_proto.rs`); Zephyr/nRF70/sockets stay in C.

## Feature bit divergence

| Bit | Upstream | omi-v4 |
| --- | --- | --- |
| `1 << 9` | `OMI_FEATURE_WIFI` | `FEATURE_CHARGING_STATE` (kept) |
| `1 << 16` | unused | `FEATURE_WIFI` / `OMI_FEATURE_WIFI` |

## Flash budget

Default production image keeps WiFi **off**:

- `CONFIG_OMI_ENABLE_WIFI=n` in `omi/omi.conf`
- Enable with `omi_wifi.conf` + `SB_CONFIG_WIFI_NRF70=y` (see
  `omi_wifi_sysbuild.conf`)

## SoftAP path (phone-assisted)

1. Companion writes SoftAP credentials to GATT `30295783…` (`WIFI_SETUP` /
   `0x01`).
2. `WIFI_START` (`0x02`) pauses the mic, brings up nRF7002 SoftAP + DHCP
   (`192.168.1.1`), waits for a station, then TCP-connects to
   `192.168.1.2:12345`.
3. Firmware streams the **SD ring** (not the old file-list protocol): header
   `0xA5` + seqs + packet size, then raw ring packets, then done `0x5A`.
4. `WIFI_SHUTDOWN` / power-off tears the SoftAP down. HW probe failure returns
   `0xFE` (`wifi_is_hw_available`).

## Home STA cloud self-sync

Goal: a cloud-registered pendant syncs at home without a phone SoftAP relay.

```
provision (phone + BLE) → register (worker) → home STA + upload (device)
```

1. **Register** — signed-in app calls `POST /api/v1/devices/register` with
   `{ deviceUid, name? }` → `{ deviceId, token, uploadHost, uploadPath }`.
2. **Provision** — app writes home SSID/password (`WIFI_HOME_SETUP` / `0x10`)
   and cloud host+token (`CLOUD_TOKEN` / `0x12`) over the same WiFi GATT char.
3. **Auto-sync** — when charging and home STA is configured, firmware calls
   `wifi_home_try_autosync()` (STA + HTTPS upload is **stubbed** behind
   `CONFIG_OMI_ENABLE_WIFI_HOME_STA`, default `n`, until flash budget allows
   TLS/STA). Worker upload endpoint is live:
   `POST /api/v1/devices/:deviceId/audio` with `Authorization: Bearer omi_dev_…`.

## Manual flash (charging cable?)

**The ordinary magnetic charging cable / dock does not flash the CV1.** It is
USB-C power into pogo pins (charge + sense). There is no USB DFU on the
charging path in the board DTS.

Ways to flash:

1. **OTA over BLE** (no cable) — build `dfu_application.zip`, use nRF Connect
   for Mobile DFU, or the companion OTA path. See `README.md`.
2. **SWD with a special flashing cable** — CV1 needs a dedicated SWD pogo/FPC
   cable to a J-Link / nRF debugger (documented upstream as distinct from the
   charger). Then:
   ```sh
   west flash --build-dir "$FW/omi/build"
   ```
   or the packaged `JLinkExe -CommanderScript program_{net,app}.jlink` flow
   from upstream `Flash_device.mdx` / `FLASH_3.0.8`.

## Hardware opportunities (DTS-grounded)

Present on `omi_nrf5340_cpuapp.dts` / architecture notes:

| Block | Status |
| --- | --- |
| Dual T5838 PDM + HW AAD pins | Used (AAD config-gated) |
| LSM6DS3TR-C IMU | Used (gestures config-gated) |
| SD-NAND + SPI NOR | Used (offline ring + MCUboot secondary) |
| nRF7002 on QSPI | **Wired; SoftAP path restored, default off** |
| PWM RGB LED, haptic, button | Used |
| Charge detect / battery ADC | Used |
| RF switch | Used |

Reasonable enablements: WiFi SoftAP/home STA (this doc), IMU double-tap,
adaptive BLE conn params, BT NUS shell debug, fuller AAD tuning — all mostly
Kconfig, not new silicon.
