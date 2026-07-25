# Firmware Rust migration goal

**End state:** Every pure-logic path lives in `firmware/omi/rust/` (`omi-rust`).
C under `firmware/omi/src/` is only Zephyr/driver glue: GPIO interrupts, I2C, SPI, PWM,
BLE GATT, threads, work queues, `k_msleep`, disk/`ring_buf`, and `main()`
orchestration that calls Rust.

**Still C:** BLE GATT/stack, Opus codec, PDM/DMIC driver + AAD bitbang timing,
SAADC, I2C IMU register traffic, SD/MMC disk worker, PWM LEDs, settings NVS,
charge-detect ISR, and `main()` control flow. Thin GPIO shells
(`bat_read`, `sdcard_en`, `rfsw_en`, `pdm_en`, haptic motor) and RTC soft-clock
state live in Rust via the zephyr crate.

**Done when:**
1. No duplicated pure math/protocol remains in C `#else` or static helpers that
   only pack bytes / clamp / classify / FSM-step.
2. `cd firmware/omi/rust && cargo test` is green.
3. `omi-cv1` links Rust (`CONFIG_RUST=y` / `CONFIG_OMI_RUST=y`) and boot
   `omi_rust_selftest()` returns 0.
4. This file’s checklist below is empty of open pure-logic items.

## Pure-logic checklist

- [x] Framing ring/GATT headers + audio ATT chunk size
- [x] Battery SoC lookup + EMA + median/divider + percentage filter state
- [x] IMU gesture classify + register packing
- [x] Button tap FSM
- [x] Haptic BLE→ms map + clamp + motor GPIO (`GpioPin`)
- [x] LED pulse-width math
- [x] Feedback error patterns
- [x] Storage BLE sync wire format (parse + ACK/DONE/INFO/DATA/READ_BEGIN)
- [x] Storage BLE transfer orchestration state
- [x] SD ring validation + seq/sector math + timestamp names
- [x] User-event payload encode
- [x] RTC extrapolate + soft-clock state/mutex/uptime + IMU boot time delta
- [x] Mic stereo→mono + avg amplitude + PDM gain map
- [x] Settings dim/gain clamps + legacy time-base blob
- [x] Offline SD Opus packer FSM
- [x] Features GATT bitmask assemble
- [x] Transport user-event queue ownership (Rust `Queue<16>`; C mutex+GATT)
- [x] Transport adaptive-connection and charging-notification policy state
- [x] GPIO shells: `bat_read`, `sdcard_en`, `rfsw_en`, `pdm_en` (zephyr `GpioPin`)
- [ ] Any remaining byte-packing helpers found in future audits
- [ ] BLE / Opus / PDM / ADC / I2C / SD worker / PWM / `main` — still C
