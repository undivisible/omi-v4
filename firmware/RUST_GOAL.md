# Firmware Rust migration goal

**End state:** Every pure-logic path lives in `firmware/omi/rust/` (`omi-rust`).
C under `firmware/omi/src/` is only Zephyr/driver glue: GPIO, I2C, SPI, PWM,
BLE GATT, threads, work queues, `k_msleep`, disk/`ring_buf`, and `main()`
orchestration that calls Rust.

**Still C:** BLE GATT/stack, Opus codec, PDM mic, ADC, I2C, SD storage, and
`main()` control flow. Haptic motor GPIO is in Rust; delayable off work and
haptic BLE GATT stay in C.

**Done when:**
1. No duplicated pure math/protocol remains in C `#else` or static helpers that
   only pack bytes / clamp / classify / FSM-step.
2. `cd firmware/omi/rust && cargo test` is green.
3. `omi-cv1` links Rust (`CONFIG_RUST=y` / `CONFIG_OMI_RUST=y`) and boot
   `omi_rust_selftest()` returns 0.
4. This file’s checklist below is empty of open pure-logic items.

## Pure-logic checklist

- [x] Framing ring/GATT headers + audio ATT chunk size
- [x] Battery SoC lookup + EMA
- [x] IMU gesture classify + register packing
- [x] Button tap FSM
- [x] Haptic BLE→ms map + clamp + motor GPIO (`GpioPin`)
- [x] LED pulse-width math
- [x] Feedback error patterns
- [x] Storage BLE sync wire format (parse + ACK/DONE/INFO/DATA/READ_BEGIN)
- [x] User-event payload encode
- [x] RTC extrapolate + IMU boot time delta
- [x] Mic stereo→mono + avg amplitude
- [x] Settings dim/gain clamps + legacy time-base blob
- [x] Offline SD Opus packer FSM
- [x] Features GATT bitmask assemble
- [x] Transport user-event queue ownership (Rust `Queue<16>`; C mutex+GATT)
- [ ] Any remaining byte-packing helpers found in future audits
- [ ] BLE / Opus / PDM / ADC / I2C / SD / `main` control flow — still C
