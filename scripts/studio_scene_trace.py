#!/usr/bin/env python3
"""Convert hash-bound Studio observations into unqualified renderer candidates."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import math
import os
from pathlib import Path
import re
import stat
import struct
import sys


MAX_CAPTURE_BYTES = 33_554_432
MAX_ATLAS_BYTES = 16_777_216
MAX_TRACE_BYTES = 100_663_296
MAX_OPERATIONS = 65_536
MAX_CLIPS = 4_096
BASE_OMISSIONS = {
    "backing-scale-factor", "font-file-identities", "source-and-executable-identities",
    "document-identity-and-input-history", "native-window-identity",
    "renderer-trace-admission", "presentation-evidence",
}
RECT = ("x", "y", "width", "height")
COLOR = ("red", "green", "blue", "alpha")
ATLAS_RECT = ("atlas_x", "atlas_y", "atlas_width", "atlas_height")


class CaptureError(ValueError):
    """Input cannot be converted without guessing or dropping behavior."""


def require(condition, message):
    if not condition:
        raise CaptureError(message)


def fields(value, names, label):
    require(type(value) is dict and set(value) == set(names), label + " fields mismatch")


def integer(value, label, minimum=0, maximum=2**64 - 1):
    require(type(value) is int and minimum <= value <= maximum, label + " is out of bounds")
    return value


def f32(value, label):
    require(type(value) in (int, float), label + " must be numeric, not boolean")
    try:
        result = struct.unpack("!f", struct.pack("!f", float(value)))[0]
    except (OverflowError, struct.error) as error:
        raise CaptureError(label + " exceeds finite f32") from error
    require(math.isfinite(result), label + " must be finite")
    return result


def rectangle(value, label):
    result = {key: f32(value[key], label + "." + key) for key in RECT}
    require(result["width"] > 0 and result["height"] > 0, label + " must have positive extents")
    return result


def rgba(values, label):
    require(type(values) in (list, tuple) and len(values) == 4, label + " requires four channels")
    result = tuple(f32(value, label) for value in values)
    require(all(0 <= channel <= 1 for channel in result), label + " channels must be normalized")
    return result


def digest(bytes_):
    return hashlib.sha256(bytes_).hexdigest()


def hash_matches(bytes_, expected, label):
    require(type(expected) is str and re.fullmatch(r"[0-9a-f]{64}", expected), label + " needs SHA-256")
    require(digest(bytes_) == expected, label + " SHA-256 mismatch")


def read_bounded(path, limit):
    require(hasattr(os, "O_NOFOLLOW"), "host lacks required no-follow file opening")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as source:
        before = os.fstat(source.fileno())
        require(stat.S_ISREG(before.st_mode) and before.st_size <= limit, "input is not a bounded regular file")
        bytes_ = source.read(limit + 1)
        after = os.fstat(source.fileno())
    fingerprint = lambda value: (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
    require(len(bytes_) <= limit and len(bytes_) == before.st_size, "input length changed or exceeded its bound")
    require(fingerprint(before) == fingerprint(after), "input changed while being read")
    return bytes_


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key")
        result[key] = value
    return result


def json_number(text, convert):
    require(len(text) <= 64, "JSON numeric token exceeds f32/u64 capture bounds")
    return convert(text)


def reject_constant(_value):
    raise CaptureError("non-finite JSON constant")


def load_capture(path, capture_sha256, atlas_sha256):
    source = read_bounded(path, MAX_CAPTURE_BYTES)
    hash_matches(source, capture_sha256, "capture")
    raw = json.loads(
        source.decode("utf-8"), object_pairs_hook=unique_object,
        parse_int=lambda text: json_number(text, int),
        parse_float=lambda text: json_number(text, float),
        parse_constant=reject_constant,
    )
    fields(raw, "schema origin process_id capture_index capture_limit scene_revision visible_editor_lines renderer_trace_admitted timing_invalidated viewport counts omissions atlas clips operations".split(), "capture")
    require(raw["schema"] == "alpine-studio-scene-capture/v1", "unsupported raw capture schema")
    require(raw["origin"] == "studio-app-delegate-frame", "unsupported declared capture origin")
    require(raw["renderer_trace_admitted"] is False and raw["timing_invalidated"] is True, "capture cannot claim admission or timing")
    integer(raw["process_id"], "process id", 1, 2**32 - 1)
    integer(raw["capture_index"], "capture index", 0, 15)
    require(type(raw["capture_limit"]) is int and raw["capture_limit"] == 16, "capture limit must be 16")
    integer(raw["scene_revision"], "scene revision", 1)
    integer(raw["visible_editor_lines"], "visible editor lines", 1, MAX_OPERATIONS)
    fields(raw["viewport"], ("width", "height", "backing_scale_factor"), "viewport")
    require(raw["viewport"]["backing_scale_factor"] is None, "raw v1 cannot establish native backing scale")
    for key in ("width", "height"):
        raw["viewport"][key] = f32(raw["viewport"][key], "viewport " + key)
        require(raw["viewport"][key] > 0, "viewport must be positive")
    omissions = raw["omissions"]
    require(type(omissions) is list and len(omissions) <= 32, "invalid omission list")
    require(all(type(item) is str and 0 < len(item) <= 128 for item in omissions), "invalid omission entry")
    require(len(set(omissions)) == len(omissions) and BASE_OMISSIONS <= set(omissions), "required omissions are missing or duplicated")
    fields(raw["counts"], ("clips", "quads", "glyphs", "operations"), "counts")
    for key, count in raw["counts"].items():
        integer(count, key + " count", 0, MAX_CLIPS if key == "clips" else MAX_OPERATIONS)
    require(type(raw["clips"]) is list and len(raw["clips"]) == raw["counts"]["clips"], "clip count mismatch")
    for index, clip in enumerate(raw["clips"]):
        fields(clip, ("id",) + RECT, "clip")
        require(integer(clip["id"], "clip id") == index, "clip ids must follow their source array")
        clip.update(rectangle(clip, "clip"))
    atlas = raw["atlas"]
    pixels = b""
    if atlas is not None:
        fields(atlas, ("file", "width", "height", "revision", "bytes", "cumulative_row_patches"), "atlas")
        expected_name = "scene-{}-{:04}.a8".format(raw["process_id"], raw["capture_index"])
        require(atlas["file"] == expected_name, "atlas must be the exact PID/index-bound sibling")
        integer(atlas["width"], "atlas width", 1, 2**31 - 1)
        integer(atlas["height"], "atlas height", 1, 2**31 - 1)
        integer(atlas["revision"], "atlas revision", 1)
        integer(atlas["cumulative_row_patches"], "atlas patch count", 0, 64)
        expected_bytes = atlas["width"] * atlas["height"]
        require(integer(atlas["bytes"], "atlas bytes", 1, MAX_ATLAS_BYTES) == expected_bytes, "atlas dimensions/bytes mismatch")
        pixels = read_bounded(path.parent / expected_name, MAX_ATLAS_BYTES)
        require(len(pixels) == expected_bytes, "atlas sidecar length mismatch")
        hash_matches(pixels, atlas_sha256, "atlas")
    else:
        require(atlas_sha256 is None, "atlas hash supplied without an atlas")
    operations = raw["operations"]
    require(type(operations) is list and 0 < len(operations) <= MAX_OPERATIONS, "invalid operation count")
    require(len(operations) == raw["counts"]["operations"], "operation count mismatch")
    seen = {"solid-quad": set(), "monochrome-glyph": set()}
    for index, operation in enumerate(operations):
        require(type(operation) is dict and operation.get("kind") in seen, "unsupported primitive")
        kind = operation["kind"]
        names = ("sequence", "kind", "source_id", "clip") + RECT + COLOR
        fields(operation, names + (ATLAS_RECT if kind == "monochrome-glyph" else ()), "operation")
        require(integer(operation["sequence"], "sequence") == index, "painter sequence must be contiguous")
        source_id = integer(operation["source_id"], "source primitive id", 0, MAX_OPERATIONS - 1)
        require(source_id not in seen[kind], "duplicate source primitive")
        seen[kind].add(source_id)
        operation.update(rectangle(operation, "operation"))
        operation.update(zip(COLOR, rgba([operation[key] for key in COLOR], "operation color")))
        if operation["clip"] is not None:
            integer(operation["clip"], "operation clip", 0, len(raw["clips"]) - 1)
        if kind == "monochrome-glyph":
            require(atlas is not None, "glyph requires the captured atlas")
            for key in ATLAS_RECT:
                integer(operation[key], key, 1 if key.endswith(("width", "height")) else 0, 2**32 - 1)
            require(operation["atlas_x"] + operation["atlas_width"] <= atlas["width"], "glyph exceeds atlas width")
            require(operation["atlas_y"] + operation["atlas_height"] <= atlas["height"], "glyph exceeds atlas height")
    for kind, count_name in (("solid-quad", "quads"), ("monochrome-glyph", "glyphs")):
        require(seen[kind] == set(range(raw["counts"][count_name])), "source primitive count/identity mismatch")
    return raw, pixels


def float_text(value):
    text = format(value, ".9g")
    return text if "." in text or "e" in text.lower() else text + ".0"


def trace_chunks(raw, pixels, workload_id, workload_hash, viewport, clear):
    yield b'schema = "alpine-scene-trace/v2"\n'
    yield ('id = "' + workload_id + '"\n').encode("ascii")
    yield ('workload_hash = "' + workload_hash + '"\n').encode("ascii")
    yield ("revision = {}\nclear_color = [{}]\n".format(raw["scene_revision"], ", ".join(map(float_text, clear)))).encode("ascii")
    if not raw["clips"]:
        yield b"clips = []\n"
    if raw["atlas"] is None:
        yield b"resources = []\n"
    yield b"\n[viewport]\n"
    for key in ("width", "height", "scale_factor", "pixel_width", "pixel_height"):
        value = str(viewport[key]) if key.startswith("pixel_") else float_text(viewport[key])
        yield (key + " = " + value + "\n").encode("ascii")
    atlas = raw["atlas"]
    if atlas is not None:
        yield b'\n[[resources]]\nid = "editor-atlas"\nkind = "a8-atlas"\n'
        yield ('content_hash = "' + digest(pixels) + '"\n').encode("ascii")
        for key in ("revision", "width", "height"):
            yield (key + " = " + str(atlas[key]) + "\n").encode("ascii")
        yield b"pixels = [\n"
        for offset in range(0, len(pixels), 64):
            yield ("  " + ", ".join(map(str, pixels[offset:offset + 64])) + ",\n").encode("ascii")
        yield b"]\n"
    for clip in raw["clips"]:
        yield ('\n[[clips]]\nid = "clip-{}"\n'.format(clip["id"])).encode("ascii")
        for key in RECT:
            yield (key + " = " + float_text(clip[key]) + "\n").encode("ascii")
    for operation in raw["operations"]:
        yield ('\n[[operations]]\nsequence = {}\nkind = "{}"\n'.format(operation["sequence"], operation["kind"])).encode("ascii")
        if operation["kind"] == "monochrome-glyph":
            yield b'resource = "editor-atlas"\n'
        if operation["clip"] is not None:
            yield ('clip = "clip-{}"\n'.format(operation["clip"])).encode("ascii")
        for key in RECT + COLOR:
            yield (key + " = " + float_text(operation[key]) + "\n").encode("ascii")
        if operation["kind"] == "monochrome-glyph":
            for key in ATLAS_RECT:
                yield (key + " = " + str(operation[key]) + "\n").encode("ascii")


def canonical_lines(lines):
    result = hashlib.sha256()
    found = 0
    for line in lines:
        if line.startswith(b"workload_hash = "):
            found += 1
        else:
            result.update(line)
    require(found == 1, "trace needs exactly one canonical workload hash line")
    return result.hexdigest()


def canonical_workload_hash(source):
    # BytesIO iterates LF-delimited, newline-inclusive lines, matching Rust's
    # split_inclusive('\n'); do not normalize line endings or TOML values.
    return canonical_lines(io.BytesIO(source))


def publish(path, chunks, limit):
    partial = path.with_name(path.name + ".incomplete")
    descriptor = os.open(partial, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    result = hashlib.sha256()
    size = 0
    with os.fdopen(descriptor, "wb") as output:
        for chunk in chunks:
            require(size + len(chunk) <= limit, "candidate output exceeds its byte limit")
            output.write(chunk)
            result.update(chunk)
            size += len(chunk)
        output.flush()
        os.fsync(output.fileno())
    os.link(partial, path)
    partial.unlink()
    return result.hexdigest(), size


def convert(capture_path, output_directory, *, capture_sha256, atlas_sha256=None,
            workload_id, scale_factor, pixel_width, pixel_height, clear_color):
    require(type(workload_id) is str and len(workload_id) <= 128 and re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", workload_id), "workload id must be a bounded lowercase slug")
    capture_path, output_directory = Path(capture_path), Path(output_directory)
    raw, pixels = load_capture(capture_path, capture_sha256, atlas_sha256)
    scale = f32(scale_factor, "supplied scale factor")
    require(scale > 0, "supplied scale factor must be positive")
    viewport = dict(width=raw["viewport"]["width"], height=raw["viewport"]["height"], scale_factor=scale)
    for logical, physical in (("width", pixel_width), ("height", pixel_height)):
        integer(physical, "supplied pixel " + logical, 1, 2**31 - 1)
        scaled = viewport[logical] * scale
        require(physical - 0.5 <= scaled < physical + 0.5, "supplied physical viewport disagrees with logical scale")
        viewport["pixel_" + logical] = physical
    clear = rgba(clear_color, "supplied clear color")
    require(clear[3] == 1.0, "v2 requires an opaque clear color")
    workload_hash = canonical_lines(trace_chunks(raw, pixels, workload_id, "0" * 64, viewport, clear))
    output_directory.mkdir(mode=0o700)
    trace_sha, trace_bytes = publish(
        output_directory / "scene.toml",
        trace_chunks(raw, pixels, workload_id, workload_hash, viewport, clear), MAX_TRACE_BYTES,
    )
    report = {
        "schema": "alpine-studio-trace-candidate/v1", "state": "candidate-only",
        "trace_schema": "alpine-scene-trace/v2", "trace_file": "scene.toml",
        "trace_sha256": trace_sha, "trace_bytes": trace_bytes, "workload_hash": workload_hash,
        "input_capture_sha256": capture_sha256, "input_atlas_sha256": atlas_sha256,
        "source_process_id": raw["process_id"], "capture_index": raw["capture_index"],
        "source_scene_revision": raw["scene_revision"], "visible_editor_lines": raw["visible_editor_lines"],
        "counts": raw["counts"], "supplied_viewport": viewport, "supplied_clear_color": clear,
        "float_policy": "ieee754-f32-before-nine-digit-serialization",
        "production_origin_verified": False, "native_backing_scale_verified": False,
        "native_clear_color_verified": False, "renderer_output_equivalence": False,
        "physical_qualification": False, "performance_qualified": False,
        "unresolved_omissions": sorted(set(raw["omissions"]) | {
            "native-clear-color", "capture-origin-authenticity",
            "representative-workload-rationale", "semantic-and-pixel-equivalence",
        }),
    }
    encoded = (json.dumps(report, indent=2, sort_keys=True, allow_nan=False) + "\n").encode("utf-8")
    publish(output_directory / "candidate.json", (encoded,), 65_536)
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--capture-sha256", required=True)
    parser.add_argument("--atlas-sha256")
    parser.add_argument("--id", dest="workload_id", required=True)
    parser.add_argument("--scale-factor", type=float, required=True)
    parser.add_argument("--pixel-width", type=int, required=True)
    parser.add_argument("--pixel-height", type=int, required=True)
    parser.add_argument("--clear-color", type=float, nargs=4, required=True)
    args = vars(parser.parse_args(argv))
    capture, output = args.pop("capture"), args.pop("output")
    try:
        report = convert(capture, output, **args)
    except (OSError, ValueError, RecursionError, UnicodeError) as error:
        print("Studio candidate conversion rejected: " + str(error)[:2048], file=sys.stderr)
        return 1
    print(json.dumps(report, sort_keys=True, allow_nan=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
