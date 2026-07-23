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

note "checking whether west is already on PATH (${PATH})"
if command -v west >/dev/null 2>&1; then
  export_zephyr_sdk || true
  report_success
  exit 0
fi

if command -v nrfutil >/dev/null 2>&1; then
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
  for base in /opt/nordic /opt /usr/local "${HOME}/.local"; do
    [ -d "${base}" ] || continue
    note "searching for a west executable under ${base}"
    while IFS= read -r candidate; do
      [ -x "${candidate}" ] || continue
      dir="$(dirname "${candidate}")"
      PATH="${dir}:${PATH}"
      export PATH
      persist_path_entry "${dir}"
      note "added ${dir} to PATH (contains ${candidate})"
      break
    done < <(find "${base}" -maxdepth 6 -type f -name west 2>/dev/null | sort)
    command -v west >/dev/null 2>&1 && break
  done
fi

if ! command -v cmake >/dev/null 2>&1 || ! command -v ninja >/dev/null 2>&1; then
  for tool in cmake ninja dtc; do
    command -v "${tool}" >/dev/null 2>&1 && continue
    note "searching for ${tool} under /opt/nordic and /opt"
    found="$(find /opt/nordic /opt -maxdepth 6 -type f -name "${tool}" -perm -u+x 2>/dev/null | sort | head -n1 || true)"
    if [ -n "${found}" ]; then
      dir="$(dirname "${found}")"
      PATH="${dir}:${PATH}"
      export PATH
      persist_path_entry "${dir}"
      note "added ${dir} to PATH (contains ${tool})"
    fi
  done
fi

export_zephyr_sdk || true

if ! command -v west >/dev/null 2>&1; then
  echo "::error::No nRF Connect SDK toolchain could be located in this container. west was not found on PATH, nrfutil toolchain-manager did not provide one, and no west executable exists under /opt/nordic, /opt, /usr/local or ~/.local. The container image layout changed; update .github/scripts/setup-ncs-toolchain.sh."
  echo "--- what was searched ---"
  cat "${SEARCH_LOG}"
  echo "--- /opt contents ---"
  ls -la /opt 2>/dev/null || echo "/opt does not exist"
  echo "--- /opt/nordic contents ---"
  find /opt/nordic -maxdepth 3 2>/dev/null | head -n 60 || echo "/opt/nordic does not exist"
  echo "--- PATH ---"
  echo "${PATH}"
  exit 1
fi

report_success
