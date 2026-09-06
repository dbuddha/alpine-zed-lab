"""Fail-closed shape controls for GPUI diagnostic records, never E4 evidence."""

import csv
import hashlib
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("gpui_profile", ROOT / "scripts/validate_gpui_profile.py")
PROFILE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROFILE)


def row(index=0):
    return [str(index), "1", "2", "3", "4", "false", "", "5", "6", "false", "", "7", "28", "40", PROFILE.SCHEMA]


class GpuiProfileTests(unittest.TestCase):
    def validate(self, rows, expected=1):
        return PROFILE.validate_rows([list(PROFILE.FIELDS), *rows], expected)

    def test_valid_and_unavailable_stages(self):
        first, second = row(), row(1)
        second[5:7] = ["true", "12"]
        second[9:11] = ["true", "15"]
        self.assertEqual(self.validate([first, second], 2), 2)

    def test_empty_old_duplicate_or_missing_header_rejected(self):
        for header in ([], list(PROFILE.FIELDS[:-2]), list(PROFILE.FIELDS[:-1]), list(PROFILE.FIELDS) + ["caller_elapsed_ns"]):
            with self.subTest(header=header), self.assertRaises(ValueError):
                PROFILE.validate_rows([header, row()], 1)
        with self.assertRaises(ValueError):
            PROFILE.validate_rows([], 1)

    def test_wrong_row_version_rejected(self):
        for schema in ("", "alpine-zed-gpui-renderer-profile/v1", "alpine-zed-gpui-renderer-profile/v3"):
            value = row(); value[14] = schema
            with self.subTest(schema=schema), self.assertRaises(ValueError):
                self.validate([value])

    def test_sample_inventory_is_nonzero_exact_and_bounded(self):
        cases = (([], 1), ([row()], 0), ([row()], 100001), ([row()], 2), ([row(), row(1)], 1), ([row(1)], 1), ([row(), row()], 2))
        for rows, count in cases:
            with self.subTest(rows=rows, count=count), self.assertRaises(ValueError):
                self.validate(rows, count)

    def test_field_inventory_rejects_extra_or_missing(self):
        for value in (row()[:-1], row() + ["extra"]):
            with self.assertRaises(ValueError):
                self.validate([value])

    def test_caller_enclosure_and_nonzero_inner(self):
        for inner, caller in (("28", "0"), ("28", "27"), ("0", "40"), ("0", "0")):
            value = row(); value[12:14] = [inner, caller]
            with self.subTest(inner=inner, caller=caller), self.assertRaises(ValueError):
                self.validate([value])
        value = row(); value[12:14] = ["28", "28"]
        self.assertEqual(self.validate([value]), 1)

    def test_integer_enclosure_is_exact_above_float_precision(self):
        value = row(); value[12:14] = [str(2**53 + 1), str(2**53)]
        with self.assertRaises(ValueError):
            self.validate([value])
        value[12:14] = [str(PROFILE.MAX_U64)] * 2
        self.assertEqual(self.validate([value]), 1)

    def test_malformed_numbers_rejected(self):
        for malformed in ("", "-1", "+1", "1.0", "1e3", " 1", "01", str(2**64), "9" * 100):
            for column in (0, 1, 2, 3, 4, 7, 8, 11, 12, 13):
                value = row(); value[column] = malformed
                with self.subTest(value=malformed, column=column), self.assertRaises(ValueError):
                    self.validate([value])

    def test_optional_stages_must_match_flags(self):
        for flag, duration in (("false", "0"), ("true", ""), ("unknown", ""), ("0", ""), ("true", "-1")):
            for flag_column in (5, 9):
                value = row(); value[flag_column:flag_column + 2] = [flag, duration]
                with self.subTest(flag=flag, duration=duration, column=flag_column), self.assertRaises(ValueError):
                    self.validate([value])

    def test_file_and_cli_preserve_no_claim_boundary(self):
        with tempfile.TemporaryDirectory(prefix="gpui-profile-test-") as directory:
            path = Path(directory) / "profile.csv"
            with path.open("w", newline="") as output:
                csv.writer(output).writerows([PROFILE.FIELDS, row()])
            self.assertEqual(PROFILE.validate_file(path, 1), 1)
            command = [sys.executable, str(ROOT / "scripts/validate_gpui_profile.py"), str(path), "1"]
            result = subprocess.run(command, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("samples=1", result.stdout)
            self.assertIn("provenance_verified=false performance_qualified=false", result.stdout)
            path.write_text("stale,header\n")
            result = subprocess.run(command, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("rejected", result.stderr)
            self.assertEqual(result.stdout, "")

    def test_non_regular_symlink_oversize_and_malformed_file_rejected(self):
        with tempfile.TemporaryDirectory(prefix="gpui-profile-file-") as directory:
            root = Path(directory); path = root / "profile.csv"
            path.write_text('"unterminated\n')
            with self.assertRaises(csv.Error):
                PROFILE.validate_file(path, 1)
            link = root / "link"; link.symlink_to(path)
            with self.assertRaises(OSError):
                PROFILE.validate_file(link, 1)
            with self.assertRaises((OSError, ValueError)):
                PROFILE.validate_file(root, 1)
            with path.open("wb") as output:
                output.truncate(PROFILE.MAX_BYTES + 1)
            with self.assertRaises(ValueError):
                PROFILE.validate_file(path, 1)
            fifo = root / "fifo"; os.mkfifo(fifo)
            with self.assertRaises(ValueError):
                PROFILE.validate_file(fifo, 1)

    def test_ordinary_adapter_timer_and_endpoint_are_byte_unchanged(self):
        patch = (ROOT / "patches/alpine-metal/0002-add-gpui-renderer-sampling.patch").read_text()
        start = patch.index("+pub(super) fn benchmark_source(")
        end = patch.index("+fn profile_renderer()", start)
        source = "\n".join(line[1:] for line in patch[start:end].splitlines() if line.startswith("+")) + "\n"
        self.assertEqual(hashlib.sha256(source.encode()).hexdigest(), "d02eae559af9654078b657f65762e82622beccc8b6e766ec3f9f9698c1256023")


if __name__ == "__main__":
    unittest.main()
