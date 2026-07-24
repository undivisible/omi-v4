# Omi device firmware

Zephyr / nRF Connect SDK firmware for the Omi wearables, vendored from
`BasedHardware/omi`. See [`PROVENANCE.md`](PROVENANCE.md) for what was vendored
and how to re-sync, [`ARCHITECTURE.md`](ARCHITECTURE.md) for how it is put
together and how it differs from upstream, and
[`BLE_CONTRACTS.md`](BLE_CONTRACTS.md) for the app-facing GATT interface.

This tree is excluded from the *root* CI workflow (`.github/workflows/ci.yml`
has `paths-ignore: firmware/**`); it is built by its own workflow,
[`.github/workflows/ci-firmware.yml`](../.github/workflows/ci-firmware.yml),
which runs inside Nordic's prebuilt NCS v3.4.0 toolchain container. See
[Notes for CI](#notes-for-ci).

> **Partially compile-verified.** `omi-cv1` and `evt-test` build clean under
> nRF Connect SDK v3.4.0 (Zephyr 4.4.0). The three `devkit-*` targets do **not**
> build yet — see [Migration status](#migration-status). Before this SDK upgrade
> nothing in this tree had ever been compiled, so several defects fixed during
> the upgrade were pre-existing rather than caused by it.

## Migration status

This tree was migrated from nRF Connect SDK v2.9.0 (Zephyr 3.7) to v3.4.0
(Zephyr 4.4.0). Build state per target:

| Target | v3.4.0 build | Notes |
| --- | --- | --- |
| `omi-cv1` | builds clean | MCUboot slot layout verified unchanged |
| `evt-test` | builds clean | |
| `devkit-v1` | **does not build** | nrfx 3.x PDM API break, plus pre-existing defects |
| `devkit-v1-spisd` | **does not build** | same |
| `devkit-v2-adafruit` | **does not build** | same |

### What the upgrade changed

Partition Manager is deprecated in v3.4.0 and **no longer defaults to on**. It
still works and is still selectable, and it is what pins this product's flash
layout, so `SB_CONFIG_PARTITION_MANAGER=y` is now set explicitly in
`omi/sysbuild.conf` and `test/sysbuild.conf`. Nordic intend to remove Partition
Manager from `main` by the end of 2026; migrating this layout to devicetree is
the next SDK-side task and must preserve the MCUboot slot addresses below.

`boards/omi/pm_static.yml` was renamed to
`boards/omi/pm_static_omi_nrf5340_cpuapp.yml`. In v3.4.0 the unqualified
`pm_static.yml` name is also matched for the **CPUNET** domain, which made the
build apply the application core's SRAM layout to the network core and fail.
Scoping the filename to the `omi/nrf5340/cpuapp` board target restores the
v2.9.0 behaviour: CPUAPP is pinned statically, CPUNET resolves dynamically.

Other required changes:

| Change | Why |
| --- | --- |
| `boards/omi/board.yml` gained `full_name` | now required by the Zephyr board schema |
| `<common/nordic/*.dtsi>` → `<nordic/*.dtsi>` | the shared-SRAM and cpuapp-partition includes moved |
| `disk-name = "SD"` added to the `mmc` node; `CONFIG_SDMMC_VOLUME_NAME` dropped | the SD disk name moved from Kconfig to devicetree |
| `CONFIG_NFCT_PINS_AS_GPIOS` → `nfct-pins-as-gpios` on `&uicr` | moved from Kconfig to devicetree |
| `CONFIG_BT_CTLR=y` and the `BT_CTLR` defconfig override removed | `BT_CTLR` has no prompt in Zephyr 4.x and is selected by the HCI driver |
| `CONFIG_NRFX_PDM0` removed | the per-instance symbol is gone; `AUDIO_DMIC_NRFX_PDM` selects `NRFX_PDM` |
| `CONFIG_BT_BUF_EVT_RX_COUNT=12` added | Zephyr 4.x asserts `BT_BUF_EVT_RX_COUNT > BT_BUF_ACL_TX_COUNT`, and this build sets the latter to 10 |
| `BT_LE_ADV_CONN` → `BT_LE_ADV_CONN_FAST_2` | the old macro was removed; the replacement has identical advertising intervals |

Dead configuration that the older SDK accepted silently and v3.4.0 rejects was
removed: `CONFIG_I2S_NRFX` (no I2S node exists), the `BT_PERIPHERAL_PREF_*`
block in `omi/sysbuild/ipc_radio.conf` (that image is HCI-raw and has no host,
so they never applied — the working copies are in `omi/omi.conf`), and
`CONFIG_NCS_SAMPLE_MCUMGR_BT_OTA_DFU` in `omi/sysbuild/mcuboot.conf` (an
application symbol that has no effect on the bootloader image; the working copy
is in `omi/omi.conf`).

### Pre-existing defects fixed in passing

These were latent because the tree had never been compiled. They are not SDK
migration issues:

- `omi/src/lib/core/transport.c` used `speak()` and the battery API without
  including `speaker.h` or `lib/battery/battery.h`.
- `battery_charging_state_read()` had no prototype in `battery.h`.
- `CONFIG_OMI_CONN_INTERVAL_IDLE_*` and `CONFIG_OMI_CONN_IDLE_LATENCY` depend on
  `OMI_ENABLE_ADAPTIVE_CONN_PARAMS`, which is `n`, but `transport.c` referenced
  them unconditionally.
- `test/app.overlay` and `test/src/imu.c` referenced a `lsm6dso` node label that
  the board does not define (it is `lsm6ds3tr_c`).
- `test/src/mic.c` did not include `mic.h`; `test/src/main.c` did not include
  `shell_uart.h`; `test/src/motor.c` had a `SYS_INIT` function returning `void`.

### Open risk: settings storage moved

**Verify this on hardware before shipping an OTA.** The MCUboot-visible
partitions are byte-identical to the v2.9.0 static layout:

| Partition | Address | Size |
| --- | --- | --- |
| `mcuboot` | `0x0` | `0x10000` |
| `mcuboot_pad` | `0x10000` | `0x200` |
| `mcuboot_primary` | `0x10000` | `0xf0000` |
| `mcuboot_primary_app` | `0x10200` | `0xefe00` |
| `mcuboot_secondary` | external `0x0` | `0xf0000` |
| `mcuboot_secondary_1` | external `0xf0000` | `0x40000` |

so OTA to devices already in the field still works. However, inside the primary
slot Partition Manager now also places `settings_storage` at `0xfc000` (8 KB)
and an `EMPTY_0` filler at `0xfe000`, which shrinks the `app` partition from
`0xefe00` to `0xebe00` (16 KB smaller). The NVS settings backend
(`CONFIG_SETTINGS_NVS`) stores the writable device name (`19B10016`) and RTC
state there. It has not been established where NVS lived under v2.9.0, so a
device upgrading over the air may or may not find its existing settings.
Confirm against a v2.9.0 build's `partitions.yml` before rollout.


## Build targets

| Target id | App directory | Board | SoC | Config file | Extra |
| --- | --- | --- | --- | --- | --- |
| `omi-cv1` | `omi/` | `omi/nrf5340/cpuapp` | nRF5340 | `omi/omi.conf` → `omi/prj.conf` | `--sysbuild`, `BOARD_ROOT` |
| `devkit-v1` | `devkit/` | `xiao_ble/nrf52840/sense` | nRF52840 | `devkit/prj_xiao_ble_sense_devkitv1.conf` | overlay |
| `devkit-v1-spisd` | `devkit/` | `xiao_ble/nrf52840/sense` | nRF52840 | `devkit/prj_xiao_ble_sense_devkitv1-spisd.conf` | overlay |
| `devkit-v2-adafruit` | `devkit/` | `xiao_ble/nrf52840/sense` | nRF52840 | `devkit/prj_xiao_ble_sense_devkitv2-adafruit.conf` | overlay |
| `evt-test` | `test/` | `omi/nrf5340/cpuapp` | nRF5340 | `test/omi.conf` → `test/prj.conf` | `--sysbuild`, `BOARD_ROOT`, bring-up/throughput harness, not a shipping image |

**Board name caveat for the DevKit targets.** The board identifier for the Seeed
XIAO nRF52840 Sense was renamed across Zephyr versions and the vendored files
disagree with each other: `devkit/CMakeLists.txt` sets
`set(BOARD seeed_xiao_nrf52840_sense)` while `devkit/CMakePresets.json` uses
`BOARD: xiao_ble_sense`. Under NCS v3.4.0 (Zephyr 4.4) the
correct identifier is still `xiao_ble/nrf52840/sense`. Pass `-b` explicitly on the
command line — it overrides the `set(BOARD ...)` in `CMakeLists.txt` — and
confirm with `west boards | grep xiao` in your workspace before wiring this into
CI.

## Toolchain

nRF Connect SDK **v3.4.0** (Zephyr 4.4.0), installed through Nordic's toolchain
manager. Do not mix SDK versions between the images in a sysbuild.

```sh
# nrfutil itself
brew install nrfutil            # macOS; or download from nordicsemi.com
nrfutil install toolchain-manager
nrfutil toolchain-manager install --ncs-version v3.4.0   # ~900 MB download, 3.2 GB installed

# host build tools
brew install ninja ccache       # apt: ninja-build ccache
```

One-time west workspace, inside the SDK shell:

```sh
nrfutil toolchain-manager launch --ncs-version v3.4.0 --shell

mkdir -p <workspace>/v3.4.0 && cd <workspace>/v3.4.0
west init -m https://github.com/nrfconnect/sdk-nrf --mr v3.4.0 .
west update          # ~2.9 GB
west zephyr-export
```

`<workspace>` can be anywhere; `firmware/v3.4.0/` is gitignored if you want it
in-tree. Every build command below assumes you are inside the toolchain shell
and inside the west workspace directory.

Let `FW=/absolute/path/to/<repo>/firmware`.

## `omi-cv1` — production nRF5340 pendant

```sh
cp "$FW/omi/omi.conf" "$FW/omi/prj.conf"

west build -b omi/nrf5340/cpuapp "$FW/omi" \
    --sysbuild \
    --build-dir "$FW/omi/build" \
    -- -DBOARD_ROOT="$FW"
```

`prj.conf` is generated (gitignored); Zephyr will not pick up `omi.conf`
directly. Re-run the copy whenever `omi.conf` changes.

`omi.conf` now sets `CONFIG_RUST=y` and `CONFIG_OMI_RUST=y`, so this build links
the `omi-rust` staticlib and requires the out-of-tree `zephyr-lang-rust` module
in the workspace and the `thumbv8m.main-none-eabihf` Rust target. See
[Rust in the firmware](#rust-in-the-firmware) for the one-time setup; without it
the build stops with a `CONFIG_OMI_RUST=y but the zephyr-lang-rust module is not
in the build` error from `omi/rust/CMakeLists.txt`.

`BOARD_ROOT` must point at `firmware/`, because the board definition lives in
`firmware/boards/omi/`. Without it the build fails with
`No board named 'omi' found`.

sysbuild produces four images: MCUboot, the network-core bootloader `b0n`, the
network-core radio image `ipc_radio`, and the application.

Outputs in `omi/build/`:

| File | Use |
| --- | --- |
| `dfu_application.zip` | **OTA package** — this is what the app and nRF Connect for Mobile consume |
| `merged.hex` | Full application-core image for SWD programming |
| `merged_CPUNET.hex` | Network-core image for SWD programming |
| `partitions.yml`, `build_info.yml` | Partition layout and build configuration, useful in release artifacts |

Clean rebuild: `west build -t pristine --build-dir "$FW/omi/build"`, or just
delete the build directory.

### Flashing `omi-cv1`

**OTA (no hardware tools):** copy `dfu_application.zip` to a phone, open nRF
Connect for Mobile, connect to the pendant (advertised name `Omi`), open the DFU
tab, select the zip, upload. Two to five minutes. MCUboot is configured
overwrite-only with downgrade prevention
(`bootloader/mcuboot/mcuboot.conf`), so the image version derived from
`omi/VERSION` must be greater than what is on the device.

**SWD (J-Link / nRF debugger):**

```sh
west flash --build-dir "$FW/omi/build"
```

Images are signed with `bootloader/mcuboot/root-rsa-2048.pem`, which is the key
shipped devices already trust. Do not substitute a different key or OTA will
stop working on existing units.

## `devkit-*` — XIAO nRF52840 Sense

Three configurations off the same `devkit/` application. They differ only in
config file and devicetree overlay:

```sh
# devkit-v1: bare XIAO Sense, onboard PDM mic, no SD
west build -b xiao_ble/nrf52840/sense "$FW/devkit" \
    --build-dir "$FW/devkit/build/devkitv1" \
    -- -DCONF_FILE="$FW/devkit/prj_xiao_ble_sense_devkitv1.conf" \
       -DDTC_OVERLAY_FILE="$FW/devkit/overlay/xiao_ble_sense_devkitv1.overlay"

# devkit-v1-spisd: adds an external SPI SD card module and offline storage
west build -b xiao_ble/nrf52840/sense "$FW/devkit" \
    --build-dir "$FW/devkit/build/devkitv1-spisd" \
    -- -DCONF_FILE="$FW/devkit/prj_xiao_ble_sense_devkitv1-spisd.conf" \
       -DDTC_OVERLAY_FILE="$FW/devkit/overlay/xiao_ble_sense_devkitv1-spisd.overlay"

# devkit-v2-adafruit: Adafruit PDM BFF module, button, battery, USB, haptic, speaker
west build -b xiao_ble/nrf52840/sense "$FW/devkit" \
    --build-dir "$FW/devkit/build/devkitv2-adafruit" \
    -- -DCONF_FILE="$FW/devkit/prj_xiao_ble_sense_devkitv2-adafruit.conf" \
       -DDTC_OVERLAY_FILE="$FW/devkit/overlay/xiao_ble_sense_devkitv2-adafruit.overlay"
```

No `--sysbuild` and no `BOARD_ROOT`: the DevKit uses an in-tree Zephyr board and
the XIAO's own Adafruit UF2 bootloader rather than MCUboot.

`devkit/CMakePresets.json` carries the same three configurations for the nRF
Connect VS Code extension. The presets still name the old board id and are kept
as-is for editor use; the commands above are the authoritative ones.

Outputs in each build directory: `zephyr/zephyr.uf2` (and `zephyr.hex`).

### Flashing `devkit-*`

Double-tap the XIAO's reset button to enter the UF2 bootloader — it mounts as a
mass-storage volume named `XIAO-SENSE` — then copy the `.uf2` onto it:

```sh
cp "$FW/devkit/build/devkitv2-adafruit/zephyr/zephyr.uf2" /Volumes/XIAO-SENSE
```

`devkit/flash.sh` does this for the v2-adafruit build on macOS, but it hardcodes
the upstream build path (`build/build_xiao_ble_sense_devkitv2-adafruit/`); if
you use the `--build-dir` layout above, copy the file by hand.

### DevKit button caveat

The DevKit button is an **external** switch between D4 (driven high as a 3.3 V
source) and D5 (`P0.05`), wired by hand — see `devkit/src/button.c`. There is no
pull resistor configured, so `P0.05` floats on a board with no button attached
and `CONFIG_OMI_ENABLE_BUTTON=y` would produce spurious taps.

Consequently `devkit-v1` and `devkit-v1-spisd` ship with the button disabled,
which also disables the single-tap bookmark, the double-tap assistant trigger,
the BLE sleep command and idle auto-sleep on those two targets.
`devkit-v2-adafruit` enables all of them. If you have wired a button to a v1
board, add to its config file:

```
CONFIG_OMI_ENABLE_BUTTON=y
CONFIG_OMI_ENABLE_BLE_SLEEP_CMD=y
CONFIG_OMI_ENABLE_IDLE_SLEEP=y
```

## `evt-test` — nRF5340 bring-up and BLE throughput harness

Not a shipping image. A Zephyr-shell application for exercising the CV1 board's
peripherals and measuring BLE throughput; see `test/README.md` and
`test/BLE_THROUGHPUT_TEST.md`.

```sh
cp "$FW/test/omi.conf" "$FW/test/prj.conf"

west build -b omi/nrf5340/cpuapp "$FW/test" \
    --sysbuild \
    --build-dir "$FW/test/build" \
    -- -DBOARD_ROOT="$FW"
```

Same board root and sysbuild layout as `omi-cv1`; flash it the same way. Its
shell is on UART and on BLE NUS, and it advertises as `Omi EVT`.

## Firmware versions

Each application derives its DIS firmware-revision string (`0x2A26`) from a
Zephyr `VERSION` file at build time; there is no hand-maintained literal:

| Target | Version file | Current |
| --- | --- | --- |
| `omi-cv1` | `omi/VERSION` | 3.1.0 |
| `devkit-*` | `devkit/VERSION` | 1.1.0 |

`CMakeLists.txt` parses the file before `find_package(Zephyr)` and writes a
generated Kconfig fragment that overrides `CONFIG_BT_DIS_FW_REV_STR`. Bump the
`VERSION` file to cut a release. The `.conf` files still contain
`CONFIG_BT_DIS_FW_REV_STR="0.0.0+unset"` as a sentinel: if a device ever reports
that string, the generated fragment was not applied.

The same `VERSION` file feeds imgtool's image version on `omi-cv1`, which is
what MCUboot's downgrade prevention compares.

## Rust in the firmware

`omi-cv1` builds and links the `omi-rust` static library. **`CONFIG_OMI_RUST`
defaults `y`**, and the `omi-cv1` CI and release builds always link `omi-rust` —
it is no longer an opt-in dual path. `omi/rust/` is where the firmware's pure
logic lives: tx ring/GATT framing, battery SoC/EMA math, IMU register packing
and gesture classify, button tap FSM, haptic BLE→duration map, LED pulse-width
math, and feedback error-pattern tables. C keeps the Zephyr I/O — GPIO, I2C,
BLE, PWM, threads and `k_msleep` timing — and calls into these helpers. `main()`
runs `omi_rust_selftest()` at boot.

### Why an out-of-tree module is needed

`CONFIG_RUST` exists in Zephyr 4.4.0 only as a Kconfig stub: the build backing
it lives in `zephyrproject-rtos/zephyr-lang-rust`, a standalone repository that
is in neither the NCS nor the upstream Zephyr west manifest. Without that module
in the workspace, `CONFIG_RUST=y` does nothing.

[`west-rust.yml`](west-rust.yml) adds it to an existing workspace at the pinned
revision, importing the NCS manifest unchanged so no other project moves:

```sh
cp "$FW/west-rust.yml" <workspace>/nrf/west-rust.yml
cd <workspace>
west config manifest.file west-rust.yml
west update zephyr-lang-rust
```

Reverse it with `west config manifest.file west.yml`. CI does not mutate a
workspace: `.github/workflows/ci-firmware.yml` clones the same pinned revision
into `modules/lang/rust` directly, which is the same layout.

### Building it

Rust links into the standard `omi-cv1` build above — there is no separate
Rust-enabled variant. Two prerequisites make that build succeed.

The nRF5340 application core builds with `CONFIG_FP_HARDABI`, so the Rust target
is **`thumbv8m.main-none-eabihf`**, not the `thumbv8m.main-none-eabi` a plain
Cortex-M33 would use. The build tells you which one it wants if you get it
wrong:

```sh
rustup target add thumbv8m.main-none-eabihf
```

And the zephyr-lang-rust module must be in the workspace (above): without it
`CONFIG_RUST` is an inert Kconfig stub and the link fails.

After the `omi-cv1` build, confirm `omi-rust` actually reached the image rather
than being garbage-collected:

```sh
arm-zephyr-eabi-nm "$FW/omi/build/omi/zephyr/zephyr.elf" | grep omi_rust_selftest
```

`omi/rust/CMakeLists.txt` deliberately does **not** call zephyr-lang-rust's
`rust_cargo_application()`: that helper injects the module's own `main.c` and
takes over `main()`, which would displace `omi/src/main.c`. It reuses the
module's target mapping and cargo integration and links the staticlib into the
existing `app` target instead.

### Known blocker: the `zephyr` bindings crate

`omi/rust/Cargo.toml` has **no dependency on the `zephyr` crate**, on purpose.
With `CONFIG_FLASH=y` — which `omi-cv1` sets — that crate's generated
`devicetree.rs` fails to compile for this board:

```
error[E0425]: cannot find function `get_instance_raw` in module `super::super::super`
   --> .../build/zephyr-*/out/devicetree.rs
    |    let device = super::super::super::get_instance_raw();
```

The generated `get_instance()` for a `fixed-partitions` child assumes the
partition's grandparent is a flash device with bindings. On the nRF5340 the
chain is `nordic_ram_flash_controller_0` → `flash_sim_0` → `partitions` →
`partition_0`, and the grandparent is a `zephyr,sim-flash` node with no
generated accessor. It is a codegen bug in the module, not in this tree, and it
does not appear with `CONFIG_FLASH=n` (which is why the module's own
`hello_world` sample builds for `omi/nrf5340/cpuapp`).

Nothing in `omi/rust/` needs Zephyr bindings, so the crate builds against `core`
with its own `#[panic_handler]` forwarding to Zephyr's `k_panic()`. Restoring
the dependency is a one-line change to `Cargo.toml` once the codegen is fixed
upstream — until then, do not add it, because it breaks `omi-cv1`.

### Where this is going

`omi/rust/src/framing.rs` is the seed for the tx path in
`omi/src/lib/core/transport.c` — `write_to_tx_queue`, `read_from_tx_queue` and
`push_to_gatt` are pure logic over a 2-byte little-endian ring-buffer length
header and the 3-byte wire header (`id` little-endian `u16`, then `index`). The
crate is host-testable (`cd omi/rust && cargo test`) precisely so it can later
be shared with `app/native/hub` and stop the two ends of the wire format from
drifting. That migration is **not** part of this change.

## Formatting

`firmware/.clang-format` applies to the C sources in `omi/`, `devkit/` and
`test/` (excluding the vendored Opus tree):

```sh
clang-format -i firmware/omi/src/**/*.c firmware/omi/src/**/*.h
```

## Notes for CI

- Every target above needs the NCS v3.4.0 toolchain and a populated west
  workspace; budget for caching `~/.cache/zephyr` and the west modules.
- `omi-cv1` and `evt-test` need `-DBOARD_ROOT` pointing at `firmware/`.
- `omi-cv1` and `evt-test` need the `omi.conf` → `prj.conf` copy step.
- The `devkit-*` targets need `-DCONF_FILE` and `-DDTC_OVERLAY_FILE`; they have
  no `prj.conf` step.
- Release artifacts worth publishing per target: `dfu_application.zip`,
  `merged.hex`, `merged_CPUNET.hex`, `partitions.yml` for the nRF5340 targets;
  `zephyr.uf2` and `zephyr.hex` for the DevKit targets.
- The signing key `bootloader/mcuboot/root-rsa-2048.pem` is in-tree and must be
  used as-is for the nRF5340 targets.
- `.github/workflows/ci-firmware.yml` (per-push, path-filtered to `firmware/**`)
  and `.github/workflows/release-firmware.yml` (per-tag) both build their matrix
  by parsing the `west build` commands above with
  `.github/scripts/discover_firmware_targets.py`, including the `cp … prj.conf`
  line that precedes them. `$FW` is resolved to `firmware/` in the checkout.
  Keep each target's command a single fenced block under its own heading, and
  re-run `python3 .github/scripts/discover_firmware_targets.py --print-only`
  after editing this file — it fails if any path it derives is missing from the
  tree. A fenced block carrying the marker `discover-ignore` is skipped, so
  example or variant commands can live here without becoming CI legs. The
  `omi-cv1` leg links `omi-rust` as part of its standard build, so there is no
  separate Rust leg in the matrix.
- **The [Migration status](#migration-status) table is the CI gate.** The
  discovery script reads it and emits `required=false` for any target whose
  `v3.4.0 build` cell says *does not build*; both workflows mark those legs
  `continue-on-error`. Editing that cell is all it takes to make a target
  gating — there is no second list to update.
- Neither workflow installs the toolchain by hand. Both run inside
  `ghcr.io/nrfconnect/sdk-nrf-toolchain:v3.4.0`, which already carries the
  Zephyr SDK, so the ~900 MB `nrfutil toolchain-manager` download and its ~3 GB
  install never happen on a runner. What is expensive is `west update`
  (~2.9 GB); `ci-firmware.yml` populates it in one `workspace` job, caches
  `/opt/ncs` under a key derived from `NCS_VERSION` and the pinned
  zephyr-lang-rust revision, and every build leg restores it with
  `fail-on-cache-miss`. Bumping either version invalidates the cache.
