#!/usr/bin/env python3
"""Validate diagnostic GPUI profile/v2 shape, not provenance or qualification."""

import argparse
import csv
import os
from pathlib import Path
import re
import stat
import sys

SCHEMA = "alpine-zed-gpui-renderer-profile/v2"
FIELDS = (
    "sample_index", "resource_preparation_ns", "instance_write_ns",
    "command_buffer_ns", "render_encoding_ns", "readback_encoding_performed",
    "readback_encoding_ns", "commit_ns", "completion_wait_ns",
    "gpu_execution_available", "gpu_execution_ns", "readback_compaction_ns",
    "total_ns", "caller_elapsed_ns", "schema",
)
MAX_SAMPLES = 100_000
MAX_BYTES = 64 * 1024 * 1024
MAX_U64 = (1 << 64) - 1


def unsigned(value):
    if len(value) > 20 or re.fullmatch(r"0|[1-9][0-9]*", value) is None:
        raise ValueError("duration or index is not canonical unsigned decimal")
    result = int(value)
    if result > MAX_U64:
        raise ValueError("duration or index exceeds u64")
    return result


def validate_rows(rows, expected_samples):
    if not 1 <= expected_samples <= MAX_SAMPLES:
        raise ValueError("expected sample count must be in 1..100000")
    rows = iter(rows)
    if next(rows, None) != list(FIELDS):
        raise ValueError("expected exact GPUI profile/v2 header with caller and schema")
    count = 0
    for index, row in enumerate(rows):
        if index >= expected_samples or len(row) != len(FIELDS):
            raise ValueError("unexpected row count or field count")
        numbers = {column: unsigned(row[column]) for column in (0, 1, 2, 3, 4, 7, 8, 11, 12, 13)}
        if numbers[0] != index:
            raise ValueError("sample indexes must be contiguous from zero")
        if row[14] != SCHEMA:
            raise ValueError("profile row has a stale or unknown schema")
        for flag, value in ((5, 6), (9, 10)):
            if row[flag] == "true":
                unsigned(row[value])
            elif row[flag] != "false" or row[value] != "":
                raise ValueError("optional duration and availability disagree")
        if numbers[12] == 0 or numbers[13] < numbers[12]:
            raise ValueError("caller must enclose a nonzero internal total")
        count += 1
    if count != expected_samples:
        raise ValueError("missing required samples")
    return count


def validate_file(path, expected_samples):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "r", encoding="ascii", newline="") as source:
        before = os.fstat(source.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_size > MAX_BYTES:
            raise ValueError("profile input must be a bounded regular file")
        count = validate_rows(csv.reader(source, strict=True), expected_samples)
        after = os.fstat(source.fileno())
        identity = lambda item: (item.st_dev, item.st_ino, item.st_size, item.st_mtime_ns, item.st_ctime_ns)
        if identity(before) != identity(after):
            raise ValueError("profile input changed during validation")
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv", type=Path)
    parser.add_argument("expected_samples", type=int)
    arguments = parser.parse_args()
    try:
        count = validate_file(arguments.csv, arguments.expected_samples)
    except (OSError, ValueError, UnicodeError, csv.Error) as error:
        print(f"GPUI profile rejected: {error}", file=sys.stderr)
        return 1
    print(
        f"schema=alpine-zed-gpui-profile-validation/v1 profile_schema={SCHEMA} "
        f"samples={count} caller_endpoint=owned-image-return "
        "provenance_verified=false performance_qualified=false"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
