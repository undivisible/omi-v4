#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import sys
from pathlib import Path

# Every path this script emits is repo-relative: `app_dir`, `conf`,
# `conf_copy_from` and `conf_copy_to` are all resolved from the repository root,
# never from `app_dir`. Path-valued CMake arguments carry the REPO_TOKEN prefix,
# which the workflow replaces with $GITHUB_WORKSPACE, because west runs from the
# NCS workspace rather than from the checkout.
REPO_TOKEN = "%%REPO_ROOT%%"

FALLBACK_TARGETS = [
    {
        "id": "omi-cv1",
        "device": "Omi CV1 pendant (nRF5340)",
        "board": "omi/nrf5340/cpuapp",
        "app_dir": "firmware/omi",
        "conf": "firmware/omi/omi.conf",
        "sysbuild": "true",
        "cmake_args": "",
        "conf_copy_from": "firmware/omi/omi.conf",
        "conf_copy_to": "firmware/omi/prj.conf",
    },
    {
        "id": "omi-devkit-v1",
        "device": "Omi DevKit v1 (Seeed XIAO nRF52840 Sense)",
        "board": "xiao_ble/nrf52840/sense",
        "app_dir": "firmware/devkit",
        "conf": "firmware/devkit/prj_xiao_ble_sense_devkitv1.conf",
        "sysbuild": "false",
        "cmake_args": f"-DCONF_FILE={REPO_TOKEN}/firmware/devkit/prj_xiao_ble_sense_devkitv1.conf",
    },
    {
        "id": "omi-devkit-v1-spisd",
        "device": "Omi DevKit v1 with SPI SD card (Seeed XIAO nRF52840 Sense)",
        "board": "xiao_ble/nrf52840/sense",
        "app_dir": "firmware/devkit",
        "conf": "firmware/devkit/prj_xiao_ble_sense_devkitv1-spisd.conf",
        "sysbuild": "false",
        "cmake_args": f"-DCONF_FILE={REPO_TOKEN}/firmware/devkit/prj_xiao_ble_sense_devkitv1-spisd.conf",
    },
    {
        "id": "omi-devkit-v2-adafruit",
        "device": "Omi DevKit v2 Adafruit (Seeed XIAO nRF52840 Sense)",
        "board": "xiao_ble/nrf52840/sense",
        "app_dir": "firmware/devkit",
        "conf": "firmware/devkit/prj_xiao_ble_sense_devkitv2-adafruit.conf",
        "sysbuild": "false",
        "cmake_args": f"-DCONF_FILE={REPO_TOKEN}/firmware/devkit/prj_xiao_ble_sense_devkitv2-adafruit.conf",
    },
]

BOARD_HINTS = [
    ("xiao", "xiao_ble/nrf52840/sense"),
    ("devkit", "xiao_ble/nrf52840/sense"),
    ("nrf5340", "omi/nrf5340/cpuapp"),
    ("cv1", "omi/nrf5340/cpuapp"),
]

SKIPPED_CONF_NAMES = {
    "sysbuild.conf",
    "mcuboot.conf",
    "b0.conf",
    "hci_ipc.conf",
    "ipc_radio.conf",
    "empty_net_core.conf",
}

SKIPPED_DIR_PARTS = {
    ".git",
    "build",
    "boards",
    "dts",
    "modules",
    "sysbuild",
    "tests",
    "samples",
    "node_modules",
    "zephyr",
    "nrf",
    "bootloader",
}

CONF_CMAKE_KEYS = ("CONF_FILE", "EXTRA_CONF_FILE", "OVERLAY_CONFIG", "FILE_SUFFIX")


def slug(text: str) -> str:
    out = re.sub(r"[^A-Za-z0-9]+", "-", text.strip().lower()).strip("-")
    return out or "target"


def repo_relative_dir(root: Path, value: str) -> str:
    parts = [p for p in value.split("/") if p and p != "."]
    for index in range(len(parts)):
        candidate = "/".join(parts[index:])
        if candidate != "firmware" and not candidate.startswith("firmware/"):
            continue
        if (root / candidate).is_dir():
            return candidate
    return ""


def readme_variables(root: Path, text: str) -> dict[str, str]:
    variables: dict[str, str] = {}
    pattern = re.compile(r"(?<![A-Za-z0-9_$])([A-Za-z_][A-Za-z0-9_]*)=([^\s`'\"]+)")
    for raw in text.splitlines():
        for match in pattern.finditer(raw):
            name = match.group(1)
            if name in variables:
                continue
            resolved = repo_relative_dir(root, match.group(2).rstrip("`.,;"))
            if resolved:
                variables[name] = resolved
    return variables


def expand_vars(text: str, variables: dict[str, str]) -> str:
    if not variables:
        return text

    def replace(match: re.Match[str]) -> str:
        name = match.group(1) or match.group(2)
        return variables.get(name, match.group(0))

    return re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)", replace, text)


def repo_relative(root: Path, value: str) -> str:
    if not value:
        return ""
    candidate = os.path.normpath(value.lstrip("/") if os.path.isabs(value) else value)
    if candidate.startswith("..") or candidate == ".":
        return ""
    if (root / candidate).exists():
        return candidate
    return ""


def resolve_conf(root: Path, app_dir: str, value: str) -> str:
    if not value:
        return ""
    direct = repo_relative(root, value)
    if direct:
        return direct
    joined = os.path.normpath(os.path.join(app_dir, value))
    if (root / joined).is_file():
        return joined
    return value


def rewrite_cmake_args(root: Path, args: list[str]) -> str:
    rewritten: list[str] = []
    for arg in args:
        body = arg[2:]
        if "=" not in body:
            rewritten.append(arg)
            continue
        key, value = body.split("=", 1)
        # The workflow derives BOARD_ROOT from the discovered board root and
        # passes it itself; keeping the README's copy would pass it twice.
        if key == "BOARD_ROOT" or key.endswith("_BOARD_ROOT"):
            continue
        relative = repo_relative(root, value)
        if relative:
            value = f"{REPO_TOKEN}/{relative}"
        rewritten.append(f"-D{key}={value}")
    return " ".join(rewritten)


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def parse_board_yaml(path: Path) -> list[dict]:
    text = read_text(path)
    if not text:
        return []
    boards: list[dict] = []
    current: dict | None = None
    soc_names: list[str] = []
    cluster_names: list[str] = []
    in_socs = False
    for raw in text.splitlines():
        line = raw.rstrip()
        if not line.strip() or line.strip().startswith("#"):
            continue
        stripped = line.strip()
        indent = len(line) - len(line.lstrip())
        if stripped in ("board:", "boards:") and indent == 0:
            in_socs = False
            continue
        name_match = re.match(r"^-?\s*name:\s*(\S+)", stripped)
        if name_match:
            value = name_match.group(1).strip("\"'")
            if in_socs:
                soc_names.append(value)
            elif indent <= 4 and current is None:
                current = {"name": value}
            elif indent <= 4:
                boards.append({"name": current["name"], "socs": soc_names, "clusters": cluster_names})
                current = {"name": value}
                soc_names, cluster_names = [], []
            continue
        if stripped.startswith("socs:"):
            in_socs = True
            continue
        if stripped.startswith("cpuclusters:"):
            continue
        cluster_match = re.match(r"^-\s*(\w+)$", stripped)
        if cluster_match and in_socs:
            cluster_names.append(cluster_match.group(1))
    if current is not None:
        boards.append({"name": current["name"], "socs": soc_names, "clusters": cluster_names})
    return boards


def discover_boards(firmware: Path) -> list[dict]:
    found: dict[str, dict] = {}
    for board_yml in firmware.rglob("board.yml"):
        for board in parse_board_yaml(board_yml):
            name = board.get("name")
            if not name:
                continue
            found.setdefault(name, board)
    for defconfig in firmware.rglob("*_defconfig"):
        name = defconfig.name[: -len("_defconfig")]
        found.setdefault(name, {"name": name, "socs": [], "clusters": []})
    results = []
    for name, board in sorted(found.items()):
        qualified = name
        socs = [s for s in board.get("socs", []) if s]
        clusters = [c for c in board.get("clusters", []) if c]
        if socs:
            qualified = f"{name}/{socs[0]}"
            if clusters:
                qualified = f"{qualified}/{clusters[0]}"
        results.append({"name": name, "qualified": qualified})
    return results


def board_for(tokens: str, boards: list[dict]) -> str:
    haystack = tokens.lower()
    for board in boards:
        if board["name"].lower() in haystack:
            return board["qualified"]
    for needle, value in BOARD_HINTS:
        if needle in haystack:
            return value
    if len(boards) == 1:
        return boards[0]["qualified"]
    return ""


def code_lines(text: str):
    fence = None
    for raw in text.splitlines():
        stripped = raw.strip()
        if fence is None and stripped.startswith("```"):
            fence = stripped[:3]
            continue
        if fence is not None and stripped.startswith("```"):
            fence = None
            continue
        yield raw, fence is not None


def logical_commands(text: str):
    heading = ""
    buffer = ""
    workdir = ""
    for raw, inside_fence in code_lines(text):
        stripped = raw.strip()
        if not inside_fence and stripped.startswith("#"):
            heading = stripped.lstrip("#").strip()
            continue
        if not inside_fence and "west build" not in stripped:
            continue
        if not stripped and not buffer:
            continue
        if buffer:
            buffer = buffer + " " + stripped.rstrip("\\").strip()
        else:
            buffer = stripped.rstrip("\\").strip()
        if stripped.endswith("\\"):
            continue
        command = buffer
        buffer = ""
        if not command:
            continue
        cd_match = re.match(r"^cd\s+([^\s&;|]+)\s*(?:&&\s*)?(.*)$", command)
        if cd_match:
            workdir = cd_match.group(1).strip("\"'")
            command = cd_match.group(2).strip()
            if not command:
                continue
        yield heading, workdir, command


def parse_west_build(command: str) -> dict | None:
    for piece in re.split(r"&&|;", command):
        piece = piece.strip()
        if piece.startswith("$"):
            piece = piece[1:].strip()
        if not piece.startswith("west "):
            continue
        try:
            tokens = shlex.split(piece)
        except ValueError:
            continue
        if len(tokens) < 2 or tokens[0] != "west" or tokens[1] != "build":
            continue
        tokens = tokens[2:]
        board = ""
        source = ""
        sysbuild = False
        cmake_args: list[str] = []
        index = 0
        while index < len(tokens):
            token = tokens[index]
            if token in ("-b", "--board"):
                index += 1
                if index < len(tokens):
                    board = tokens[index]
            elif token.startswith("--board="):
                board = token.split("=", 1)[1]
            elif token.startswith("-b=") :
                board = token.split("=", 1)[1]
            elif token in ("-d", "--build-dir", "-t", "--target", "-o", "--build-opt"):
                index += 1
            elif token in ("--sysbuild",):
                sysbuild = True
            elif token in ("--no-sysbuild",):
                sysbuild = False
            elif token == "--":
                cmake_args.extend(tokens[index + 1 :])
                break
            elif token.startswith("-D"):
                cmake_args.append(token)
            elif token.startswith("-"):
                pass
            elif not source:
                source = token
            index += 1
        if not board:
            continue
        return {
            "board": board,
            "source": source,
            "sysbuild": sysbuild,
            "cmake_args": [a for a in cmake_args if a.startswith("-D")],
        }
    return None


def parse_conf_copy(root: Path, command: str) -> tuple[str, str] | None:
    if not command.startswith("cp "):
        return None
    try:
        tokens = shlex.split(command)
    except ValueError:
        return None
    tokens = [t for t in tokens[1:] if not t.startswith("-")]
    if len(tokens) != 2:
        return None
    source, destination = tokens
    if Path(destination).name != "prj.conf":
        return None
    source_rel = repo_relative(root, source)
    destination_rel = os.path.normpath(
        destination.lstrip("/") if os.path.isabs(destination) else destination
    )
    if not source_rel or destination_rel.startswith(".."):
        return None
    return source_rel, destination_rel


def conf_from_cmake_args(args: list[str]) -> str:
    for arg in args:
        body = arg[2:]
        if "=" not in body:
            continue
        key, value = body.split("=", 1)
        for candidate in CONF_CMAKE_KEYS:
            if key == candidate or key.endswith("_" + candidate):
                return value.split(";")[0].strip().strip("\"'")
    return ""


def resolve_app_dir(root: Path, workdir: str, source: str) -> str:
    candidates = []
    if source:
        if workdir:
            candidates.append(Path(workdir) / source)
        candidates.append(Path(source))
    elif workdir:
        candidates.append(Path(workdir))
    for candidate in candidates:
        normalised = repo_relative(root, str(candidate))
        if not normalised:
            continue
        if (root / normalised / "CMakeLists.txt").is_file():
            return normalised
    for candidate in candidates:
        name = Path(os.path.normpath(str(candidate))).name
        if not name or name in (".", ".."):
            continue
        for cmake in (root / "firmware").rglob("CMakeLists.txt"):
            if cmake.parent.name == name:
                return str(cmake.parent.relative_to(root))
    return ""


def is_sysbuild_conf(root: Path, app_dir: Path, conf: str, declared: bool) -> bool:
    if declared:
        return True
    if (app_dir / "sysbuild.conf").is_file() or (app_dir / "sysbuild").is_dir():
        return True
    conf_path = root / conf if conf else app_dir / "prj.conf"
    text = read_text(conf_path)
    return "CONFIG_BOOTLOADER_MCUBOOT=y" in text


def targets_from_readme(root: Path, boards: list[dict]) -> list[dict]:
    readme = root / "firmware" / "README.md"
    if not readme.is_file():
        return []
    text = read_text(readme)
    variables = readme_variables(root, text)
    seen: set[str] = set()
    targets: list[dict] = []
    entries = []
    pending_copy = ("", "")
    for heading, workdir, command in logical_commands(text):
        command = expand_vars(command, variables)
        workdir = expand_vars(workdir, variables)
        copy = parse_conf_copy(root, command)
        if copy:
            pending_copy = copy
            continue
        parsed = parse_west_build(command)
        if not parsed:
            continue
        app_dir = resolve_app_dir(root, workdir, parsed["source"])
        if not app_dir:
            pending_copy = ("", "")
            continue
        copy_from, copy_to = pending_copy
        if copy_to and os.path.dirname(copy_to) != app_dir:
            copy_from, copy_to = "", ""
        pending_copy = ("", "")
        entries.append((heading, parsed, app_dir, copy_from, copy_to))
    # One README heading often documents several builds that differ only by
    # config (the DevKit variants). Numbering those would produce artifacts
    # nobody can map back to a board, so those targets are named after their
    # config instead.
    heading_counts: dict[str, int] = {}
    for heading, _, _, _, _ in entries:
        key = slug(heading) if heading else ""
        heading_counts[key] = heading_counts.get(key, 0) + 1
    for heading, parsed, app_dir, copy_from, copy_to in entries:
        conf = resolve_conf(root, app_dir, conf_from_cmake_args(parsed["cmake_args"]))
        board = parsed["board"]
        if not board:
            board = board_for(f"{app_dir} {conf} {heading}", boards)
        heading_slug = slug(heading) if heading else ""
        if heading_slug and heading_counts.get(heading_slug, 0) == 1:
            identifier = heading_slug
        elif conf:
            stem = Path(conf).stem
            if stem.startswith("prj_"):
                stem = stem[4:]
            identifier = slug(stem)
        else:
            identifier = heading_slug or slug(f"{Path(app_dir).name}-{board}")
        base = identifier or slug(Path(app_dir).name)
        identifier = base
        suffix = 2
        while identifier in seen:
            identifier = f"{base}-{suffix}"
            suffix += 1
        seen.add(identifier)
        targets.append(
            {
                "id": identifier,
                "device": heading or f"{Path(app_dir).name} ({board})",
                "board": board,
                "app_dir": app_dir,
                "conf": conf,
                "sysbuild": "true" if is_sysbuild_conf(root, root / app_dir, conf, parsed["sysbuild"]) else "false",
                "cmake_args": rewrite_cmake_args(root, parsed["cmake_args"]),
                "conf_copy_from": copy_from,
                "conf_copy_to": copy_to,
            }
        )
    return targets


def candidate_app_dirs(firmware: Path) -> list[Path]:
    results = []
    for cmake in sorted(firmware.rglob("CMakeLists.txt")):
        app = cmake.parent
        parts = set(app.relative_to(firmware).parts)
        if parts & SKIPPED_DIR_PARTS:
            continue
        text = read_text(cmake)
        if "find_package(Zephyr" not in text and "FIND_PACKAGE(Zephyr" not in text.upper():
            continue
        confs = [p for p in app.glob("*.conf") if p.name not in SKIPPED_CONF_NAMES]
        if not confs:
            continue
        results.append(app)
    return results


def targets_from_tree(root: Path, boards: list[dict]) -> list[dict]:
    firmware = root / "firmware"
    targets: list[dict] = []
    seen: set[str] = set()
    for app in candidate_app_dirs(firmware):
        confs = sorted(p for p in app.glob("*.conf") if p.name not in SKIPPED_CONF_NAMES)
        variants = [p for p in confs if p.name != "prj.conf"]
        chosen = variants or confs
        for conf in chosen:
            stem = conf.stem
            if stem.startswith("prj_"):
                stem = stem[len("prj_") :]
            identifier = slug(stem if stem != "prj" else app.name)
            if identifier in seen:
                identifier = slug(f"{app.name}-{stem}")
            base = identifier
            suffix = 2
            while identifier in seen:
                identifier = f"{base}-{suffix}"
                suffix += 1
            seen.add(identifier)
            app_rel = str(app.relative_to(root))
            conf_rel = str(conf.relative_to(root))
            board = board_for(f"{app_rel} {conf.name}", boards)
            sysbuild = is_sysbuild_conf(root, app, conf_rel, False)
            cmake_args = ""
            if conf.name != "prj.conf":
                prefix = f"{app.name}_" if sysbuild else ""
                cmake_args = f"-D{prefix}CONF_FILE={REPO_TOKEN}/{conf_rel}"
            targets.append(
                {
                    "id": identifier,
                    "device": f"{app.name} ({conf.name})",
                    "board": board,
                    "app_dir": app_rel,
                    "conf": conf_rel,
                    "sysbuild": "true" if sysbuild else "false",
                    "cmake_args": cmake_args,
                }
            )
    return targets


def emit(output_path: str, key: str, value: str) -> None:
    if not output_path:
        print(f"{key}={value}")
        return
    with open(output_path, "a", encoding="utf-8") as handle:
        if "\n" in value:
            handle.write(f"{key}<<__EOF__\n{value}\n__EOF__\n")
        else:
            handle.write(f"{key}={value}\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", default=".")
    parser.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT", ""))
    parser.add_argument("--print-only", action="store_true")
    args = parser.parse_args()

    root = Path(args.repo_root).resolve()
    firmware = root / "firmware"
    if not firmware.is_dir():
        print(
            "::error::firmware/ is not present in this repository. The pendant firmware has not "
            "been vendored yet, so no firmware target can be built. Vendor the nRF Connect SDK "
            "firmware tree into firmware/ and re-run this workflow."
        )
        return 1

    boards = discover_boards(firmware)
    board_root = "firmware" if (firmware / "boards").is_dir() else ""

    source = "readme"
    targets = targets_from_readme(root, boards)
    if not targets:
        source = "tree"
        targets = targets_from_tree(root, boards)
    if not targets:
        source = "fallback"
        targets = [dict(entry) for entry in FALLBACK_TARGETS]
        print(
            "::warning::Neither firmware/README.md nor the firmware tree yielded a buildable "
            "Zephyr application. Falling back to the declared matrix; every entry that does not "
            "exist on disk will fail loudly during its build step."
        )

    for target in targets:
        target["board_root"] = board_root
        target.setdefault("cmake_args", "")
        target.setdefault("conf", "")
        target.setdefault("conf_copy_from", "")
        target.setdefault("conf_copy_to", "")

    print(f"Discovery source: {source}")
    print(f"Board root: {board_root or '(none)'}")
    print("Boards found under firmware/boards:")
    for board in boards:
        print(f"  - {board['name']} -> {board['qualified']}")
    if not boards:
        print("  (none)")
    print("Targets:")
    for target in targets:
        copy = ""
        if target["conf_copy_from"]:
            copy = f" conf_copy={target['conf_copy_from']} -> {target['conf_copy_to']}"
        print(
            f"  - {target['id']}: board={target['board'] or '(unresolved)'} "
            f"app_dir={target['app_dir']} conf={target['conf'] or '(default prj.conf)'} "
            f"sysbuild={target['sysbuild']} cmake_args={target['cmake_args'] or '(none)'}{copy}"
        )

    missing = []
    for target in targets:
        for key in ("app_dir", "conf", "conf_copy_from"):
            value = target[key]
            if value and not (root / value).exists():
                missing.append(f"{target['id']}: {key}={value}")
    if missing:
        print(
            "::error::These discovered paths do not exist in the checkout: "
            + "; ".join(missing)
            + ". Fix the west build commands in firmware/README.md or "
            ".github/scripts/discover_firmware_targets.py."
        )
        return 1

    unresolved = [t["id"] for t in targets if not t["board"]]
    if unresolved:
        print(
            "::warning::No board could be resolved for: "
            + ", ".join(unresolved)
            + ". Those builds will fail with a diagnostic. Document the exact west build command "
            "in firmware/README.md to fix this."
        )

    matrix = json.dumps({"include": targets}, separators=(",", ":"))
    if args.print_only:
        print(matrix)
        return 0
    emit(args.github_output, "matrix", matrix)
    emit(args.github_output, "count", str(len(targets)))
    emit(args.github_output, "source", source)
    return 0


if __name__ == "__main__":
    sys.exit(main())
