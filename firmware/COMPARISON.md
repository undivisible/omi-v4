# The vendored firmware compared with upstream Omi

*This document owns every comparison between `firmware/` and the upstream
`BasedHardware/omi` firmware tree. [`ARCHITECTURE.md`](ARCHITECTURE.md) describes
how this firmware is built and makes no comparative claims;
[`PROVENANCE.md`](PROVENANCE.md) records the mechanics of the vendoring and how
to re-sync; [`README.md`](README.md) is the build and flash guide;
[`BLE_CONTRACTS.md`](BLE_CONTRACTS.md) is the app-facing GATT interface. This is
the firmware counterpart to the root [`COMPARISON.md`](../COMPARISON.md), which
compares the app and backend.*

*Method and limits: "upstream" means the `BasedHardware/omi` checkout at
`~/projects/omi`, subtree `omi/firmware/`, at commit
`ed4e513e64702b33fa088f1a0f58fc60e1935976` on branch `firmware/idle-auto-sleep`
— the exact commit this tree was vendored from. Every file-level claim below was
produced by extracting that subtree and diffing it against `firmware/`. Nothing
here has been measured. **Nothing in this tree has been run on hardware**, and
only two of its five build targets have ever been compiled; see §6.*

*Unlike the app and backend, this is a genuine inheritance. The C sources are
upstream's, and the majority of them are byte-identical. What follows is an
account of a copy that has since been edited, not of an independent
implementation.*

---

## 1. What was vendored, and why that branch

Upstream's firmware directory covers three applications and their shared board
support. All three were taken:

| Path here | Upstream path | What it is |
| --- | --- | --- |
| `omi/` | `omi/firmware/omi/` | Production nRF5340 CV1 pendant application |
| `devkit/` | `omi/firmware/devkit/` | Seeed XIAO nRF52840 Sense DevKit application, three configurations |
| `test/` | `omi/firmware/test/` | CV1 bring-up and BLE-throughput harness |
| `boards/omi/` | `omi/firmware/boards/omi/` | Out-of-tree nRF5340 board definition |
| `bootloader/mcuboot/` | `omi/firmware/bootloader/mcuboot/` | MCUboot fragment and the image signing key |
| `.clang-format`, `BUILD_AND_OTA_FLASH.md` | same | Formatting rules; upstream's build guide, kept verbatim as reference |

**`firmware/idle-auto-sleep` was vendored rather than `main`** because that
branch already carried the work the app needs: idle auto-sleep, the BLE sleep
command (`19B10014`), the capture-state LED and characteristic (`19B10015`), the
writable persisted device name (`19B10016`), the battery-low LED, and DIS
firmware/hardware revision reporting. Taking `main` would have meant
re-implementing all of it. The cost of that choice is stated in §5: the branch is
not upstream's integration point, so it may be rebased, abandoned, or merged in a
form that does not match what is here.

Not a submodule. `PROVENANCE.md` records the reasoning: a flat copy, because the
tree is edited here and a submodule pin cannot represent that.

## 2. Where the trees are byte-identical

Of the 585 files in the five vendored subtrees, **523 are byte-identical to
upstream**, 43 differ, and 19 were deliberately not taken (§4.3).

The identical set is not incidental — it is most of the firmware:

- **The entire vendored Opus 1.2.1 tree** (209 files under
  `omi/src/lib/core/lib/opus-1.2.1/`) is untouched. The codec configuration in
  `codec.c` is also unchanged: 16 kHz mono, 20 ms frames, 32 kbps unconstrained
  VBR, `OPUS_APPLICATION_RESTRICTED_LOWDELAY`, DTX off. The wire format the app
  decodes is upstream's, exactly.
- **`omi/src/lib/core/storage.c`'s offline-sync protocol** — the raw sector ring,
  the `RING_INFO` / `RING_READ` / `RING_ADVANCE` / `RING_CLEAR` opcode set, the
  read-pointer checkpointing — is upstream's design and upstream's logic. Two
  behavioural fixes were applied (§3.2) and the file is documented in
  `BLE_CONTRACTS.md` §7, but the protocol is not ours.
- **The GATT service and characteristic layout** is upstream's. Every UUID in
  `BLE_CONTRACTS.md` except `19B10017` (§3.1) comes from upstream.
- **`bootloader/mcuboot/root-rsa-2048.pem`** is byte-identical and must stay that
  way: it is the key MCUboot on shipped pendants already trusts. An image signed
  with any other key is rejected, so re-signing would break OTA on every device
  in the field.
- **The DevKit's `mic.c`, `storage.c`, `sdcard.c`, `usb.c`** and most of its
  build configuration are untouched, which is why DevKit changes can still be
  taken from upstream almost verbatim (§5).

## 3. Where we diverge

`git log -- firmware/` is the authoritative set; the initial vendoring commit is
pristine minus the §4.3 exclusions and everything after it is local. The 43
differing files fall into five groups.

### 3.1 New capability

**A timestamped user-event characteristic (`19B10017`) — CV1 and DevKit.**
Upstream's button reporting is the legacy service `23BA7925`: an 8-byte `int[2]`
carrying an event code and nothing else — no timestamp, no sequence number, and
no delivery at all if the app is not connected at that instant. Its `LONG_TAP`
and `BUTTON_PRESS` codes are defined but never emitted.

Ours adds a new characteristic in the settings service carrying code, source, a
16-bit sequence number, and a UTC timestamp from the RTC the device already
keeps. Single tap is defined as bookmark (`0x01`), double tap as assistant
trigger (`0x02`), and long press still powers the device off but emits
`POWER_OFF` (`0x03`) first, so an app sees an intentional shutdown rather than an
unexplained disconnect. Events raised while disconnected are held in a 16-deep
ring and flushed in order on subscribe. The legacy service is untouched, so
existing app builds keep working. *The queue is RAM only: a tap survives a
reconnect but not a reboot.*

**IMU wake-on-motion and gestures — CV1 only.** Upstream uses the LSM6DS3TR-C
solely as a timekeeping counter across system off; its `accel.c` streaming
service is not listed in `omi/CMakeLists.txt` and has therefore never built. Ours
adds `omi/src/imu_gesture.c`, which programs the IMU's embedded activity
detector, routes it latched to INT1 (already declared as `irq-gpios` in the board
DTS), and re-arms it as a level interrupt before `sys_poweroff()` so the GPIO
SENSE block wakes the SoC. The pendant can come back from idle auto-sleep on
movement alone, motion resets the idle timer while running, and double-tap
(`0x21`) is implemented but off by default because its thresholds are
datasheet-plausible guesses rather than measured values.

**Hardware AAD tuning exposed as configuration — CV1 only.** Upstream's T5838
acoustic-activity path already existed and already worked, with the mode-A
bandwidth and threshold as hard-coded constants. Ours makes them
`CONFIG_OMI_AAD_A_LPF` and `CONFIG_OMI_AAD_A_THRESHOLD` with the original values
as defaults, so wake sensitivity is retunable without patching the driver, and
emits user events `0x10`/`0x11` on AAD transitions so the app can distinguish
"silent" from "gone". The capture LED no longer shows blue during AAD sleep,
where the app is subscribed but no audio is flowing.

**Build-derived firmware version.** Upstream's `CONFIG_BT_DIS_FW_REV_STR` is a
hand-maintained literal — `"3.0.20"` on CV1 and three divergent strings across
the DevKit configurations. Ours is a Zephyr `VERSION` file per application,
parsed before `find_package(Zephyr)` into a generated Kconfig fragment; the
`.conf` files keep `"0.0.0+unset"` as a loud sentinel. On CV1 the same file feeds
imgtool's image version, which is what MCUboot's downgrade prevention actually
compares. The DIS `0x2A26` contract is unchanged.

**A required Rust static library — no upstream counterpart.** Upstream is C only.
`omi/rust/` builds `omi-rust` and links it into the existing `app` target;
**`CONFIG_OMI_RUST` defaults `y`**, so the `omi-cv1` CI and release images link
it rather than treating it as an opt-in dual path. `west-rust.yml` pins
`zephyr-lang-rust` at a fixed revision because `CONFIG_RUST` in Zephyr 4.4.0 is a
Kconfig stub without that out-of-tree module, and that module is required in the
workspace. `omi/rust/` is where the firmware's pure logic lives — framing,
battery SoC/EMA, IMU gesture/register packing, button tap FSM, haptic duration
map, LED pulse math, feedback error patterns — plus a boot-time self-test, linked
into a real image and verifiable with `nm … | grep omi_rust_selftest` on the
built ELF. C keeps the Zephyr I/O (GPIO, I2C, BLE, PWM, threads). It still has
**no** dependency on the `zephyr` bindings crate, because with `CONFIG_FLASH=y`
that crate's generated `devicetree.rs` does not compile for this board, so it
builds against `core`. Its purpose is to prove the toolchain path before
`transport.c`'s tx logic moves over, and to give the wire format a host-testable
home that `app/native/hub` could later share.

**Firmware CI.** Upstream carries `omi/firmware/scripts/ci/` — shell scripts
(`build-cv1.sh`, `make-release-body.sh`) with no workflow in the firmware tree
that invokes them. This tree has `.github/workflows/ci-firmware.yml` (per push,
path-filtered to `firmware/**`) and `.github/workflows/release-firmware.yml` (per
tag), both running inside `ghcr.io/nrfconnect/sdk-nrf-toolchain:v3.4.0` and both
deriving their build matrix by parsing the fenced `west build` blocks in
`README.md` with `.github/scripts/discover_firmware_targets.py`. The *Migration
status* table in `README.md` is the gate: a target whose build cell says "does
not build" is emitted as `continue-on-error`, so making a target gating is a one
cell edit with no second list to update.

### 3.2 Reliability fixes

Four upstream defects were found by reading and fixed. None was reported
upstream.

- **`send_ring_info_response()` dropped the reply on `-ENOMEM`.** The app issues
  `RING_INFO` once per sync, so a single transiently missing TX buffer stalled
  the whole offline sync. It now retries within the existing 5 s deadline.
- **`push_to_gatt()` sized audio notifications as `ATT_MTU` when the maximum
  payload is `ATT_MTU − 3`.** Harmless above MTU 163 because a codec frame is at
  most 160 bytes, but between the MTU floor of 100 and 163 every notification
  would be rejected and dropped after three retries.
- **The charging characteristic (`19B10013`) notified only on the 5-second
  battery work item**, so the app mirrored the charging LED up to five seconds
  late. Worse, `notify_charging_status()` and its state were compiled only under
  `CONFIG_OMI_ENABLE_BATTERY` while being called unconditionally from the CCC
  handler. Both symbols moved out of the battery-only block and the
  `bat_chg_pin` interrupt now schedules an immediate deduplicated notification.
  The 1-byte payload is unchanged.
- **The DevKit SPI-SD configuration silently had no offline storage.**
  `prj_xiao_ble_sense_devkitv1-spisd.conf` set `CONFIG_OMI_OFFLINE_STORAGE=y`,
  but the symbol declared in `devkit/Kconfig` is `OMI_ENABLE_OFFLINE_STORAGE`.
  The entire point of that configuration was compiled out.

A further set of latent defects — missing includes, a missing prototype, an
unconditional reference to symbols behind a disabled Kconfig, a `SYS_INIT`
function returning `void`, `lsm6dso` node labels the board never defined — were
fixed during the SDK migration. They were pre-existing rather than caused by it:
the tree had never been compiled. `README.md`'s *Pre-existing defects fixed in
passing* has the list.

### 3.3 The SDK migration — the largest divergence, and one-way

**Upstream builds against nRF Connect SDK v2.9.0 (Zephyr 3.7). This tree was
migrated to v3.4.0 (Zephyr 4.4.0).** This is the divergence that changes the
relationship with upstream, because every future upstream change to a migrated
file must now be ported by hand rather than merged.

The migrated set is enumerated file-by-file in `PROVENANCE.md` and the reasons
are in `README.md`'s *Migration status*. In outline: Partition Manager no longer
defaults on and is now selected explicitly; `boards/omi/pm_static.yml` was renamed
to `pm_static_omi_nrf5340_cpuapp.yml` because the unqualified name is also matched
for the CPUNET domain in v3.4.0, which made the build apply the application core's
SRAM layout to the network core; devicetree include prefixes moved; the SD disk
name and the NFC-pins-as-GPIO setting moved from Kconfig to devicetree;
`BT_CTLR` lost its prompt; `BT_LE_ADV_CONN` was removed in favour of
`BT_LE_ADV_CONN_FAST_2` (identical intervals).

Build state after the migration:

| Target | Upstream (v2.9.0) | Here (v3.4.0) |
| --- | --- | --- |
| `omi-cv1` | not verified — the tree had never been compiled | **builds clean** |
| `evt-test` | not verified | **builds clean** |
| `devkit-v1` | not verified | **does not build** — `mic.c` needs porting to the nrfx 3.x PDM API |
| `devkit-v1-spisd` | not verified | **does not build** — same |
| `devkit-v2-adafruit` | not verified | **does not build** — same |

The DevKit targets are behind, not broken by intent. Until they are ported,
DevKit changes can still be taken from upstream almost verbatim, which is a small
consolation for the CV1 divergence.

### 3.4 The Kconfig lean pass

Upstream's `omi/omi.conf` accumulated configuration that the sources do not use.
Every removal was justified against the code:

- **`CONFIG_FILE_SYSTEM` and `CONFIG_FILE_SYSTEM_LITTLEFS`** — the largest. The
  CV1 SD path uses raw `disk_access_*` and there is not one `fs_*` call anywhere
  under `omi/src/`. The whole VFS and LittleFS stack was dead flash and RAM.
- `CONFIG_ADC_ASYNC` (only `adc_read()` is used), `CONFIG_POSIX_CLOCK` (unused),
  `CONFIG_NORDIC_QSPI_NOR` (no `nordic,qspi-nor` node exists),
  `CONFIG_CBPRINTF_FP_SUPPORT` (after converting the only two `%f` log lines to
  integer arithmetic), `CONFIG_INIT_STACKS` (a debug aid), an inert
  `CONFIG_BT_CTLR_*` block, a `CONFIG_I2C=n` that contradicted a `CONFIG_I2C=y`
  earlier in the same file, and sixteen duplicate assignments.

Deliberately left alone: `CONFIG_HEAP_MEM_POOL_SIZE=40000` (no way to measure the
BT/SD demand without hardware), `CONFIG_BT_SMP`, the BLE buffer sizes, and
`CONFIG_SERIAL`/`CONFIG_CONSOLE` (the production line parses `BLE_ADDR` from
UART).

Alongside it, connection parameters that were literals in upstream's
`transport.c` became `CONFIG_OMI_CONN_INTERVAL_FAST_MIN/MAX` and
`CONFIG_OMI_CONN_SUPERVISION_TIMEOUT`, and `CONFIG_BT_PERIPHERAL_PREF_TIMEOUT`
was aligned to the value the code actually requests (upstream advertised 6 s and
requested something else). `CONFIG_BT_CTLR_PHY_2M=y` moved to
`omi/sysbuild/ipc_radio.conf`, where controller symbols take effect, and
`CONFIG_BT_CTLR_PHY_CODED` was turned off there because nothing requests coded
PHY. A new `CONFIG_OMI_ENABLE_ADAPTIVE_CONN_PARAMS` relaxes the link when audio
is unsubscribed; **it defaults to off**, because an earlier attempt to force slow
parameters from the AAD sleep path caused dropped connections on some phones.

None of this has been measured. The claim is "these symbols are not referenced by
any source file in this tree", which is checkable; the claim is *not* that the
image is measurably smaller or that the device measurably lasts longer.

### 3.5 The DevKit port

The feature work above is CV1-first, and the DevKit gets the portable subset
through a new `devkit/src/omi_ext.c` rather than by duplicating CV1 code. What
crossed and what did not, and why:

| Feature | DevKit | Why |
| --- | --- | --- |
| User events `19B10017`, bookmark/assistant/power-off | ported | Portable; needs `CONFIG_OMI_ENABLE_BUTTON`, which is off on the two v1 configurations because the DevKit button is an external switch the user wires by hand and the pin floats without it |
| Hardware AAD VAD | **not ported, and not faked** | The XIAO Sense onboard PDM mic and the Adafruit PDM BFF have no acoustic activity detector. `CONFIG_OMI_ENABLE_SW_VAD_GATE` (default off) is an explicitly labelled software gate that suppresses the codec, BLE and SD writes during silence but leaves the mic and PDM peripheral running — a fraction of the CV1 saving, and its Kconfig help says so |
| IMU wake and gestures | not ported | The DevKit configurations set `CONFIG_LSM6DSL_TRIGGER_GLOBAL_THREAD=y`, so Zephyr's driver owns INT1 while this implementation needs to own it directly. Needs hardware in hand |
| Charging state | v2-adafruit only | The DevKit's only charge signal is VBUS detect in `usb.c`; without `CONFIG_OMI_ENABLE_USB` the characteristic would report a constant 0 |
| Build-derived version | ported | |

The DevKit also keeps a volatile clock: it holds the epoch in RAM as base plus
`k_uptime_get()`, because no DevKit configuration enables `CONFIG_SETTINGS`/NVS.
Timestamps are correct while it runs and zero after a reboot until the app writes
`19B10031` again. Upstream has the same limitation.

## 4. What upstream has that we do not

### 4.1 The OmiGlass ESP32 OTA command set

Upstream's `omiGlass/firmware` is a **Seeed XIAO ESP32-S3 Sense** application —
`platform = espressif32`, `framework = arduino`, a `firmware.ino` over
`src/{app,mic,opus_encoder,ota}.cpp` with camera pin headers and
`partitions_ota.csv`. Its `src/ota.cpp` implements a BLE-driven, Wi-Fi-fetched
OTA that has no counterpart anywhere in this tree:

| | |
| --- | --- |
| Service | `19B10010-E8F2-537E-4F6C-D104768A1214` |
| Control (write, read status) | `19B10011-…` |
| Data (notify progress) | `19B10012-…` |
| Commands | `0x01` set Wi-Fi credentials, `0x02` start OTA from a URL, `0x03` cancel, `0x04` get status, `0x05` set firmware URL |
| Status codes | idle `0x00`; Wi-Fi connecting/connected/failed `0x10`/`0x11`/`0x12`; downloading/complete/failed `0x20`/`0x21`/`0x22` (download and install carry a progress byte); installing/complete/failed `0x30`/`0x31`/`0x32`; rebooting `0x40`; error `0xFF` |

Note the collision: those UUIDs are in the same `19B100xx` space the pendant uses
for its settings service, where `19B10011` is the LED dim ratio and `19B10012`
the mic gain. **The two profiles are not compatible and must not be assumed
shared.** An app that discovers `19B10011` must decide from the device identity
which product it is talking to.

We do not have this because we do not have the glasses. The reasoning for not
vendoring the glasses firmware is in `ARCHITECTURE.md` §2.1 and `PROVENANCE.md`:
nothing in this Zephyr tree ports to an ESP32 Arduino sketch, it shares no BLE
contract with the pendants, it would add a second toolchain to CI, upstream
commits a `.pio/libdeps/` build cache of third-party libraries, and the
OpenGlass-versus-omiGlass question of which repository is current is unresolved.

The *pattern* is worth noting independently of the hardware: a device that fetches
its own image over Wi-Fi, driven by a small BLE control channel, is exactly the
shape `ARCHITECTURE.md` §5.1 sketches for an nRF7002 bulk-sync path on the CV1.
The CV1's OTA is Zephyr SMP-over-BLE — the phone pushes the whole image over the
link — and stays that way here.

### 4.2 Bootloader and recovery artifacts

Upstream ships prebuilt binaries this tree does not carry:

| Upstream path | What | Why not taken |
| --- | --- | --- |
| `bootloader/bootloader0.9.0.uf2` | XIAO nRF52840 Adafruit UF2 bootloader (69 KB) | For the DevKit's nRF52840, not the nRF5340. A DevKit that has lost its bootloader cannot be recovered from this tree |
| `bootloader/deprecated/` | Two older XIAO bootloader images plus a SoftDevice `.hex` (≈1 MB) | Older revisions of the same |
| `bootloader/mcuboot/enc-rsa2048-{priv,pub}.pem` | MCUboot image **encryption** keys | Encryption is enabled nowhere in this tree — no `SB_CONFIG_BOOT_ENCRYPTION`, no reference in any `.conf`. Carrying a private key for a feature nobody uses is a liability, not a capability. Enabling encryption later requires fetching them |
| `FLASH_3.0.8/` | ≈40 MB of prebuilt `.hex` images and Windows `.exe` flashing tools for a 2024-era release | Superseded by building from source. A device that will only accept a 3.0.8 image cannot be served from this tree |

The consequence is worth stating plainly: **this tree can build firmware but
cannot restore a bricked bootloader or reproduce a historical release.** Both
require going back to upstream.

### 4.3 Upstream scripts and other excluded files

`omi/firmware/scripts/` is not vendored. It contains:

- `build.sh` (a three-line `west build` plus a UF2 copy to `/Volumes/XIAO-SENSE`,
  superseded by `README.md`'s per-target commands), `build-docker.sh`,
  `build-firmware-in-docker.sh`, `docker-build.md` — a container build path
  replaced here by CI running in Nordic's own toolchain image.
- `monitor_device.sh`.
- `ci/` — `build-cv1.sh` and `make-release-body.sh`, with no workflow in the
  firmware tree that calls them. Replaced by §3.1's workflows.
- `devkit/` — a substantial Python host-side toolkit: `client.py`,
  `local_client.py`, `local_laptop_client.py`, `storage.py`,
  `discover_devices.py`, `get_audio_file.py`, `get_info_list.py`,
  `decode_audio.py`, `delete_audio_files.py`, `play_sound_on_friend.py`, plus an
  `OmiSimulator`, button/SD-card test fixtures and recorded captures.

**That Python toolkit is the most substantive omission.** It is a working
host-side implementation of the offline-storage sync protocol and a device
simulator, and nothing here replaces it: `BLE_CONTRACTS.md` §7 documents the
protocol but the only client that speaks it is the Flutter app. If the offline
sync path needs bringing up on real hardware, `scripts/devkit/storage.py` is the
first thing to go back for.

Also not taken: `omi/firmware/omi/src/lib/evt/` (19 files — an EVT-hardware
bring-up variant that `omi/CMakeLists.txt` does not reference, so it has never
compiled into any image), `AGENTS.md` (upstream's own agent instructions),
`readme.md` (superseded by ours), and everything outside `omi/firmware/`.

### 4.4 What upstream simply has more of

Upstream's firmware directory is one part of a monorepo that also contains an
app, a Python backend, SDKs, a plugin ecosystem, MCP servers, a web surface and
OpenTofu infrastructure. None of that is in scope for a firmware tree, and its
absence here is not a gap. The genuine firmware-side gaps are the four in §4.1
and §4.2.

## 5. The maintenance cost of the vendoring relationship

This is a flat copy of a moving upstream, edited in place. The cost is real and
worth naming precisely.

**The re-sync is a manual three-way merge, not a pull.** `PROVENANCE.md` §*How to
re-sync* is the procedure: export the same subtree at a new SHA, `diff -ru`
against this tree, and take the upstream side selectively. Step 3 will produce a
large diff on every file in the SDK-migration table (§3.3) *whether or not
upstream changed them*, because the same file has been edited here for a newer
SDK. Those hunks are deliberate and must not be taken.

**The branch is not upstream's integration point.** `firmware/idle-auto-sleep`
is a feature branch. It may be rebased, force-pushed, merged into `main` in a
squashed or altered form, or abandoned. The pinned SHA remains fetchable while it
is referenced, but "diff against the branch tip" may one day mean diffing against
something that never becomes upstream's history. Verify with
`git -C ~/projects/omi log --oneline firmware/idle-auto-sleep -5` before
re-syncing, and if the branch is gone, the merge base has to be reconstructed
from `main`.

**The SDK divergence is one-way and does not close.** Upstream would have to
migrate to NCS v3.4.0 for the two trees to converge, and nothing suggests it
will. Until then every upstream change to a board file, a sysbuild fragment, or a
`.conf` is a hand port. Nordic intend to remove Partition Manager from `main` by
the end of 2026, which means a second migration — this layout to devicetree —
that upstream will not have done either, widening the gap further.

**Divergence is concentrated where it is most expensive.** The 43 differing files
are almost entirely build configuration, board definition, and `transport.c` /
`main.c` / `mic.c` — the files most likely to change upstream and hardest to
merge mechanically. The 523 identical files are Opus and the parts nobody edits.
That ratio is the wrong way round for cheap merges.

**Three costs push the other way.** The signing key is byte-identical, so OTA to
shipped devices still works. The Rust library is self-contained in `omi/rust/`,
so it does not collide with upstream's C on re-sync. And the DevKit is largely
unported, so DevKit changes can still be taken nearly verbatim — a temporary
benefit that ends the day the nrfx 3.x PDM port lands.

**What we owe upstream.** The four fixes in §3.2 are upstream bugs found by
reading upstream code, and none has been reported. The `RING_INFO` `-ENOMEM`
retry and the `ATT_MTU`/`ATT_MTU − 3` sizing in particular are small, isolated,
and apply cleanly to v2.9.0. Contributing them back would shrink the divergence
rather than grow it.

## 6. Nothing here has been measured, and most of it has not been run

Stated separately because everything above depends on it.

- **Nothing in this tree has been run on hardware.** No pendant has booted an
  image built from this branch. Every behavioural claim about IMU wake, AAD
  gating, the user-event queue, adaptive connection parameters or the offline
  sync path is a claim about what the code says, not about what a device does.
- **Two of five targets have ever compiled.** `omi-cv1` and `evt-test` build
  clean under NCS v3.4.0; the three `devkit-*` targets do not build at all.
  Before the SDK upgrade, *nothing* in this tree had ever been compiled, which is
  why several of the fixes in §3.2 were latent rather than regressions.
- **No power, retention, throughput, latency or connection-quality number is
  claimed** — in either direction. The AAD path should push real-world retention
  past the ≈35-hour continuous-audio ceiling of the ring because silence is never
  encoded, but that is an argument from the code, not a measurement. The lean
  config pass removed configuration the sources do not reference; it has not been
  shown to shrink the image.
- **The `settings_storage` OTA risk is unresolved.** The MCUboot-visible
  partitions are byte-identical to the v2.9.0 static layout, so OTA to fielded
  devices should still work. But inside the primary slot, Partition Manager under
  v3.4.0 now also places `settings_storage` (8 KB) and an `EMPTY_0` filler,
  shrinking the `app` partition by 16 KB. The NVS settings backend stores the
  writable device name and RTC state there, and it has not been established where
  NVS lived under v2.9.0 — so a device upgrading over the air may or may not find
  its existing settings. **Confirm against a v2.9.0 build's `partitions.yml`
  before any rollout.** `README.md`'s *Open risk: settings storage moved* has the
  partition table.
- **Two features ship off by default because they are unvalidated**: adaptive
  connection parameters (an earlier variant dropped connections on some phones)
  and IMU double-tap (datasheet-plausible thresholds, never measured).
- **Enabling Opus DTX remains an open question, not a decision.** It would shrink
  the stream during pauses the AAD threshold misses, at the cost of comfort-noise
  artefacts and a decoder that must handle DTX frames. It changes the wire format
  the app decodes, so it needs an app-side decision and an A/B on real
  recordings. Upstream has it off too.
