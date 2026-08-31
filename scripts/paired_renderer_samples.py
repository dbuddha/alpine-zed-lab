#!/usr/bin/env python3
"""Fail-closed paired renderer sampling for the isolated Alpine Zed Lab."""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parent.parent
SCHEMA = "alpine-zed-paired-renderer-run/v1"
SET_SCHEMA = "alpine-zed-paired-renderer-samples/v1"
WINDOW_SCHEMA = "alpine-renderer-window/v1"
CALIBRATION_SCHEMA = "alpine-aa-calibration/v1"
CSV_HEADER = ["run_id", "pair_index", "order", "base", "candidate"]
SAMPLE_HEADER = ["sample_index", "elapsed_ns"]
MINIMUM_RUNS = 20
MINIMUM_WINDOWS = 4
MAXIMUM_PAIRS = 1_000
MAXIMUM_WARMUPS = 100_000
MEASUREMENT_STAGE = "renderer-submit-readback"
CLOCK = "process-monotonic-instant"
ORDER_ALGORITHM = "sha256-balanced-sort-v1"
SLUG = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
GIT_SHA = re.compile(r"^[0-9a-f]{40}$")

WINDOW_FIELDS = (
    "id",
    "lease_id",
    "environment_kind",
    "hardware_id",
    "hardware_model",
    "gpu",
    "memory_bytes",
    "os_build",
    "xcode_build",
    "rustc",
    "runner_image",
    "power_state",
    "thermal_policy",
    "display_state",
    "shader_mode",
    "validation_enabled",
    "started_at_utc",
    "ended_at_utc",
)

ADAPTATION_FIELDS = (
    "adaptation_clips",
    "adaptation_operations",
    "adaptation_quads",
    "adaptation_glyphs",
    "adaptation_resources",
    "adaptation_resource_bytes",
    "adaptation_atlas_allocations",
)


class ProtocolError(RuntimeError):
    """A qualification precondition or artifact invariant failed."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ProtocolError(message)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_scalar(source: str, path: Path, line_number: int) -> Any:
    if source.startswith('"') and source.endswith('"'):
        try:
            value = json.loads(source)
        except json.JSONDecodeError as error:
            raise ProtocolError(
                f"cannot parse {path} line {line_number}: {error}"
            ) from error
        require(
            isinstance(value, str),
            f"{path} line {line_number} must contain a string",
        )
        return value
    if source == "true":
        return True
    if source == "false":
        return False
    require(
        re.fullmatch(r"[0-9]+", source) is not None,
        f"{path} line {line_number} has an unsupported TOML value",
    )
    return int(source)


def load_toml(path: Path) -> dict[str, Any]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise ProtocolError(f"cannot load {path}: {error}") from error
    value: dict[str, Any] = {}
    current = value
    key_pattern = re.compile(r"^[a-z][a-z0-9_]*$")
    for line_number, raw_line in enumerate(lines, start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            table = line[1:-1]
            require(
                key_pattern.fullmatch(table) is not None,
                f"{path} line {line_number} has an invalid table",
            )
            require(
                table not in value,
                f"{path} line {line_number} duplicates table {table}",
            )
            current = {}
            value[table] = current
            continue
        require(
            "=" in line,
            f"{path} line {line_number} must contain a key and value",
        )
        key, encoded = (part.strip() for part in line.split("=", 1))
        require(
            key_pattern.fullmatch(key) is not None,
            f"{path} line {line_number} has an invalid key",
        )
        require(
            key not in current,
            f"{path} line {line_number} duplicates key {key}",
        )
        current[key] = parse_scalar(encoded, path, line_number)
    return value


def toml_string(value: str) -> str:
    require("\n" not in value and "\r" not in value, "TOML strings cannot contain newlines")
    return json.dumps(value, ensure_ascii=True)


def bool_text(value: bool) -> str:
    return "true" if value else "false"


def run_command(
    arguments: list[str], *, cwd: Path = ROOT, timeout: int = 900
) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            arguments,
            cwd=cwd,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
            env={**os.environ, "LC_ALL": "C", "LANG": "C"},
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ProtocolError(f"cannot execute {' '.join(arguments)}: {error}") from error


def require_command(arguments: list[str], *, cwd: Path = ROOT) -> str:
    result = run_command(arguments, cwd=cwd)
    require(
        result.returncode == 0,
        f"command failed ({' '.join(arguments)}): {result.stderr.strip() or result.stdout.strip()}",
    )
    return result.stdout.strip()


def normal_relative(value: str, *, prefix: str | None = None) -> Path:
    require(value and "\\" not in value, f"unsafe repository path: {value}")
    path = Path(value)
    require(not path.is_absolute(), f"repository path must be relative: {value}")
    require(
        all(part not in ("", ".", "..") for part in path.parts),
        f"unsafe repository path: {value}",
    )
    if prefix is not None:
        require(
            path.parts and path.parts[0] == prefix,
            f"path must be below {prefix}/: {value}",
        )
    return path


def reject_symlink_path(path: Path) -> None:
    try:
        relative = path.relative_to(ROOT)
    except ValueError as error:
        raise ProtocolError(f"path must remain below the lab root: {path}") from error
    current = ROOT
    for part in relative.parts:
        current /= part
        if current.exists() or current.is_symlink():
            require(
                not current.is_symlink(),
                f"path cannot traverse a symbolic link: {current}",
            )


def artifact_path(value: str, *, must_exist: bool) -> Path:
    relative = normal_relative(value, prefix="artifacts")
    path = ROOT / relative
    reject_symlink_path(path)
    if must_exist:
        require(
            path.is_dir() and not path.is_symlink(),
            f"artifact directory is missing: {value}",
        )
    else:
        require(
            not path.exists() and not path.is_symlink(),
            f"artifact output already exists: {value}",
        )
    return path


def regular_file(path: Path, label: str) -> None:
    reject_symlink_path(path)
    require(
        path.is_file() and not path.is_symlink(),
        f"{label} must be a regular non-symlink file: {path}",
    )


def executable(path_value: str, label: str) -> Path:
    path = Path(path_value)
    if not path.is_absolute():
        path = ROOT / normal_relative(path_value)
    try:
        path.relative_to(ROOT)
    except ValueError as error:
        raise ProtocolError(f"{label} must remain below the lab root") from error
    regular_file(path, label)
    require(os.access(path, os.X_OK), f"{label} is not executable: {path}")
    return path


def valid_slug(value: Any) -> bool:
    return isinstance(value, str) and SLUG.fullmatch(value) is not None


def valid_sha256(value: Any) -> bool:
    return isinstance(value, str) and SHA256.fullmatch(value) is not None


def valid_git_sha(value: Any) -> bool:
    return isinstance(value, str) and GIT_SHA.fullmatch(value) is not None


def parse_utc(value: Any, label: str) -> dt.datetime:
    require(
        isinstance(value, str) and len(value) == 20 and value.endswith("Z"),
        f"{label} must be second-resolution UTC",
    )
    try:
        return dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=dt.timezone.utc
        )
    except ValueError as error:
        raise ProtocolError(f"{label} is not a valid UTC timestamp") from error


def canonical_window_hash(window: dict[str, Any]) -> str:
    encoded = json.dumps(
        {field: window[field] for field in WINDOW_FIELDS},
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    return hashlib.sha256(encoded).hexdigest()


def validate_window(path: Path, allow_test_fixture: bool) -> dict[str, Any]:
    regular_file(path, "window manifest")
    window = load_toml(path)
    require(set(window) == {"schema", *WINDOW_FIELDS}, "window manifest fields drifted")
    require(window["schema"] == WINDOW_SCHEMA, f"window schema must be {WINDOW_SCHEMA}")
    require(valid_slug(window["id"]), "window identifier must be a lowercase slug")
    require(
        valid_slug(window["lease_id"]),
        "window lease identifier must be a lowercase slug",
    )
    require(
        window["environment_kind"] in ("leased-physical", "test-fixture"),
        "window environment must be leased-physical or test-fixture",
    )
    for field in (
        "hardware_id",
        "hardware_model",
        "gpu",
        "os_build",
        "xcode_build",
        "rustc",
        "runner_image",
        "power_state",
        "thermal_policy",
        "display_state",
    ):
        require(
            isinstance(window[field], str) and window[field].strip(),
            f"window {field} is required",
        )
    require(
        isinstance(window["memory_bytes"], int) and window["memory_bytes"] > 0,
        "window memory must be positive",
    )
    require(
        window["shader_mode"] == "offline-metallib",
        "paired sampling requires offline-metallib shaders",
    )
    require(
        window["validation_enabled"] is False,
        "paired sampling rejects validation-enabled timing",
    )
    started = parse_utc(window["started_at_utc"], "window start")
    ended = parse_utc(window["ended_at_utc"], "window end")
    require(started < ended, "window timestamps must be ordered")
    if window["environment_kind"] == "test-fixture":
        require(
            allow_test_fixture,
            "test-fixture capture requires --allow-test-fixture",
        )
    else:
        require(
            not allow_test_fixture,
            "leased physical capture cannot use --allow-test-fixture",
        )
        require(platform.system() == "Darwin", "physical paired sampling requires macOS")
        require(
            platform.machine() == "arm64",
            "physical paired sampling requires Apple Silicon",
        )
        now = dt.datetime.now(dt.timezone.utc)
        require(
            started <= now <= ended,
            "physical capture must execute inside the declared lease window",
        )
    return window


def read_pins() -> dict[str, Any]:
    require_command([str(ROOT / "scripts/check-pin.sh")])
    require_command([str(ROOT / "scripts/check-alpine-pin.sh")])
    require_command([str(ROOT / "scripts/check-series.sh")])
    alpine = load_toml(ROOT / "pins/alpine.toml")
    zed = load_toml(ROOT / "pins/zed.toml")
    lab_revision = require_command([str(ROOT / "scripts/read-lab-revision.sh")])
    require(valid_git_sha(lab_revision), "lab revision is not a full Git SHA")
    return {
        "lab_revision": lab_revision,
        "alpine_revision": alpine["commit"],
        "zed_revision": zed["commit"],
        "trace_manifest_path": alpine["trace_manifest_path"],
        "trace_manifest_sha256": alpine["trace_manifest_sha256"],
        "patch_series_sha256": sha256_file(ROOT / "patches/alpine-metal/series"),
    }


def select_trace(trace_id: str, pins: dict[str, Any]) -> dict[str, str]:
    require(valid_slug(trace_id), "trace identifier must be a lowercase slug")
    manifest = ROOT / normal_relative(pins["trace_manifest_path"])
    regular_file(manifest, "trace manifest")
    require(
        sha256_file(manifest) == pins["trace_manifest_sha256"],
        "trace manifest hash drifted",
    )
    selected: dict[str, str] | None = None
    with manifest.open(newline="", encoding="utf-8") as source:
        for row in csv.reader(source, delimiter="\t"):
            if not row or row[0].startswith("#"):
                continue
            require(len(row) == 10, "trace manifest row must contain ten fields")
            if row[0] == trace_id:
                require(selected is None, f"duplicate trace identifier {trace_id}")
                selected = {
                    "id": row[0],
                    "schema": row[1],
                    "path": row[2],
                    "trace_sha256": row[3],
                    "workload_hash": row[4],
                }
    require(selected is not None, f"trace is not pinned: {trace_id}")
    assert selected is not None
    require(
        selected["schema"] == "alpine-scene-trace/v2",
        "paired sampling requires a version 2 prepared trace",
    )
    require(valid_sha256(selected["trace_sha256"]), "trace SHA-256 is invalid")
    require(valid_sha256(selected["workload_hash"]), "workload SHA-256 is invalid")
    trace = ROOT / ".lab/alpine" / normal_relative(selected["path"])
    regular_file(trace, "pinned trace")
    require(
        sha256_file(trace) == selected["trace_sha256"],
        "pinned trace bytes drifted",
    )
    selected["absolute_path"] = str(trace)
    return selected


def validate_equivalence(
    root: Path, trace: dict[str, str], pins: dict[str, Any]
) -> dict[str, str]:
    set_path = root / "qualification-set.toml"
    fixture_path = root / trace["id"] / "qualification.toml"
    regular_file(set_path, "equivalence set")
    regular_file(fixture_path, "fixture equivalence")
    set_record = load_toml(set_path)
    fixture = load_toml(fixture_path)
    expected_set = {
        "schema": "alpine-renderer-equivalence-set/v2",
        "state": "equivalent",
        "comparison_level": "renderer-only",
        "lab_revision": pins["lab_revision"],
        "zed_revision": pins["zed_revision"],
        "alpine_revision": pins["alpine_revision"],
        "trace_manifest_sha256": pins["trace_manifest_sha256"],
        "patch_series_sha256": pins["patch_series_sha256"],
        "shader_mode": "offline-metallib",
        "direct_metal_performed": True,
        "cpu_oracle_equivalence_within_tolerance_all": True,
        "exact_metal_equivalence_all": True,
        "renderer_timing_performed": False,
        "performance_qualified": False,
    }
    expected_fixture = {
        "schema": "alpine-renderer-equivalence/v2",
        "state": "equivalent",
        "comparison_level": "renderer-only",
        "lab_revision": pins["lab_revision"],
        "zed_revision": pins["zed_revision"],
        "alpine_revision": pins["alpine_revision"],
        "trace_manifest_sha256": pins["trace_manifest_sha256"],
        "trace_schema": trace["schema"],
        "trace_id": trace["id"],
        "trace_path": trace["path"],
        "scene_trace_sha256": trace["trace_sha256"],
        "workload_hash": trace["workload_hash"],
        "shader_mode": "offline-metallib",
        "direct_metal_performed": True,
        "cpu_oracle_equivalence_within_tolerance": True,
        "exact_metal_equivalence": True,
        "renderer_timing_performed": False,
        "performance_qualified": False,
    }
    for key, value in expected_set.items():
        require(
            set_record.get(key) == value,
            f"equivalence set field drifted: {key}",
        )
    for key, value in expected_fixture.items():
        require(
            fixture.get(key) == value,
            f"fixture equivalence field drifted: {key}",
        )
    return {
        "set_sha256": sha256_file(set_path),
        "fixture_sha256": sha256_file(fixture_path),
    }


def balanced_orders(seed: str, lane: str, count: int) -> list[str]:
    require(valid_sha256(seed), "randomization seed must be a lowercase SHA-256")
    require(valid_slug(lane), "order lane must be a lowercase slug")
    require(
        2 <= count <= MAXIMUM_PAIRS,
        f"pair count must be between 2 and {MAXIMUM_PAIRS}",
    )
    labels = ["base-first"] * ((count + 1) // 2) + ["candidate-first"] * (
        count // 2
    )
    ranked = []
    for index, label in enumerate(labels):
        key = hashlib.sha256(f"{seed}:{lane}:{index}:{label}".encode()).digest()
        ranked.append((key, label))
    ranked.sort(key=lambda item: item[0])
    orders = [label for _, label in ranked]
    require(
        "base-first" in orders and "candidate-first" in orders,
        "order lane lacks both directions",
    )
    require(
        abs(orders.count("base-first") - orders.count("candidate-first")) <= 1,
        "order lane is unbalanced",
    )
    return orders


def parse_sample_csv(path: Path) -> int:
    regular_file(path, "sampler CSV")
    with path.open(newline="", encoding="utf-8") as source:
        rows = list(csv.reader(source))
    require(rows and rows[0] == SAMPLE_HEADER, "sampler CSV header drifted")
    require(
        len(rows) == 2,
        "single paired invocation must publish exactly one sample",
    )
    require(
        rows[1][0] == "0" and len(rows[1]) == 2,
        "sampler CSV index drifted",
    )
    require(
        rows[1][1].isdigit() and int(rows[1][1]) > 0,
        "sampler duration must be positive",
    )
    return int(rows[1][1])


def parse_key_values(source: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for token in source.split():
        if "=" in token:
            key, value = token.split("=", 1)
            values[key] = value.rstrip(";")
    return values


def invoke_sampler(
    renderer: str,
    binary: Path,
    trace: dict[str, str],
    output: Path,
    warmups: int,
    log: Path,
) -> tuple[int, dict[str, int] | None]:
    require(
        not output.exists() and not output.is_symlink(),
        f"sampler output collision: {output}",
    )
    if renderer == "alpine":
        arguments = [
            str(binary),
            "benchmark-scene-native",
            trace["absolute_path"],
            str(output),
            str(warmups),
            "1",
        ]
    elif renderer == "gpui":
        arguments = [
            str(binary),
            "--benchmark",
            trace["absolute_path"],
            str(output),
            str(warmups),
            "1",
        ]
    else:
        raise ProtocolError(f"unsupported sampler renderer: {renderer}")
    result = run_command(arguments)
    log.write_text(
        f"command={json.dumps(arguments)}\nreturncode={result.returncode}\n"
        f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        encoding="utf-8",
    )
    require(
        result.returncode == 0,
        f"{renderer} sampler failed: {result.stderr.strip() or result.stdout.strip()}",
    )
    elapsed = parse_sample_csv(output)
    if renderer == "alpine":
        for expected in (
            "admission_iterations=1",
            f"warmup_iterations={warmups}",
            "sample_count=1",
            "renderer=direct-metal",
            f"trace={trace['id']}",
            f"stage {MEASUREMENT_STAGE}",
            "process-monotonic Instant",
            "performance claim=none",
        ):
            require(
                expected in result.stdout,
                f"Alpine sampler summary drifted: {expected}",
            )
        return elapsed, None
    values = parse_key_values(result.stdout)
    expected_values = {
        "schema": "alpine-zed-gpui-renderer-samples/v1",
        "trace_schema": trace["schema"],
        "id": trace["id"],
        "workload_hash": trace["workload_hash"],
        "admission_iterations": "1",
        "warmup_iterations": str(warmups),
        "sample_count": "1",
        "measurement_stage": MEASUREMENT_STAGE,
        "clock": CLOCK,
        "renderer_timing_performed": "true",
        "adaptation_timing_performed": "false",
        "performance_qualified": "false",
    }
    for key, value in expected_values.items():
        require(
            values.get(key) == value,
            f"GPUI sampler summary drifted: {key}",
        )
    adaptation: dict[str, int] = {}
    for field in ADAPTATION_FIELDS:
        require(
            values.get(field, "").isdigit(),
            f"GPUI adaptation counter drifted: {field}",
        )
        adaptation[field] = int(values[field])
    return elapsed, adaptation


def write_csv(
    path: Path, rows: Iterable[tuple[str, int, str, int, int]]
) -> None:
    with path.open("x", newline="", encoding="utf-8") as target:
        writer = csv.writer(target, lineterminator="\n")
        writer.writerow(CSV_HEADER)
        writer.writerows(rows)
        target.flush()
        os.fsync(target.fileno())


def render_window(window: dict[str, Any], heading: str = "[window]") -> str:
    lines = [heading]
    for field in WINDOW_FIELDS:
        value = window[field]
        if isinstance(value, bool):
            rendered = bool_text(value)
        elif isinstance(value, int):
            rendered = str(value)
        else:
            rendered = toml_string(value)
        lines.append(f"{field} = {rendered}")
    return "\n".join(lines)


def render_adaptation(
    trace: dict[str, str], adaptation: dict[str, int]
) -> str:
    lines = [
        'schema = "alpine-zed-gpui-adaptation/v1"',
        f"trace_id = {toml_string(trace['id'])}",
        f"workload_hash = {toml_string(trace['workload_hash'])}",
        "adaptation_timing_performed = false",
    ]
    lines.extend(f"{field} = {adaptation[field]}" for field in ADAPTATION_FIELDS)
    lines.extend(
        [
            "renderer_timing_included = false",
            "performance_qualified = false",
            "",
        ]
    )
    return "\n".join(lines)


def invoke_same_renderer_pair(
    renderer: str,
    lane: str,
    pair_index: int,
    order: str,
    binary: Path,
    trace: dict[str, str],
    warmups: int,
    invocation_dir: Path,
    adaptations: list[dict[str, int]],
) -> tuple[int, int]:
    roles = (
        ["base", "candidate"]
        if order == "base-first"
        else ["candidate", "base"]
    )
    values: dict[str, int] = {}
    for sequence, role in enumerate(roles):
        stem = f"{lane}-{pair_index:04d}-{sequence}-{role}-{renderer}"
        elapsed, adaptation = invoke_sampler(
            renderer,
            binary,
            trace,
            invocation_dir / f"{stem}.csv",
            warmups,
            invocation_dir / f"{stem}.log",
        )
        values[role] = elapsed
        if adaptation is not None:
            adaptations.append(adaptation)
    return values["base"], values["candidate"]


def invoke_cross_pair(
    pair_index: int,
    order: str,
    alpine_binary: Path,
    gpui_binary: Path,
    trace: dict[str, str],
    warmups: int,
    invocation_dir: Path,
    adaptations: list[dict[str, int]],
) -> tuple[int, int]:
    renderers = (
        ["alpine", "gpui"]
        if order == "base-first"
        else ["gpui", "alpine"]
    )
    values: dict[str, int] = {}
    for sequence, renderer in enumerate(renderers):
        binary = alpine_binary if renderer == "alpine" else gpui_binary
        stem = f"cross-{pair_index:04d}-{sequence}-{renderer}"
        elapsed, adaptation = invoke_sampler(
            renderer,
            binary,
            trace,
            invocation_dir / f"{stem}.csv",
            warmups,
            invocation_dir / f"{stem}.log",
        )
        values[renderer] = elapsed
        if adaptation is not None:
            adaptations.append(adaptation)
    return values["alpine"], values["gpui"]


def capture(arguments: argparse.Namespace) -> None:
    require(
        valid_slug(arguments.run_id),
        "run identifier must be a lowercase slug",
    )
    require(
        valid_sha256(arguments.seed),
        "randomization seed must be a lowercase SHA-256",
    )
    require(
        0 <= arguments.warmups <= MAXIMUM_WARMUPS,
        f"warmups must not exceed {MAXIMUM_WARMUPS}",
    )
    require(
        2 <= arguments.pairs <= MAXIMUM_PAIRS,
        f"pairs must be between 2 and {MAXIMUM_PAIRS}",
    )
    output = artifact_path(arguments.output, must_exist=False)
    equivalence = artifact_path(arguments.equivalence, must_exist=True)
    window_path = ROOT / normal_relative(arguments.window)
    window = validate_window(window_path, arguments.allow_test_fixture)
    pins = read_pins()
    trace = select_trace(arguments.trace_id, pins)
    equivalence_identity = validate_equivalence(equivalence, trace, pins)
    alpine_binary = executable(arguments.alpine_sampler, "Alpine sampler")
    gpui_binary = executable(arguments.gpui_sampler, "GPUI sampler")

    output.parent.mkdir(parents=True, exist_ok=True)
    reject_symlink_path(output.parent)
    output.mkdir()
    complete = False
    try:
        invocation_dir = output / "invocations"
        invocation_dir.mkdir()
        adaptations: list[dict[str, int]] = []
        alpine_rows = []
        gpui_rows = []
        cross_rows = []
        alpine_orders = balanced_orders(
            arguments.seed, "alpine-aa", arguments.pairs
        )
        gpui_orders = balanced_orders(arguments.seed, "gpui-aa", arguments.pairs)
        cross_orders = balanced_orders(
            arguments.seed, "cross-renderer", arguments.pairs
        )
        for index in range(arguments.pairs):
            alpine_base, alpine_candidate = invoke_same_renderer_pair(
                "alpine",
                "alpine-aa",
                index,
                alpine_orders[index],
                alpine_binary,
                trace,
                arguments.warmups,
                invocation_dir,
                adaptations,
            )
            gpui_base, gpui_candidate = invoke_same_renderer_pair(
                "gpui",
                "gpui-aa",
                index,
                gpui_orders[index],
                gpui_binary,
                trace,
                arguments.warmups,
                invocation_dir,
                adaptations,
            )
            cross_base, cross_candidate = invoke_cross_pair(
                index,
                cross_orders[index],
                alpine_binary,
                gpui_binary,
                trace,
                arguments.warmups,
                invocation_dir,
                adaptations,
            )
            alpine_rows.append(
                (
                    arguments.run_id,
                    index,
                    alpine_orders[index],
                    alpine_base,
                    alpine_candidate,
                )
            )
            gpui_rows.append(
                (
                    arguments.run_id,
                    index,
                    gpui_orders[index],
                    gpui_base,
                    gpui_candidate,
                )
            )
            cross_rows.append(
                (
                    arguments.run_id,
                    index,
                    cross_orders[index],
                    cross_base,
                    cross_candidate,
                )
            )

        require(adaptations, "GPUI sampling produced no adaptation evidence")
        canonical_adaptation = adaptations[0]
        require(
            all(value == canonical_adaptation for value in adaptations),
            "GPUI adaptation counters changed across renderer samples",
        )
        alpine_csv = output / "alpine-aa.csv"
        gpui_csv = output / "gpui-aa.csv"
        cross_csv = output / "alpine-gpui.csv"
        adaptation_path = output / "gpui-adaptation.toml"
        write_csv(alpine_csv, alpine_rows)
        write_csv(gpui_csv, gpui_rows)
        write_csv(cross_csv, cross_rows)
        adaptation_path.write_text(
            render_adaptation(trace, canonical_adaptation),
            encoding="utf-8",
        )

        captured_at = (
            dt.datetime.now(dt.timezone.utc)
            .replace(microsecond=0)
            .strftime("%Y-%m-%dT%H:%M:%SZ")
        )
        manifest = "\n".join(
            [
                f"schema = {toml_string(SCHEMA)}",
                f"state = {toml_string('fixture-only' if window['environment_kind'] == 'test-fixture' else 'captured')}",
                'comparison_level = "renderer-only"',
                f"run_id = {toml_string(arguments.run_id)}",
                f"randomization_seed = {toml_string(arguments.seed)}",
                f"order_algorithm = {toml_string(ORDER_ALGORITHM)}",
                f"expected_pairs = {arguments.pairs}",
                f"warmup_iterations = {arguments.warmups}",
                f"measurement_stage = {toml_string(MEASUREMENT_STAGE)}",
                f"clock = {toml_string(CLOCK)}",
                f"lab_revision = {toml_string(pins['lab_revision'])}",
                f"zed_revision = {toml_string(pins['zed_revision'])}",
                f"alpine_revision = {toml_string(pins['alpine_revision'])}",
                f"trace_manifest_sha256 = {toml_string(pins['trace_manifest_sha256'])}",
                f"patch_series_sha256 = {toml_string(pins['patch_series_sha256'])}",
                f"trace_schema = {toml_string(trace['schema'])}",
                f"trace_id = {toml_string(trace['id'])}",
                f"trace_path = {toml_string(trace['path'])}",
                f"scene_trace_sha256 = {toml_string(trace['trace_sha256'])}",
                f"workload_hash = {toml_string(trace['workload_hash'])}",
                f"equivalence_set_sha256 = {toml_string(equivalence_identity['set_sha256'])}",
                f"fixture_equivalence_sha256 = {toml_string(equivalence_identity['fixture_sha256'])}",
                f"alpine_sampler_sha256 = {toml_string(sha256_file(alpine_binary))}",
                f"gpui_sampler_sha256 = {toml_string(sha256_file(gpui_binary))}",
                'alpine_aa_artifact = "alpine-aa.csv"',
                f"alpine_aa_sha256 = {toml_string(sha256_file(alpine_csv))}",
                'gpui_aa_artifact = "gpui-aa.csv"',
                f"gpui_aa_sha256 = {toml_string(sha256_file(gpui_csv))}",
                'cross_artifact = "alpine-gpui.csv"',
                f"cross_sha256 = {toml_string(sha256_file(cross_csv))}",
                'adaptation_artifact = "gpui-adaptation.toml"',
                f"adaptation_sha256 = {toml_string(sha256_file(adaptation_path))}",
                "adaptation_timing_performed = false",
                "renderer_timing_performed = true",
                "performance_qualified = false",
                'performance_claim = "none"',
                f"captured_at_utc = {toml_string(captured_at)}",
                f"environment_hash = {toml_string(canonical_window_hash(window))}",
                "",
                render_window(window),
                "",
            ]
        )
        (output / "run.toml").write_text(manifest, encoding="utf-8")
        complete = True
    finally:
        if not complete:
            shutil.rmtree(output, ignore_errors=True)
    print(
        f"captured {arguments.run_id} with {arguments.pairs} paired samples per lane; "
        "performance_qualified=false performance_claim=none"
    )


def parse_paired_csv(
    path: Path, run_id: str, expected_pairs: int
) -> list[tuple[str, int, str, int, int]]:
    regular_file(path, "paired sample CSV")
    with path.open(newline="", encoding="utf-8") as source:
        rows = list(csv.reader(source))
    require(
        rows and rows[0] == CSV_HEADER,
        f"paired CSV header drifted: {path}",
    )
    parsed = []
    for line_number, row in enumerate(rows[1:], start=2):
        require(
            len(row) == 5,
            f"paired CSV line {line_number} must contain five fields",
        )
        require(
            row[0] == run_id,
            f"paired CSV line {line_number} run identity drifted",
        )
        require(
            row[1].isdigit(),
            f"paired CSV line {line_number} pair index is invalid",
        )
        require(
            row[2] in ("base-first", "candidate-first"),
            f"paired CSV line {line_number} order is invalid",
        )
        require(
            row[3].isdigit() and int(row[3]) > 0,
            f"paired CSV line {line_number} base is invalid",
        )
        require(
            row[4].isdigit() and int(row[4]) > 0,
            f"paired CSV line {line_number} candidate is invalid",
        )
        parsed.append(
            (row[0], int(row[1]), row[2], int(row[3]), int(row[4]))
        )
    require(
        len(parsed) == expected_pairs,
        f"run {run_id} expected {expected_pairs} pairs",
    )
    require(
        [row[1] for row in parsed] == list(range(expected_pairs)),
        f"run {run_id} pair indices are not contiguous",
    )
    orders = [row[2] for row in parsed]
    require(
        "base-first" in orders and "candidate-first" in orders,
        f"run {run_id} must contain both execution orders",
    )
    require(
        abs(orders.count("base-first") - orders.count("candidate-first")) <= 1,
        f"run {run_id} order is unbalanced",
    )
    return parsed


def load_run(path_value: str) -> dict[str, Any]:
    path = artifact_path(path_value, must_exist=True)
    manifest_path = path / "run.toml"
    regular_file(manifest_path, "paired run manifest")
    record = load_toml(manifest_path)
    require(
        record.get("schema") == SCHEMA,
        f"run schema drifted: {path_value}",
    )
    require(
        record.get("performance_qualified") is False
        and record.get("performance_claim") == "none",
        "run claims performance",
    )
    require(
        record.get("renderer_timing_performed") is True,
        "run lacks renderer timing",
    )
    require(
        record.get("adaptation_timing_performed") is False,
        "run mixes adaptation timing",
    )
    require(
        record.get("measurement_stage") == MEASUREMENT_STAGE,
        "run measurement stage drifted",
    )
    require(record.get("clock") == CLOCK, "run clock drifted")
    require(
        record.get("order_algorithm") == ORDER_ALGORITHM,
        "run order algorithm drifted",
    )
    require(valid_slug(record.get("run_id")), "run identifier drifted")
    require(valid_sha256(record.get("randomization_seed")), "run seed drifted")
    require(
        isinstance(record.get("expected_pairs"), int),
        "run pair count drifted",
    )
    require(
        2 <= record["expected_pairs"] <= MAXIMUM_PAIRS,
        "run pair count is outside bounds",
    )
    require(
        isinstance(record.get("warmup_iterations"), int),
        "run warmup count drifted",
    )
    require(
        0 <= record["warmup_iterations"] <= MAXIMUM_WARMUPS,
        "run warmup count is outside bounds",
    )
    for field in ("lab_revision", "zed_revision", "alpine_revision"):
        require(valid_git_sha(record.get(field)), f"run {field} drifted")
    for field in (
        "trace_manifest_sha256",
        "patch_series_sha256",
        "scene_trace_sha256",
        "workload_hash",
        "equivalence_set_sha256",
        "fixture_equivalence_sha256",
        "alpine_sampler_sha256",
        "gpui_sampler_sha256",
        "alpine_aa_sha256",
        "gpui_aa_sha256",
        "cross_sha256",
        "adaptation_sha256",
        "environment_hash",
    ):
        require(valid_sha256(record.get(field)), f"run {field} drifted")
    window = record.get("window")
    require(isinstance(window, dict), "run window is missing")
    require(set(window) == set(WINDOW_FIELDS), "run window fields drifted")
    require(
        canonical_window_hash(window) == record["environment_hash"],
        "run environment hash drifted",
    )
    lanes = {}
    for lane, artifact_field, hash_field in (
        ("alpine", "alpine_aa_artifact", "alpine_aa_sha256"),
        ("gpui", "gpui_aa_artifact", "gpui_aa_sha256"),
        ("cross", "cross_artifact", "cross_sha256"),
    ):
        relative = normal_relative(record.get(artifact_field, ""))
        require(
            len(relative.parts) == 1,
            f"run {lane} artifact must stay inside its bundle",
        )
        sample_path = path / relative
        require(
            sha256_file(sample_path) == record[hash_field],
            f"run {lane} sample hash drifted",
        )
        lanes[lane] = parse_paired_csv(
            sample_path,
            record["run_id"],
            record["expected_pairs"],
        )
    adaptation_relative = normal_relative(record.get("adaptation_artifact", ""))
    require(
        len(adaptation_relative.parts) == 1,
        "adaptation artifact must stay inside its bundle",
    )
    adaptation = path / adaptation_relative
    regular_file(adaptation, "adaptation artifact")
    require(
        sha256_file(adaptation) == record["adaptation_sha256"],
        "adaptation artifact hash drifted",
    )
    return {
        "path": path,
        "manifest_path": manifest_path,
        "record": record,
        "window": window,
        "lanes": lanes,
        "adaptation": adaptation,
    }


def render_calibration(
    *,
    calibration_id: str,
    renderer: str,
    revision: str,
    workload_hash: str,
    warmups: int,
    raw_path: Path,
    windows: dict[str, dict[str, Any]],
    runs: list[dict[str, Any]],
) -> str:
    relative = raw_path.relative_to(ROOT).as_posix()
    lines = [
        f"schema = {toml_string(CALIBRATION_SCHEMA)}",
        f"id = {toml_string(calibration_id)}",
        'comparison_level = "renderer-only"',
        f"workload_hash = {toml_string(workload_hash)}",
        f"base_renderer = {toml_string(renderer)}",
        f"candidate_renderer = {toml_string(renderer)}",
        f"base_revision = {toml_string(revision)}",
        f"candidate_revision = {toml_string(revision)}",
        'metric = "frame-wall-time"',
        'unit = "nanoseconds"',
        'direction = "lower-is-better"',
        f"measurement_stage = {toml_string(MEASUREMENT_STAGE)}",
        f"clock = {toml_string(CLOCK)}",
        f"sample_class = {toml_string('cold' if warmups == 0 else 'warm')}",
        f"warmup_iterations = {warmups}",
        f"raw_samples_artifact = {toml_string(relative)}",
        f"raw_samples_sha256 = {toml_string(sha256_file(raw_path))}",
        'assumptions = ["Semantic and exact Metal equivalence passed before sampling.", "Each capture used one immutable prepared scene and one declared renderer-submit-readback stage."]',
        'exclusions = ["No confidence interval, effect-size decision, residency result, product latency result, or performance claim.", "Test-fixture windows prove protocol shape only; leased physical windows remain required for E4."]',
        "",
    ]
    for window_id in sorted(windows):
        lines.append(render_window(windows[window_id], "[[windows]]"))
        lines.append("")
    for run in runs:
        record = run["record"]
        lines.extend(
            [
                "[[runs]]",
                f"id = {toml_string(record['run_id'])}",
                f"window_id = {toml_string(run['window']['id'])}",
                f"randomization_seed = {toml_string(record['randomization_seed'])}",
                f"expected_pairs = {record['expected_pairs']}",
                "",
            ]
        )
    return "\n".join(lines)


def validate_calibration(binary: Path, manifest: Path) -> str:
    relative = manifest.relative_to(ROOT).as_posix()
    result = run_command([str(binary), "validate-aa-calibration", relative])
    require(
        result.returncode == 0,
        f"A/A validator rejected {relative}: {result.stderr.strip() or result.stdout.strip()}",
    )
    require(
        "no performance claim" in result.stdout,
        "A/A validator report lost the no-claim boundary",
    )
    return result.stdout


def compose(arguments: argparse.Namespace) -> None:
    output = artifact_path(arguments.output, must_exist=False)
    validator = executable(
        arguments.alpine_assurance,
        "Alpine assurance validator",
    )
    require(
        len(arguments.run) >= MINIMUM_RUNS,
        f"composition requires at least {MINIMUM_RUNS} runs",
    )
    runs = [load_run(value) for value in arguments.run]
    run_ids: set[str] = set()
    seeds: set[str] = set()
    windows: dict[str, dict[str, Any]] = {}
    leases: set[str] = set()
    identity: tuple[Any, ...] | None = None
    warmups: int | None = None
    adaptation_hash: str | None = None
    environment_kind: str | None = None
    for run in runs:
        record = run["record"]
        require(
            record["run_id"] not in run_ids,
            f"duplicate run identifier {record['run_id']}",
        )
        require(
            record["randomization_seed"] not in seeds,
            f"duplicate run seed {record['randomization_seed']}",
        )
        run_ids.add(record["run_id"])
        seeds.add(record["randomization_seed"])
        current_identity = (
            record["lab_revision"],
            record["zed_revision"],
            record["alpine_revision"],
            record["trace_manifest_sha256"],
            record["patch_series_sha256"],
            record["trace_schema"],
            record["trace_id"],
            record["trace_path"],
            record["scene_trace_sha256"],
            record["workload_hash"],
            record["measurement_stage"],
            record["clock"],
            record["alpine_sampler_sha256"],
            record["gpui_sampler_sha256"],
        )
        if identity is None:
            identity = current_identity
            warmups = record["warmup_iterations"]
            adaptation_hash = record["adaptation_sha256"]
            environment_kind = run["window"]["environment_kind"]
        require(
            current_identity == identity,
            f"run identity drifted: {record['run_id']}",
        )
        require(
            record["warmup_iterations"] == warmups,
            f"run warmup semantics drifted: {record['run_id']}",
        )
        require(
            record["adaptation_sha256"] == adaptation_hash,
            f"run adaptation evidence drifted: {record['run_id']}",
        )
        require(
            run["window"]["environment_kind"] == environment_kind,
            "composition cannot mix environment kinds",
        )
        window_id = run["window"]["id"]
        if window_id in windows:
            require(
                windows[window_id] == run["window"],
                f"window identity drifted: {window_id}",
            )
        else:
            require(
                run["window"]["lease_id"] not in leases,
                f"duplicate lease identity {run['window']['lease_id']}",
            )
            windows[window_id] = run["window"]
            leases.add(run["window"]["lease_id"])
    require(
        len(windows) >= MINIMUM_WINDOWS,
        f"composition requires at least {MINIMUM_WINDOWS} independent windows",
    )
    assert identity is not None and warmups is not None
    assert adaptation_hash is not None

    output.parent.mkdir(parents=True, exist_ok=True)
    reject_symlink_path(output.parent)
    output.mkdir()
    complete = False
    try:
        raw = output / "raw"
        raw.mkdir()
        lane_paths = {
            "alpine": raw / "alpine-aa.csv",
            "gpui": raw / "gpui-aa.csv",
            "cross": raw / "alpine-gpui.csv",
        }
        for lane, path in lane_paths.items():
            rows = [row for run in runs for row in run["lanes"][lane]]
            write_csv(path, rows)
        adaptation_path = output / "gpui-adaptation.toml"
        shutil.copyfile(runs[0]["adaptation"], adaptation_path)
        require(
            sha256_file(adaptation_path) == adaptation_hash,
            "composed adaptation evidence drifted",
        )

        alpine_manifest = output / "alpine-aa.toml"
        gpui_manifest = output / "gpui-aa.toml"
        alpine_manifest.write_text(
            render_calibration(
                calibration_id="alpine-direct-metal-aa",
                renderer="alpine-direct-metal",
                revision=identity[2],
                workload_hash=identity[9],
                warmups=warmups,
                raw_path=lane_paths["alpine"],
                windows=windows,
                runs=runs,
            ),
            encoding="utf-8",
        )
        gpui_manifest.write_text(
            render_calibration(
                calibration_id="zed-gpui-metal-aa",
                renderer="zed-gpui-metal",
                revision=identity[0],
                workload_hash=identity[9],
                warmups=warmups,
                raw_path=lane_paths["gpui"],
                windows=windows,
                runs=runs,
            ),
            encoding="utf-8",
        )
        alpine_validation = validate_calibration(validator, alpine_manifest)
        gpui_validation = validate_calibration(validator, gpui_manifest)
        (output / "alpine-aa-validation.log").write_text(
            alpine_validation,
            encoding="utf-8",
        )
        (output / "gpui-aa-validation.log").write_text(
            gpui_validation,
            encoding="utf-8",
        )

        run_lines = []
        for run in runs:
            record = run["record"]
            run_lines.extend(
                [
                    "[[runs]]",
                    f"id = {toml_string(record['run_id'])}",
                    f"window_id = {toml_string(run['window']['id'])}",
                    f"randomization_seed = {toml_string(record['randomization_seed'])}",
                    f"expected_pairs = {record['expected_pairs']}",
                    f"run_manifest_sha256 = {toml_string(sha256_file(run['manifest_path']))}",
                    "",
                ]
            )
        state = (
            "fixture-only"
            if environment_kind == "test-fixture"
            else "protocol-ready"
        )
        qualification = "\n".join(
            [
                f"schema = {toml_string(SET_SCHEMA)}",
                f"state = {toml_string(state)}",
                'comparison_level = "renderer-only"',
                f"lab_revision = {toml_string(identity[0])}",
                f"zed_revision = {toml_string(identity[1])}",
                f"alpine_revision = {toml_string(identity[2])}",
                f"trace_manifest_sha256 = {toml_string(identity[3])}",
                f"patch_series_sha256 = {toml_string(identity[4])}",
                f"trace_schema = {toml_string(identity[5])}",
                f"trace_id = {toml_string(identity[6])}",
                f"trace_path = {toml_string(identity[7])}",
                f"scene_trace_sha256 = {toml_string(identity[8])}",
                f"workload_hash = {toml_string(identity[9])}",
                f"measurement_stage = {toml_string(identity[10])}",
                f"clock = {toml_string(identity[11])}",
                f"alpine_sampler_sha256 = {toml_string(identity[12])}",
                f"gpui_sampler_sha256 = {toml_string(identity[13])}",
                f"warmup_iterations = {warmups}",
                f"run_count = {len(runs)}",
                f"window_count = {len(windows)}",
                f"pair_count = {sum(run['record']['expected_pairs'] for run in runs)}",
                'alpine_aa_manifest = "alpine-aa.toml"',
                f"alpine_aa_manifest_sha256 = {toml_string(sha256_file(alpine_manifest))}",
                'gpui_aa_manifest = "gpui-aa.toml"',
                f"gpui_aa_manifest_sha256 = {toml_string(sha256_file(gpui_manifest))}",
                'cross_artifact = "raw/alpine-gpui.csv"',
                f"cross_sha256 = {toml_string(sha256_file(lane_paths['cross']))}",
                'adaptation_artifact = "gpui-adaptation.toml"',
                f"adaptation_sha256 = {toml_string(adaptation_hash)}",
                "semantic_equivalence_required = true",
                "aa_controls_validated = true",
                "adaptation_timing_performed = false",
                "renderer_timing_performed = true",
                "residency_qualified = false",
                "statistics_qualified = false",
                "performance_qualified = false",
                'performance_claim = "none"',
                'exclusions = ["No confidence interval, effect-size decision, residency result, product latency result, or dominance claim.", "Fixture-only output cannot be promoted to physical evidence."]',
                "",
                *run_lines,
            ]
        )
        (output / "qualification.toml").write_text(
            qualification,
            encoding="utf-8",
        )
        complete = True
    finally:
        if not complete:
            shutil.rmtree(output, ignore_errors=True)
    print(
        f"composed {len(runs)} runs across {len(windows)} windows; "
        "aa_controls_validated=true performance_qualified=false performance_claim=none"
    )


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    subcommands = root.add_subparsers(dest="command", required=True)
    capture_parser = subcommands.add_parser(
        "capture",
        help="capture one bounded paired run",
    )
    capture_parser.add_argument("--output", required=True)
    capture_parser.add_argument("--equivalence", required=True)
    capture_parser.add_argument("--trace-id", required=True)
    capture_parser.add_argument("--window", required=True)
    capture_parser.add_argument("--run-id", required=True)
    capture_parser.add_argument("--seed", required=True)
    capture_parser.add_argument("--warmups", type=int, required=True)
    capture_parser.add_argument("--pairs", type=int, required=True)
    capture_parser.add_argument("--alpine-sampler", required=True)
    capture_parser.add_argument("--gpui-sampler", required=True)
    capture_parser.add_argument("--allow-test-fixture", action="store_true")
    capture_parser.set_defaults(handler=capture)

    compose_parser = subcommands.add_parser(
        "compose",
        help="compose complete runs into strict A/A inputs",
    )
    compose_parser.add_argument("--output", required=True)
    compose_parser.add_argument("--run", action="append", required=True)
    compose_parser.add_argument("--alpine-assurance", required=True)
    compose_parser.set_defaults(handler=compose)
    return root


def main() -> int:
    try:
        arguments = parser().parse_args()
        arguments.handler(arguments)
        return 0
    except ProtocolError as error:
        print(f"paired renderer protocol error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
