#!/usr/bin/env bash
set -euo pipefail

SEARCH_LOG="$(mktemp)"
trap 'rm -f "${SEARCH_LOG}"' EXIT

note() {
  printf '%s\n' "$1" >> "${SEARCH_LOG}"
  printf '%s\n' "$1"
}

persist_path_entry() {
  if [ -n "${GITHUB_PATH:-}" ]; then
    printf '%s\n' "$1" >> "${GITHUB_PATH}"
  fi
}

persist_env() {
  if [ -n "${GITHUB_ENV:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "${GITHUB_ENV}"
  fi
  export "$1=$2"
}

prepend_path() {
  case ":${PATH}:" in
    *":$1:"*) return 0 ;;
  esac
  PATH="$1:${PATH}"
  export PATH
  persist_path_entry "$1"
  note "added $1 to PATH"
}

toolchain_bundles() {
  # nrfutil unpacks each toolchain into a hash-named directory. The image sets
  # ZEPHYR_SDK_INSTALL_DIR=<bundle>/opt/zephyr-sdk, which names the bundle
  # without having to guess the hash.
  if [ -n "${ZEPHYR_SDK_INSTALL_DIR:-}" ]; then
    case "${ZEPHYR_SDK_INSTALL_DIR}" in
      */opt/zephyr-sdk) printf '%s\n' "${ZEPHYR_SDK_INSTALL_DIR%/opt/zephyr-sdk}" ;;
    esac
  fi
  for root in /opt/ncs/toolchains /opt/nordic/ncs/toolchains "${HOME}/ncs/toolchains"; do
    [ -d "${root}" ] || continue
    for bundle in "${root}"/*; do
      [ -d "${bundle}" ] || continue
      printf '%s\n' "${bundle}"
    done
  done
}

export_toolchain_bundle() {
  local found=1
  while IFS= read -r bundle; do
    [ -n "${bundle}" ] || continue
    [ -d "${bundle}" ] || continue
    note "inspecting toolchain bundle ${bundle}"
    for suffix in bin usr/bin usr/local/bin opt/bin opt/zephyr-sdk/arm-zephyr-eabi/bin; do
      [ -d "${bundle}/${suffix}" ] || continue
      prepend_path "${bundle}/${suffix}"
      found=0
    done
    if [ -d "${bundle}/opt/zephyr-sdk" ] && [ -z "${ZEPHYR_SDK_INSTALL_DIR:-}" ]; then
      persist_env ZEPHYR_SDK_INSTALL_DIR "${bundle}/opt/zephyr-sdk"
    fi
  done <<EOF
$(toolchain_bundles)
EOF
  return "${found}"
}

export_zephyr_sdk() {
  if [ -n "${ZEPHYR_SDK_INSTALL_DIR:-}" ] && [ -d "${ZEPHYR_SDK_INSTALL_DIR}" ]; then
    persist_env ZEPHYR_SDK_INSTALL_DIR "${ZEPHYR_SDK_INSTALL_DIR}"
    persist_env ZEPHYR_TOOLCHAIN_VARIANT "${ZEPHYR_TOOLCHAIN_VARIANT:-zephyr}"
    return 0
  fi
  local sdk
  for base in /opt/nordic /opt /usr/local "${HOME}"; do
    [ -d "${base}" ] || continue
    note "searching for a Zephyr SDK under ${base}"
    sdk="$(find "${base}" -maxdepth 6 -type f -name sdk_version -printf '%h\n' 2>/dev/null | sort | head -n1 || true)"
    if [ -n "${sdk}" ]; then
      persist_env ZEPHYR_SDK_INSTALL_DIR "${sdk}"
      persist_env ZEPHYR_TOOLCHAIN_VARIANT "${ZEPHYR_TOOLCHAIN_VARIANT:-zephyr}"
      note "found a Zephyr SDK at ${sdk}"
      return 0
    fi
  done
  note "no Zephyr SDK (a directory containing sdk_version) was found"
  return 1
}

report_success() {
  echo "west:    $(command -v west)"
  echo "cmake:   $(command -v cmake || echo 'not found')"
  echo "ninja:   $(command -v ninja || echo 'not found')"
  echo "python3: $(command -v python3 || echo 'not found')"
  echo "ZEPHYR_SDK_INSTALL_DIR=${ZEPHYR_SDK_INSTALL_DIR:-unset}"
  echo "ZEPHYR_TOOLCHAIN_VARIANT=${ZEPHYR_TOOLCHAIN_VARIANT:-unset}"
}

note "checking whether the build tools are already on PATH (${PATH})"
if command -v west >/dev/null 2>&1 && command -v cmake >/dev/null 2>&1 \
  && command -v ninja >/dev/null 2>&1; then
  # The container image puts the toolchain on PATH for THIS step, but each
  # GitHub Actions step runs in a fresh shell that does not inherit it — the
  # next step got `west: command not found` (exit 127) while this one saw west
  # perfectly well. Persist the directories holding the tools we just resolved
  # to $GITHUB_PATH so later steps actually get them.
  if [ -n "${GITHUB_PATH:-}" ]; then
    for tool in west cmake ninja python3; do
      resolved="$(command -v "${tool}" 2>/dev/null || true)"
      [ -n "${resolved}" ] || continue
      tool_dir="$(dirname "${resolved}")"
      case ":${persisted_dirs:-}:" in
        *":${tool_dir}:"*) continue ;;
      esac
      persisted_dirs="${persisted_dirs:-}:${tool_dir}"
      echo "${tool_dir}" >> "${GITHUB_PATH}"
      note "persisted ${tool_dir} to GITHUB_PATH (for ${tool})"
    done
  fi
  export_zephyr_sdk || true
  report_success
  exit 0
fi

note "looking for an unpacked nRF Connect SDK toolchain bundle"
export_toolchain_bundle || note "no toolchain bundle directory was found"

if ! command -v west >/dev/null 2>&1 && command -v nrfutil >/dev/null 2>&1; then
  note "asking nrfutil toolchain-manager for the toolchain environment"
  before="$(mktemp)"
  after="$(mktemp)"
  script="$(mktemp)"
  if nrfutil toolchain-manager env --as-script > "${script}" 2>/dev/null && [ -s "${script}" ]; then
    env | sort > "${before}"
    set +eu
    . "${script}"
    set -eu
    env | sort > "${after}"
    while IFS= read -r line; do
      name="${line%%=*}"
      value="${line#*=}"
      case "${name}" in
        PATH)
          continue
          ;;
        ZEPHYR_*|GNUARMEMB_*|CMAKE_PREFIX_PATH|PYTHONPATH|LD_LIBRARY_PATH)
          persist_env "${name}" "${value}"
          ;;
      esac
    done < <(comm -13 "${before}" "${after}")
    old_path="$(grep -m1 '^PATH=' "${before}" | cut -d= -f2- || true)"
    if [ "${PATH}" != "${old_path}" ]; then
      IFS=':' read -r -a new_entries <<< "${PATH}"
      for entry in "${new_entries[@]}"; do
        [ -n "${entry}" ] || continue
        case ":${old_path}:" in
          *":${entry}:"*) continue ;;
        esac
        persist_path_entry "${entry}"
        note "added ${entry} to PATH from nrfutil toolchain-manager"
      done
    fi
  else
    note "nrfutil toolchain-manager env --as-script produced nothing usable"
  fi
  rm -f "${before}" "${after}" "${script}"
fi

if ! command -v west >/dev/null 2>&1; then
  for base in /opt/ncs /opt/nordic /opt /usr/local "${HOME}/.local"; do
    [ -d "${base}" ] || continue
    note "searching for a west executable under ${base}"
    while IFS= read -r candidate; do
      [ -x "${candidate}" ] || continue
      prepend_path "$(dirname "${candidate}")"
      break
    done < <(find "${base}" -maxdepth 9 -type f -name west 2>/dev/null | sort)
    command -v west >/dev/null 2>&1 && break
  done
fi

for tool in cmake ninja dtc python3; do
  command -v "${tool}" >/dev/null 2>&1 && continue
  note "searching for ${tool} under /opt/ncs, /opt/nordic and /opt"
  found="$(find /opt/ncs /opt/nordic /opt -maxdepth 9 -type f -name "${tool}" -perm -u+x 2>/dev/null | sort | head -n1 || true)"
  if [ -n "${found}" ]; then
    prepend_path "$(dirname "${found}")"
  fi
done

export_zephyr_sdk || true

report_failure() {
  echo "::error::$1 Update .github/scripts/setup-ncs-toolchain.sh."
  echo "--- what was searched ---"
  cat "${SEARCH_LOG}"
  echo "--- toolchain bundles considered ---"
  toolchain_bundles || true
  echo "--- /opt contents ---"
  ls -la /opt 2>/dev/null || echo "/opt does not exist"
  echo "--- /opt/ncs contents ---"
  ls -la /opt/ncs 2>/dev/null || echo "/opt/ncs does not exist"
  echo "--- toolchain directory listings ---"
  for root in /opt/ncs/toolchains /opt/nordic/ncs/toolchains; do
    [ -d "${root}" ] || continue
    ls -la "${root}" 2>/dev/null || true
    for bundle in "${root}"/*; do
      [ -d "${bundle}" ] || continue
      echo "--- ${bundle} ---"
      ls -la "${bundle}" 2>/dev/null || true
      for suffix in bin usr/bin usr/local/bin opt/bin; do
        [ -d "${bundle}/${suffix}" ] || continue
        echo "--- ${bundle}/${suffix} ---"
        ls -la "${bundle}/${suffix}" 2>/dev/null | head -n 40 || true
      done
    done
  done
  echo "--- any file named west anywhere under / (depth 9) ---"
  find / -maxdepth 9 -name west -type f 2>/dev/null | head -n 20 || true
  echo "--- ZEPHYR_SDK_INSTALL_DIR=${ZEPHYR_SDK_INSTALL_DIR:-unset} ---"
  echo "--- PATH ---"
  echo "${PATH}"
  exit 1
}

if ! command -v west >/dev/null 2>&1; then
  report_failure "No nRF Connect SDK toolchain could be located in this container. west was not found on PATH, nrfutil toolchain-manager did not provide one, and no west executable exists under /opt/ncs, /opt/nordic, /opt, /usr/local or ~/.local."
fi

if ! west --version >/dev/null 2>&1; then
  report_failure "west was found at $(command -v west) but is not runnable ($(west --version 2>&1 | head -n 3))."
fi

report_success
