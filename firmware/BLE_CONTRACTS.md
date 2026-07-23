# Omi pendant BLE contracts

*Interface reference for the mobile/desktop apps. Every entry below is derived
from the firmware sources in this directory; file and function citations are
inline so each claim is checkable. Reflects `firmware/omi/VERSION` 3.1.0 on top
of upstream `BasedHardware/omi` `ed4e513e` (see `PROVENANCE.md`).*

## 0. Which device am I talking to?

Two different Zephyr firmwares implement (parts of) this interface:

| Device | Firmware | Advertised name | DIS model `0x2A24` |
| --- | --- | --- | --- |
| **CV1 pendant** (production, nRF5340) | `firmware/omi/` | `Omi` | `Omi CV 1` |
| **DevKit v1** (XIAO nRF52840 Sense) | `firmware/devkit/`, `prj_xiao_ble_sense_devkitv1.conf` | `Friend` | `Friend DevKit 1` |
| **DevKit v1-spisd** | same app, `…devkitv1-spisd.conf` | `Friend` | `Friend DevKit 1 SPI SD` |
| **DevKit v2-adafruit** | same app, `…devkitv2-adafruit.conf` | `Friend` | see that config file |

**Everything in this document is the CV1 contract.** The DevKit implements a
subset, listed in §12. Read the features bitmap (§4) and fall back to GATT
discovery rather than assuming a characteristic exists.

**Other Omi hardware does not implement this profile at all.** The glasses
firmware (`omiGlass` upstream, and the sibling `OpenGlass` repository) is a
Seeed XIAO ESP32-S3 Sense Arduino application, and `Whomane` is a Raspberry Pi
Python wearable. Neither runs Zephyr and neither shares any UUID below. Do not
route them through the same client code.

## 0.1 Conventions

- **Base UUID**: most custom services use `xxxxxxxx-E8F2-537E-4F6C-D104768A1214`.
  The button, accelerometer, haptic and storage services predate that and use
  their own bases; full 128-bit UUIDs are given for every entry.
- **Endianness is not uniform.** It is stated per characteristic. The rule of
  thumb: the offline-storage control protocol is **big-endian** (it uses
  `sys_put_be*`, `firmware/omi/src/lib/core/storage.c`), everything else is
  **little-endian** (raw struct reads, or `sys_put_le*`).
- **Presence is build-dependent.** Characteristics guarded by a Kconfig symbol
  only exist when it is enabled. The "Present in this build" column reflects
  `firmware/omi/omi.conf` as committed. Prefer feature-detecting via the
  features bitmap (§4) or a GATT discovery pass over hard-coding.
- **Security**: no characteristic uses encrypted or authenticated permissions.
  All are `BT_GATT_PERM_READ` / `BT_GATT_PERM_WRITE`
  (`firmware/omi/src/lib/core/transport.c`). Pairing is available
  (`CONFIG_BT_SMP=y`) but nothing requires it.
- **MTU**: the peripheral requests an ATT MTU exchange, 2M PHY and maximum data
  length on connect, retrying the MTU exchange up to six times at 800 ms
  intervals (`_transport_connected`, `mtu_recheck_work_handler`). The app should
  request a large MTU itself. **Several payloads below need MTU ≥ 34**; the
  offline-sync `INFO` response is 31 bytes.

## 1. Advertising and identity

| Field | Value | Source |
| --- | --- | --- |
| Advertising data | Flags (general discoverable, no BR/EDR), full 128-bit audio service UUID `19B10000-…`, complete local name | `bt_ad` in `transport.c` |
| Scan response | 16-bit UUID `0x180A` (Device Information) | `bt_sd` in `transport.c` |
| Default name | `"Omi"` (`CONFIG_BT_DEVICE_NAME`) | `omi.conf` |
| Appearance | 22 (`CONFIG_BT_DEVICE_APPEARANCE`) | `omi.conf` |
| Max connections | 1 (`CONFIG_BT_MAX_CONN=1`) | `omi.conf` |

Note: the advertised name is the compile-time `CONFIG_BT_DEVICE_NAME` literal,
because `bt_ad` embeds it at build time. A device renamed through `19B10016`
(§3.7) reports the new name via `bt_get_name()` in the GAP Device Name
characteristic and on the next `bt_le_adv_start()`, but the currently running
advertisement keeps the old name until BLE is restarted. Do not rely on the
advertised name for identification; use the BLE address.

## 2. Audio service — `19B10000-E8F2-537E-4F6C-D104768A1214`

`firmware/omi/src/lib/core/transport.c`

### 2.1 Audio data — `19B10001-…` — Read, Notify

The live audio stream. Subscribing to this characteristic is what the firmware
treats as "capturing": it flips the capture-state flag (§3.6), turns the status
LED blue and holds off idle auto-sleep (`transport_is_audio_subscribed()`,
`update_idle_sleep()` in `src/main.c`).

Each notification is:

```
offset 0 : uint16  packet_id   (little-endian, wraps at 65535)
offset 2 : uint8   chunk_index (0-based, resets per packet_id)
offset 3 : ...     Opus payload bytes
```

One encoded Opus frame is one `packet_id`. If the frame does not fit in a single
notification it is split across consecutive `chunk_index` values with the same
`packet_id`; concatenate them in order to recover the frame
(`push_to_gatt()`). At any negotiated MTU above 163 a frame always fits in one
notification, because `CODEC_OUTPUT_MAX_BYTES` is 160 (`src/lib/core/config.h`).

A read returns an empty value; the characteristic is notify-only in practice.

**Gaps are expected and are not errors.** `packet_id` is a free-running counter
that is not reset on subscribe, and the firmware drops frames rather than
blocking when the link stalls. Treat a jump in `packet_id` as lost audio, not as
a protocol error.

### 2.2 Audio codec — `19B10002-…` — Read

Single byte codec identifier. This build returns **21** = Opus.

Opus parameters (`src/lib/core/codec.c` `codec_start()`, `src/lib/core/config.h`):

| Parameter | Value |
| --- | --- |
| Sample rate | 16 000 Hz |
| Channels | 1 (the two T5838 mics are mixed to mono in `src/mic.c`) |
| Application | `OPUS_APPLICATION_RESTRICTED_LOWDELAY` |
| Frame | 320 samples = 20 ms |
| Bitrate | 32 000 bps |
| VBR | on, unconstrained |
| Complexity | 3 |
| Signal type | `OPUS_SIGNAL_VOICE` |
| DTX | **off** |
| In-band FEC | off |

DTX off means silence is encoded at full bitrate. On-device silence suppression
is handled at the microphone instead (§7).

### 2.3 Speaker / haptic passthrough — `19B10003-…` — Write, Notify

**Not present in this build.** Compiled only under
`CONFIG_OMI_ENABLE_SPEAKER`, which is `n` in `omi.conf`.

## 3. Settings service — `19B10010-E8F2-537E-4F6C-D104768A1214`

`firmware/omi/src/lib/core/transport.c`

| UUID | Properties | Payload | Kconfig | Present |
| --- | --- | --- | --- | --- |
| `19B10011-…` | Read, Write | 1 byte, LED dim ratio 0–100 | always | yes |
| `19B10012-…` | Read, Write | 1 byte, mic gain level 0–8 | always | yes |
| `19B10013-…` | Read, Notify | 1 byte, charging state | always | yes |
| `19B10014-…` | Write | 1 byte, sleep command | `OMI_ENABLE_BLE_SLEEP_CMD` | yes |
| `19B10015-…` | Read, Write | 1 byte, capture state | `OMI_ENABLE_CAPTURE_LED` | yes |
| `19B10016-…` | Read, Write | UTF-8 device name | `OMI_ENABLE_DEVICE_NAME_RW` | yes |
| `19B10017-…` | Read, Notify | 8 bytes, user event | `OMI_ENABLE_USER_EVENTS` | yes |

### 3.1 LED dim ratio — `19B10011-…` — Read, Write

One byte, 0–100, the PWM duty applied to every status LED
(`set_led_on_off()` in `src/led.c`). Values above 100 are clamped to 100. Writes
of any other length are rejected with `Invalid Attribute Length`. Persisted in
NVS (`app_settings_save_dim_ratio()`).

### 3.2 Microphone gain — `19B10012-…` — Read, Write

One byte, level 0–8, clamped to 8. Applied immediately to the nRF PDM gain
register and persisted (`mic_set_gain()` in `src/mic.c`):

| Level | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Gain | mute | −20 dB | −10 dB | 0 dB | +6 dB | +10 dB | +20 dB | +30 dB | +40 dB |

### 3.3 Charging state — `19B10013-…` — Read, Notify

One byte: `0` = not charging, `1` = charging. Derived from the `bat_chg_pin`
GPIO (P0.07, active low: pin low means charging) in
`battery_charging_state_read()`, `src/battery.c`.

Notification behaviour:

- On subscribe, the current value is pushed immediately (forced, even if
  unchanged) — `charging_status_ccc_config_changed_handler()`.
- On every charger plug/unplug edge, the GPIO interrupt schedules a notification
  from the system workqueue (`transport_notify_charging_changed()`).
- The 5-second battery work item also re-checks it as a backstop.
- Notifications are deduplicated: the same value is not sent twice in a row.

There is no separate "charged" value. The green-LED "fully charged" condition
the firmware itself uses is `19B10013 == 1` **and** battery level (BAS `0x2A19`,
§5) `>= 98` — `BATTERY_FULL_THRESHOLD_PERCENT` in `src/main.c`. Mirror that if
you want to reproduce the LED exactly.

### 3.4 Sleep command — `19B10014-…` — Write

Write the single byte `0x01` to put the pendant into system off. Any other value
is ignored with a warning; any length other than 1 is rejected. This runs the
same `turnoff_all()` path as a long button press: haptic pulse, BLE teardown,
mic off, SD flush and unmount, then `sys_poweroff()`
(`settings_sleep_cmd_write_handler()` → `turnoff_all()` in
`src/lib/core/button.c`).

Expect the connection to drop roughly 1.5–3 s after the write. Before the radio
goes down the firmware emits a `POWER_OFF` user event (§3.7), so a subscriber
gets an explicit "going down now" signal rather than an unexplained disconnect.

**The device cannot be woken over BLE.** In nRF5340 system off the radio is
unpowered. Wake sources are the user button and, when
`CONFIG_OMI_ENABLE_IMU_GESTURES` is on, IMU motion (§8).

### 3.5 Capture state — `19B10015-…` — Read, Write

One byte, `0` or `1`. Mirrors the firmware's internal `is_capturing` flag, which
drives the blue status LED. It is set automatically when a central subscribes to
the audio characteristic and cleared when it unsubscribes
(`audio_ccc_config_changed_handler()`); writing it lets the app override the LED
(for example to show "capturing" while it is buffering, or to force it off).

Note that the LED also requires the microphone to be awake: while the mic is in
hardware AAD sleep the LED is not blue even if this flag is 1
(`set_led_state()` in `src/main.c`, `mic_in_aad_sleep()`).

### 3.6 Device name — `19B10016-…` — Read, Write

Read returns the current `bt_get_name()` string (no NUL terminator). Write
accepts 1..`CONFIG_BT_DEVICE_NAME_MAX` UTF-8 bytes, applies it with
`bt_set_name()` and persists it in NVS, so it survives reboot without
`CONFIG_BT_SETTINGS`. Empty or over-long writes are rejected with
`Invalid Attribute Length`.

See §1 for the caveat about the advertised name.

### 3.7 User events — `19B10017-…` — Read, Notify

**New in this branch.** The device-originated event stream: button gestures,
power-off warning, microphone sleep/wake and IMU gestures. Declared in
`firmware/omi/src/lib/core/user_event.h`, implemented in `transport.c`.

Payload is 8 bytes, **little-endian**:

```
offset 0 : uint8   code
offset 1 : uint8   source
offset 2 : uint16  seq      monotonic, wraps at 65535
offset 4 : uint32  epoch_s  UTC seconds, 0 if the RTC is not synced
```

A read returns the most recent event, or all zeros if none has been emitted
since boot.

Event codes:

| Code | Name | Meaning |
| --- | --- | --- |
| `0x01` | `BOOKMARK` | **Single button tap — "mark this moment".** |
| `0x02` | `ASSISTANT` | **Double button tap — "talk to the assistant".** |
| `0x03` | `POWER_OFF` | The device is entering system off (long press, sleep command, idle auto-sleep, or critical battery). |
| `0x10` | `MIC_SLEEP` | The microphone entered T5838 hardware AAD sleep. Audio stops flowing; this is silence, not a fault. |
| `0x11` | `MIC_WAKE` | Acoustic activity woke the microphone; audio resumes. |
| `0x20` | `IMU_MOTION` | The accelerometer saw motion above the wake threshold. |
| `0x21` | `IMU_DOUBLE_TAP` | Double tap on the pendant body (off by default, see §8). |

Source codes: `0x01` button, `0x02` microphone, `0x03` IMU, `0x04` system.

Delivery semantics:

- Events raised while a central is subscribed are notified immediately.
- Events raised while disconnected or unsubscribed are queued in a RAM ring of
  `CONFIG_OMI_USER_EVENT_QUEUE_LEN` entries (16 by default). The oldest is
  dropped on overflow. The whole queue is flushed, **in order**, when the
  central subscribes.
- The queue is RAM only. A tap made while disconnected survives a reconnect but
  **not** a reboot or a system-off cycle. Persisting bookmarks to the SD ring
  would require a raw layout version bump (`RAW_LAYOUT_VERSION` in
  `src/sd_card.c`) and is deliberately not done.
- `seq` lets the app detect drops. It is not reset on reconnect; only on reboot.
- `epoch_s` is `0` until the app has written the time-sync characteristic (§6)
  at least once since the last power loss.

Single and double tap also still appear on the legacy button service (§9.1) for
existing app builds.

## 4. Features service — `19B10020-E8F2-537E-4F6C-D104768A1214`

### 4.1 Feature bitmap — `19B10021-…` — Read

`uint32` bitmap, **little-endian** (a raw struct read). Bits, from
`firmware/omi/src/lib/core/features.h` and `features_read_handler()`:

| Bit | Mask | Feature | Set in this build |
| --- | --- | --- | --- |
| 0 | `0x00000001` | Speaker | no |
| 1 | `0x00000002` | Accelerometer service (`32403790-…`) | no |
| 2 | `0x00000004` | Button service | yes |
| 3 | `0x00000008` | Battery | yes |
| 4 | `0x00000010` | USB | no |
| 5 | `0x00000020` | Haptic | yes |
| 6 | `0x00000040` | Offline storage | yes |
| 7 | `0x00000080` | LED dimming | yes (always) |
| 8 | `0x00000100` | Mic gain | yes (always) |
| 9 | `0x00000200` | Charging state characteristic | yes (always) |
| 10 | `0x00000400` | User events (`19B10017`) | yes |
| 11 | `0x00000800` | IMU gestures | yes |
| 12 | `0x00001000` | Hardware VAD (T5838 AAD) | yes |
| 13 | `0x00002000` | BLE sleep command (`19B10014`) | yes |
| 14 | `0x00004000` | Capture state (`19B10015`) | yes |
| 15 | `0x00008000` | Writable device name (`19B10016`) | yes |

Bits 9–15 are new in this branch. Older firmware reports 0 for them; treat an
unset bit as "characteristic may be absent" and fall back to GATT discovery.

## 5. Standard Bluetooth SIG services

| Service | UUID | Characteristic | Value |
| --- | --- | --- | --- |
| Battery Service | `0x180F` | Battery Level `0x2A19`, read + notify | `uint8` percent, EMA-filtered (`src/battery.c`), pushed every 5 s while connected |
| Device Information | `0x180A` | Manufacturer Name `0x2A29` | `"Based Hardware"` |
| | | Model Number `0x2A24` | `"Omi CV 1"` |
| | | Hardware Revision `0x2A27` | `"5.0"` |
| | | Firmware Revision `0x2A26` | see below |

**Firmware Revision `0x2A26`** is a UTF-8 string, format `MAJOR.MINOR.PATCH`
(with `-EXTRAVERSION` appended when set). The contract is unchanged from
previous firmware, but the value is no longer a hand-edited literal: it is
generated from `firmware/omi/VERSION` by `firmware/omi/CMakeLists.txt` into a
Kconfig fragment that overrides `CONFIG_BT_DIS_FW_REV_STR`. Current value:
**`3.1.0`**.

If a device ever reports `0.0.0+unset`, the generated fragment did not get
applied — that is the deliberate sentinel left in `omi.conf`, not a real
release.

The pendant also enters critical shutdown below 3500 mV regardless of the
reported percentage (`CONFIG_OMI_BATTERY_CRITICAL_MV` in `transport.c`).

## 6. Time sync service — `19B10030-E8F2-537E-4F6C-D104768A1214`

| UUID | Properties | Payload |
| --- | --- | --- |
| `19B10031-…` | Write | `uint32` UTC epoch seconds, **little-endian**, exactly 4 bytes |
| `19B10032-…` | Read | `uint32` UTC epoch seconds, **little-endian** |

Both are raw `memcpy`/`bt_gatt_attr_read` of a native `uint32_t`, hence
little-endian. A write of any other length is rejected.

**This is a hard dependency for offline recording.** `process_write_data_req()`
in `src/sd_card.c` refuses to store any audio packet while
`rtc_is_valid()` is false or the epoch is below `1700000000`, because every
stored packet carries a timestamp. A pendant that has lost its clock (first
boot, long system-off without an IMU time base) records **nothing** until the
app writes this characteristic. The firmware signals this state by blinking the
red LED (`set_led_state()` in `src/main.c`) and by reporting `rtc_valid = 0` in
the storage status characteristic (§7.3).

**The app should write `19B10031` on every connect**, before enabling audio.

The RTC survives system off through an IMU timestamp base written to NVS on the
way down and replayed on boot (`lsm6dsl_time_prepare_for_system_off()` /
`lsm6dsl_time_boot_adjust_rtc()` in `src/imu.c`), so a normal sleep/wake cycle
keeps time. A battery-out event does not.

## 7. Offline storage service — `30295780-4301-EABD-2904-2849ADFEAE43`

`firmware/omi/src/lib/core/storage.c` (protocol) and `firmware/omi/src/sd_card.c`
(on-disk ring). Present when `CONFIG_OMI_ENABLE_OFFLINE_STORAGE=y`, which it is.

| UUID | Properties | Role |
| --- | --- | --- |
| `30295781-…` | Write, Notify | Control: commands in, responses and bulk data out |
| `30295782-…` | Read, Notify | Status snapshot (polled; nothing ever notifies it) |

**All multi-byte fields on `30295781` are big-endian.** The status
characteristic `30295782` is little-endian (raw struct read). This asymmetry is
inherited from upstream; do not "fix" it on one side only.

### 7.1 Storage model

The SD-NAND is **not** a filesystem. `src/sd_card.c` writes raw 512-byte sectors:
64 metadata sectors holding a generation-versioned round-robin of ring pointers,
followed by fixed 32-sector (16 KiB) batches of audio.

- **Packet**: 444 bytes = 4-byte big-endian UTC epoch second + 440 bytes of
  payload (`RAW_AUDIO_PACKET_BYTES` / `MAX_WRITE_SIZE` in
  `src/lib/core/sd_card.h`).
- **Batch**: 32-byte header + 36 packets (`RAW_PACKETS_PER_BATCH`).
- **Sequence numbers**: `read_seq` and `write_seq` are 64-bit monotonic packet
  counters. `write_seq` is the next packet to be written; `read_seq` is the
  oldest packet still retained. Unread packets = `write_seq - read_seq`.
- **Capacity**: `capacity_packets` is computed at mount from the actual card
  size. On the shipped 512 MB SD-NAND this is on the order of 1.1 M packets
  ≈ 480 MB ≈ 35 hours of continuous 32 kbps audio. Read the real number from
  the `INFO` response rather than assuming.
- **It is a ring. Oldest data is overwritten once full.** When the writer laps
  the reader, the firmware advances `read_seq` past the overwritten region and
  adds the difference to `dropped_packets`. An app that syncs rarely will lose
  the oldest audio silently except for the `dropped_packets` counter, which is
  the only signal that this happened. `dropped_packets` is cumulative since the
  last `CMD_RING_CLEAR`.

### 7.2 Payload framing inside a packet

The 440-byte payload is a concatenation of length-prefixed Opus frames written
by `write_to_storage()` in `transport.c`:

```
[uint8 len][len bytes of Opus] [uint8 len][len bytes] ...
```

Decode by walking from offset 0 and stopping as soon as `len == 0` or
`offset + 1 + len > 440`; the tail of a partially filled block is padding and
may contain a stale length byte. Frames are 20 ms of 16 kHz mono Opus, same
parameters as the live stream (§2.2), so the same decoder works for both.

### 7.3 Status characteristic — `30295782-…` — Read

16 bytes, four native `uint32` values, **little-endian**:

```
offset 0  : uint32 used_bytes       unread_packets * 444
offset 4  : uint32 unread_packets   write_seq - read_seq
offset 8  : uint32 free_bytes       (capacity_packets - unread) * 444
offset 12 : uint32 rtc_valid        1 if the clock is synced, else 0
```

This is a cached snapshot, refreshed at most every 250 ms while connected
(`storage_status_cache_maybe_refresh()`), and updated live as a sync frees
space. It is cheap to poll and does not touch the SD card. It is declared
`NOTIFY` but the firmware never notifies it — poll it.

`rtc_valid == 0` means the device is currently recording nothing (§6).

### 7.4 Control commands — write to `30295781-…`

| Opcode | Length | Arguments | Response |
| --- | --- | --- | --- |
| `0x10` `RING_INFO` | 1 | — | `INFO` notification, or `ACK` with an error status |
| `0x11` `RING_READ` | 9 or 13 | `be64 start_seq` [`be32 packet_count`] | `READ_BEGIN`, then a stream of `DATA`, then `DONE` |
| `0x12` `RING_ADVANCE` | 9 | `be64 new_read_seq` | `ACK` |
| `0x13` `RING_CLEAR` | 1 | — | `ACK` |
| `0x03` `STOP_SYNC` | 1 | — | `ACK` (status 0), and any transfer in flight is abandoned |

Any other opcode, or a wrong length, gets `ACK` with status `6`.

`packet_count` of 0 (or omitting it by sending the 9-byte form) means "as many
as are available from `start_seq`".

### 7.5 Notifications from `30295781-…`

First byte is the type tag.

| Tag | Name | Layout | Total |
| --- | --- | --- | --- |
| `0x01` | `ACK` | `u8 tag`, `u8 status` | 2 |
| `0x02` | `INFO` | `u8 tag`, `be64 read_seq`, `be64 write_seq`, `be32 capacity_packets`, `be64 dropped_packets`, `be16 packet_bytes` | 31 |
| `0x03` | `DATA` | `u8 tag`, raw ring bytes | up to `ATT_MTU − 3` |
| `0x04` | `DONE` | `u8 tag`, `u8 status`, `be64 next_seq` | 10 |
| `0x05` | `READ_BEGIN` | `u8 tag`, `be64 start_seq`, `be32 packet_count` | 13 |

Status values: `0` success, `6` invalid command, `9` storage not ready
(card unmounted, busy, or timed out), `10` sequence out of range.

`packet_bytes` in `INFO` is 444 and is authoritative — use it rather than
hard-coding.

`DATA` payloads are a **byte stream**, not packet-aligned: a 444-byte packet is
split across whatever chunk size the MTU allows
(`get_ble_data_chunk_size()` returns `ATT_MTU − 4`). Reassemble by byte count
starting at `READ_BEGIN.start_seq`, then split into 444-byte packets.

`DONE.next_seq` is the sequence number the device stopped at. On a clean run it
equals `start_seq + packet_count`.

### 7.6 Recommended sync flow

1. Connect, negotiate a large MTU, subscribe to `30295781` notifications.
2. Write the current time to `19B10031` (§6).
3. Send `RING_INFO` (`0x10`). Wait for `INFO`. If you get `ACK` with status `9`,
   the card is still remounting — the firmware already waits up to 5 s
   internally before answering `9`, so a `9` means genuinely unavailable. Retry
   later rather than immediately.
4. Compute `unread = write_seq − read_seq`. If `dropped_packets` grew since your
   last sync, there is a gap in your recording history; surface it.
5. Send `RING_READ` (`0x11`) with `start_seq = read_seq` and the packet count you
   want (or 0 for everything).
6. Consume `READ_BEGIN` → `DATA`* → `DONE`. Reassemble, split into 444-byte
   packets, take the big-endian timestamp from each, decode the payload (§7.2).
7. **Deletion is `RING_ADVANCE` (`0x12`)**: write the sequence number up to which
   you have durably stored the audio. Everything below it becomes reusable ring
   space. This is the only per-range delete primitive; there is no
   delete-by-file, because there are no files.
   - You do not have to do this explicitly for the range you just read: during
     a transfer the firmware auto-advances `read_seq` to the last packet whose
     notification the controller confirmed sending, checkpointing every 2 s and
     once more at `DONE` (`sync_checkpoint_advance()`). A mid-sync disconnect
     therefore resumes from the last checkpoint instead of restarting.
   - Send an explicit `RING_ADVANCE` after you have committed the data to your
     own storage if you want stronger guarantees than "the controller sent it".
8. `RING_CLEAR` (`0x13`) wipes everything and resets `read_seq`, `write_seq` and
   `dropped_packets` to 0. Use it for factory reset, not for routine sync.
9. `STOP_SYNC` (`0x03`) aborts an in-flight read. The firmware checkpoints what
   was confirmed and stops; the next `RING_INFO` shows where it got to.

### 7.7 Verified behaviour and known limits

Verified by reading the implementation (this branch is **not** compile- or
hardware-verified, see §11):

- **Recording while disconnected works**: when there is no connection the audio
  pusher writes each encoded frame to the SD ring instead of the GATT stream
  (`pusher()` in `transport.c`), provided the RTC is valid and the card is
  powered.
- **Retention across power cycles works**: ring pointers live in the 64-sector
  metadata round-robin with a generation counter, so a torn write falls back to
  the previous valid record (`load_ring_metadata()`), and a partially written
  tail batch is truncated on mount (`restore_tail_batch()`).
- **Sync does not starve control traffic**: bulk `DATA` notifications and audio
  notifications share a TX-slot semaphore that always leaves 2 buffers free for
  battery/charging/status notifications (`transport_bulk_tx_acquire()`).
- **Sync defers AAD sleep**: the mic will not drop into hardware AAD sleep while
  `storage_transfer_active()` (`aad_track_silence()` in `src/mic.c`), so a sync
  is never interrupted by the power-saving path.
- **Limit — connected but not subscribed records nothing.** The pusher only
  falls back to SD when there is *no* connection at all. If the app is connected
  but not subscribed to `19B10001`, audio is discarded, neither streamed nor
  stored. This is intentional (it is how "capture off" is expressed) but it also
  means a long sync session with audio unsubscribed loses that period's audio.
  If you want continuous capture, stay subscribed.
- **Limit — no clock, no recording.** See §6.
- **Limit — the ring overwrites silently.** See §7.1.

## 8. IMU gestures and wake-on-motion

New in this branch, `firmware/omi/src/imu_gesture.c`, gated by
`CONFIG_OMI_ENABLE_IMU_GESTURES` (`y` in this build).

There is no dedicated characteristic: IMU events arrive on the user-event
characteristic `19B10017` (§3.7) as codes `0x20` (`IMU_MOTION`) and `0x21`
(`IMU_DOUBLE_TAP`) with source `0x03`.

- **Wake-on-motion**: the LSM6DS3TR-C activity detector is routed to INT1
  (P1.13). While running, motion emits `IMU_MOTION` and resets the idle
  auto-sleep timer, so a worn pendant does not fall asleep. Before
  `sys_poweroff()` the interrupt is re-armed as a level interrupt so the nRF5340
  GPIO SENSE block wakes the SoC — the pendant can come back from idle sleep on
  movement alone, without a button press. Waking is a full reboot; the app will
  see a fresh advertisement.
- **Double tap on the pendant body** emits `IMU_DOUBLE_TAP` as an alternative to
  the button double tap. `CONFIG_OMI_ENABLE_IMU_DOUBLE_TAP` defaults to `n`
  because it needs the accelerometer at 416 Hz instead of 26 Hz (real idle
  current) and the thresholds have not been validated on hardware. Apps should
  handle `0x21` but not depend on it.

Thresholds are Kconfig ints (`OMI_IMU_WAKE_THRESHOLD`, `OMI_IMU_WAKE_DURATION`,
`OMI_IMU_TAP_*`).

## 9. Legacy and conditional services

### 9.1 Button service — `23BA7924-0000-1000-7450-346EAC492E92`

`firmware/omi/src/lib/core/button.c`. Present when `CONFIG_OMI_ENABLE_BUTTON=y`.

Characteristic `23BA7925-…`, read + notify. Payload is 8 bytes: a native
`int[2]`, **little-endian**, where element 0 is the event code and element 1 is
always 0.

| Code | Name | Emitted? |
| --- | --- | --- |
| 1 | `SINGLE_TAP` | yes, on single tap |
| 2 | `DOUBLE_TAP` | yes, on double tap |
| 3 | `LONG_TAP` | **never** — long press goes straight to `turnoff_all()`; use user event `0x03` instead |
| 4 | `BUTTON_PRESS` | **never** — `notify_press()` exists but is not called |
| 5 | `BUTTON_RELEASE` | yes, on release after a press longer than 300 ms |

Timing (`check_button_level()`, polled at 25 Hz): tap threshold 300 ms,
double-tap window 600 ms, long press 3000 ms.

New apps should use `19B10017` (§3.7), which carries the same taps plus a
timestamp, a sequence number and offline queueing. This service is retained
unchanged so existing app builds keep working.

### 9.2 Haptic service — `CAB1AB95-2EA5-4F4D-BB56-874B72CFC984`

`firmware/omi/src/haptic.c`. Present when `CONFIG_OMI_ENABLE_HAPTIC=y`, which it
is.

Characteristic `CAB1AB96-…`, write only, one byte:

| Value | Effect |
| --- | --- |
| 1 | 100 ms buzz |
| 2 | 300 ms buzz |
| 3 | 500 ms buzz |

Any other value is ignored.

Note that `src/lib/core/speaker.c` declares the *same* service UUID
`CAB1AB95-…`. Only one of the two is ever registered because
`CONFIG_OMI_ENABLE_SPEAKER=n`; if a build enables both, they collide.

### 9.3 Accelerometer service — `32403790-0000-1000-7450-BF445E5829A2`

**Not present in this build.** `src/lib/core/accel.c` is gated by
`CONFIG_OMI_ENABLE_ACCELEROMETER` (`n`) and is not even listed in
`firmware/omi/CMakeLists.txt`, so enabling that symbol alone will fail to link.
IMU functionality in this build is exposed through §8 instead.

### 9.4 SMP / MCUmgr — `8D53DC1D-1DB7-4CD3-868B-8A527460AA84`

Registered by `CONFIG_NCS_SAMPLE_MCUMGR_BT_OTA_DFU=y` (`omi.conf`). This is the
standard Zephyr SMP-over-BLE service used for OTA. See `README.md` for the DFU
flow; the app should use a standard McuMgr client library rather than driving it
by hand.

## 10. Connection parameters

Requested by the peripheral on connect (`_transport_connected()`):

| Parameter | Value | Source |
| --- | --- | --- |
| Connection interval | 7.5–15 ms (`CONFIG_OMI_CONN_INTERVAL_FAST_MIN/MAX`, 6–12 units) | `transport.c` |
| Peripheral latency | 0 | |
| Supervision timeout | 4 s (`CONFIG_OMI_CONN_SUPERVISION_TIMEOUT` = 400) | |
| PHY | 2M preferred, both directions | `update_phy()` |
| Data length | `BT_GAP_DATA_LEN_MAX` | `update_data_length()` |
| ATT MTU | requested, up to `CONFIG_BT_L2CAP_TX_MTU` = 498 | `update_mtu()` |

The peripheral re-requests the fast interval if the central settles above
15 ms. `CONFIG_OMI_ENABLE_ADAPTIVE_CONN_PARAMS` (off by default) additionally
relaxes the link to 30–50 ms with latency 4 whenever audio is unsubscribed and
no sync is running.

## 11. Per-device support matrix

`—` means the characteristic is not registered on that target at all; a read or
write will fail with "attribute not found". "needs button" means the code is
present but `CONFIG_OMI_ENABLE_BUTTON` is off in that configuration, because the
DevKit button is an external switch the user wires between D4 and D5
(`firmware/devkit/src/button.c`) and a floating pin would produce spurious taps.

| UUID | What | CV1 | DevKit v1 | v1-spisd | v2-adafruit |
| --- | --- | --- | --- | --- | --- |
| `19B10001` | Audio data | yes | yes | yes | yes |
| `19B10002` | Codec id | yes | yes | yes | yes |
| `19B10003` | Speaker | — | — | — | yes |
| `19B10011` | LED dim ratio | yes | — | — | — |
| `19B10012` | Mic gain | yes | — | — | — |
| `19B10013` | Charging state | yes | — | — | yes |
| `19B10014` | Sleep command | yes | needs button | needs button | yes |
| `19B10015` | Capture state | yes | yes | yes | yes |
| `19B10016` | Device name | yes | — | — | — |
| `19B10017` | User events | yes | yes | yes | yes |
| `19B10021` | Features bitmap | yes | yes | yes | yes |
| `19B10031`/`32` | Time sync | yes, NVS-backed | yes, RAM only | yes, RAM only | yes, RAM only |
| `30295781`/`82` | Offline storage | yes, raw ring | — | yes, **FATFS, different protocol** | yes, **FATFS, different protocol** |
| `23BA7925` | Legacy button | yes | needs button | needs button | yes |
| `CAB1AB96` | Haptic | yes | — | — | yes |
| `32403791` | Accelerometer stream | — | — | — | yes |
| `0x2A19` | Battery level (BAS) | yes | yes | yes | yes |
| `0x2A26` | Firmware revision (DIS) | yes | yes | yes | yes |
| `00001531` | Nordic legacy DFU | — | yes | yes | yes |
| SMP `8D53DC1D…` | MCUmgr OTA | yes | — | — | — |

Per-device notes the app must handle:

- **User events on the DevKit** use the identical 8-byte layout and the identical
  codes (`firmware/devkit/src/omi_ext.h`), but only `0x01` bookmark, `0x02`
  assistant and `0x03` power-off are ever emitted. There is no `0x10`/`0x11`
  microphone sleep pair (no hardware AAD) and no `0x20`/`0x21` IMU pair.
- **DevKit timestamps are volatile.** The DevKit has no RTC peripheral and no
  NVS in these builds, so `19B10032` returns base-epoch + uptime and resets to 0
  on every reboot. Write `19B10031` on every connect and do not trust a DevKit
  timestamp across a reconnect that followed a reboot.
- **DevKit offline storage is a different protocol.** The `-spisd` and
  `v2-adafruit` builds use `firmware/devkit/src/storage.c` over FATFS, which
  predates the CV1 ring protocol in §7 and does not share its opcodes. Section 7
  applies to the CV1 only. Gate on the DIS model string, not just on the
  presence of the `30295780` service.
- **OTA differs.** CV1 is MCUboot + SMP over BLE; the DevKits use the Adafruit
  UF2 bootloader with the Nordic legacy DFU service `00001530`/`00001531`.
- **The DevKit has no LED dim ratio or mic gain**, so any settings UI must be
  driven from the features bitmap rather than assumed.

## 12. Verification status

This branch has **not** been compiled or run on hardware. No Zephyr / nRF
Connect SDK toolchain is installed on the machine where these changes were made.
Everything above was derived by reading the sources listed inline, and was
statically cross-checked: every `CONFIG_OMI_*` referenced in the C sources or in
`CMakeLists.txt` is defined in `firmware/omi/Kconfig`, every `CONFIG_OMI_*` set
in `omi.conf` is defined, and every `DT_NODELABEL` / `DT_ALIAS` used in the
sources resolves against `firmware/boards/omi/omi_nrf5340_cpuapp.dts` or the
nRF5340 SoC DTSI.

Before shipping, verify on hardware: the new `19B10017` characteristic and its
offline queue, the IMU wake-on-motion path out of system off, the immediate
charging notification, and that the removal of the (unused) filesystem stack
from `omi.conf` did not break the SD ring.
