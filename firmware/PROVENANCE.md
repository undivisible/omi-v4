# Firmware vendoring provenance

The Omi pendant firmware in this directory is vendored from a separate upstream
repository. It is **not** built by this repo's CI (it needs the Zephyr SDK /
nRF Connect SDK toolchain).

## Upstream

| Field | Value |
| --- | --- |
| Upstream repo (local path) | `~/projects/omi` |
| Upstream remote | `https://github.com/BasedHardware/omi.git` |
| Branch vendored | `firmware/idle-auto-sleep` |
| Commit SHA | `ed4e513e64702b33fa088f1a0f58fc60e1935976` |
| Upstream commit date | 2026-07-23 02:50:56 -0400 |
| Upstream subtree | `omi/firmware/` |
| Vendored on | 2026-07-23 |

`firmware/idle-auto-sleep` was chosen over `main` because it carries the
idle auto-sleep, DIS firmware-revision, capture-state LED (`19B10015`), BLE
sleep command (`19B10014`) and writable device name (`19B10016`) work.

Verify the upstream tip with:

```sh
git -C ~/projects/omi log --oneline firmware/idle-auto-sleep -5
```

## What was included

Everything the production nRF5340 pendant image needs to build:

| Path here | Upstream path | Notes |
| --- | --- | --- |
| `omi/` | `omi/firmware/omi/` | Production application (Zephyr app root) |
| `omi/src/lib/core/lib/opus-1.2.1/` | same | Vendored Opus 1.2.1, built when `CONFIG_OMI_CODEC_OPUS=y` |
| `boards/omi/` | `omi/firmware/boards/omi/` | nRF5340 board definition (`BOARD_ROOT` target) |
| `bootloader/mcuboot/` | `omi/firmware/bootloader/mcuboot/` | MCUboot Kconfig fragment + image signing key |
| `.clang-format` | `omi/firmware/.clang-format` | Formatting rules for the C sources |
| `BUILD_AND_OTA_FLASH.md` | `omi/firmware/BUILD_AND_OTA_FLASH.md` | Upstream build/OTA guide (kept verbatim as reference) |

### `bootloader/mcuboot/root-rsa-2048.pem`

This is the MCUboot **image signing** key referenced by
`omi/sysbuild.conf` (`SB_CONFIG_BOOT_SIGNATURE_KEY_FILE`). It is the key that is
already published in the upstream open-source repository and already burned into
shipped devices — it is *not* a secret, and it is load-bearing: an image signed
with any other key will be rejected by the MCUboot already on the pendant, so
OTA would break. It must stay byte-identical to upstream.

## What was excluded

| Path | Why |
| --- | --- |
| `omi/firmware/devkit/` | Legacy XIAO nRF52840 devkit variant; not the shipping pendant |
| `omi/firmware/testing/`, `test*` | Test/bring-up variants, not production |
| `omi/firmware/FLASH_3.0.8/` | ~40 MB of prebuilt `.hex`/`.exe` flashing blobs for an old release |
| `omi/firmware/bootloader/bootloader0.9.0.uf2`, `bootloader/deprecated/` | XIAO nRF52840 Adafruit bootloader images, unrelated to the nRF5340 |
| `omi/firmware/bootloader/mcuboot/enc-rsa2048-{priv,pub}.pem` | MCUboot image **encryption** keys; encryption is not enabled anywhere in this tree (no `SB_CONFIG_BOOT_ENCRYPTION`, no reference in any `.conf`), so the private key was not vendored |
| `omi/firmware/omi/src/lib/evt/` | EVT-hardware bring-up variant. Not referenced by `omi/CMakeLists.txt`, so it never compiles into the production image |
| `omi/firmware/AGENTS.md` | Upstream repo's agent instructions, not applicable here |
| `.git` | Not a submodule; this is a flat vendored copy |

## Divergence from upstream

This tree is **not** a pristine mirror. After the initial vendoring commit
(which is pristine minus the exclusions above), local feature work was applied
on top. See `git log -- firmware/` for the exact set. The feature work covers:

- button gesture semantics + user-event BLE characteristic
- T5838 hardware-AAD tuning exposed as Kconfig
- IMU wake-on-motion / tap gestures
- charging-state BLE notify improvements
- build-derived firmware version (DIS `0x2A26`)
- `omi.conf` / Kconfig lean pass

See `BLE_CONTRACTS.md` for the resulting app-facing interface and `README.md`
for build instructions.

## How to re-sync with upstream

1. Fetch upstream and pick the commit to vendor:

   ```sh
   git -C ~/projects/omi fetch origin
   git -C ~/projects/omi log --oneline firmware/idle-auto-sleep -20
   ```

2. Export the same subtree into a scratch directory:

   ```sh
   SHA=<new-sha>
   git -C ~/projects/omi archive "$SHA" \
       omi/firmware/omi omi/firmware/boards \
       omi/firmware/bootloader/mcuboot \
       omi/firmware/.clang-format omi/firmware/BUILD_AND_OTA_FLASH.md \
       -o /tmp/omi-fw.tar
   mkdir -p /tmp/omi-fw && tar -xf /tmp/omi-fw.tar -C /tmp/omi-fw --strip-components=2
   rm -rf /tmp/omi-fw/omi/src/lib/evt /tmp/omi-fw/bootloader/mcuboot/enc-rsa2048-*.pem
   ```

3. Diff against this tree and merge deliberately — do **not** blindly overwrite,
   because of the local divergence listed above:

   ```sh
   diff -ru firmware /tmp/omi-fw | less
   ```

4. Update the SHA / date / branch table at the top of this file in the same
   commit, and re-check `BLE_CONTRACTS.md` if any GATT code changed.
