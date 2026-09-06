import csv
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts/paired_renderer_samples.py"
SPEC = importlib.util.spec_from_file_location("paired_renderer_samples", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
PAIRED = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PAIRED)


class PairedRendererSamplesTests(unittest.TestCase):
    @staticmethod
    def temporary_directory():
        parent = PAIRED.ROOT / "artifacts"
        parent.mkdir(exist_ok=True)
        return tempfile.TemporaryDirectory(dir=parent)

    def test_balanced_orders_are_deterministic_and_bidirectional(self):
        seed = "1" * 64
        for count in (2, 3, 20):
            first = PAIRED.balanced_orders(seed, "cross-renderer", count)
            second = PAIRED.balanced_orders(seed, "cross-renderer", count)
            self.assertEqual(first, second)
            self.assertIn("base-first", first)
            self.assertIn("candidate-first", first)
            self.assertLessEqual(
                abs(first.count("base-first") - first.count("candidate-first")),
                1,
            )
        self.assertNotEqual(
            PAIRED.balanced_orders(seed, "alpine-aa", 20),
            PAIRED.balanced_orders(seed, "gpui-aa", 20),
        )

    def test_single_sample_parser_rejects_header_count_and_zero(self):
        with self.temporary_directory() as directory:
            path = Path(directory) / "sample.csv"
            path.write_text(
                "sample_index,elapsed_ns\n0,17\n",
                encoding="utf-8",
            )
            self.assertEqual(PAIRED.parse_sample_csv(path), 17)
            for source in (
                "wrong,header\n0,17\n",
                "sample_index,elapsed_ns\n0,0\n",
                "sample_index,elapsed_ns\n0,17\n1,18\n",
            ):
                path.write_text(source, encoding="utf-8")
                with self.assertRaises(PAIRED.ProtocolError):
                    PAIRED.parse_sample_csv(path)

    def test_paired_parser_rejects_gaps_and_one_sided_order(self):
        with self.temporary_directory() as directory:
            path = Path(directory) / "paired.csv"
            with path.open("w", newline="", encoding="utf-8") as target:
                writer = csv.writer(target)
                writer.writerow(PAIRED.CSV_HEADER)
                writer.writerow(["run-01", 0, "base-first", 10, 11])
                writer.writerow(["run-01", 1, "candidate-first", 12, 13])
            rows = PAIRED.parse_paired_csv(path, "run-01", 2)
            self.assertEqual(len(rows), 2)
            path.write_text(
                "run_id,pair_index,order,base,candidate\n"
                "run-01,0,base-first,10,11\n"
                "run-01,2,base-first,12,13\n",
                encoding="utf-8",
            )
            with self.assertRaises(PAIRED.ProtocolError):
                PAIRED.parse_paired_csv(path, "run-01", 2)

    def test_window_hash_changes_with_environment_identity(self):
        window = {
            "id": "window-01",
            "lease_id": "fixture-lease-01",
            "environment_kind": "test-fixture",
            "hardware_id": "fixture-hardware",
            "hardware_model": "fixture-model",
            "gpu": "fixture-gpu",
            "memory_bytes": 1,
            "os_build": "fixture-os",
            "xcode_build": "fixture-xcode",
            "rustc": "fixture-rustc",
            "runner_image": "fixture-runner",
            "power_state": "fixed-ac",
            "thermal_policy": "fixture-nominal",
            "display_state": "headless-fixed",
            "shader_mode": "offline-metallib",
            "validation_enabled": False,
            "started_at_utc": "2026-08-01T00:00:00Z",
            "ended_at_utc": "2026-08-01T01:00:00Z",
        }
        first = PAIRED.canonical_window_hash(window)
        window["gpu"] = "different-gpu"
        self.assertNotEqual(first, PAIRED.canonical_window_hash(window))

    def test_independent_windows_reject_overlap_but_accept_adjacency(self):
        first = {
            "id": "window-01",
            "started_at_utc": "2026-08-01T00:00:00Z",
            "ended_at_utc": "2026-08-01T01:00:00Z",
        }
        second = {
            "id": "window-02",
            "started_at_utc": "2026-08-01T01:00:00Z",
            "ended_at_utc": "2026-08-01T02:00:00Z",
        }
        PAIRED.validate_independent_windows([second, first])
        second["started_at_utc"] = "2026-08-01T00:59:59Z"
        with self.assertRaisesRegex(PAIRED.ProtocolError, "hardware windows overlap"):
            PAIRED.validate_independent_windows([first, second])

    def test_nearest_rank_and_rounded_ratio_are_integer_deterministic(self):
        values = [10, 20, 30, 40]
        self.assertEqual(PAIRED.nearest_rank(values, 5_000), 20)
        self.assertEqual(PAIRED.nearest_rank(values, 9_500), 40)
        self.assertEqual(PAIRED.rounded_ratio(1_000_000, 3), 333_333)
        self.assertEqual(PAIRED.rounded_ratio(-1_000_000, 3), -333_333)

    def test_bootstrap_interval_is_repeatable_and_contains_constant(self):
        seed = "a" * 64
        first = PAIRED.bootstrap_median_interval([7] * 20, seed, 1_000)
        second = PAIRED.bootstrap_median_interval([7] * 20, seed, 1_000)
        self.assertEqual(first, (7, 7))
        self.assertEqual(first, second)

    def test_composed_parser_rejects_unknown_and_duplicate_runs(self):
        bindings = {"run-01": ("window-01", 2)}
        with self.temporary_directory() as directory:
            path = Path(directory) / "composed.csv"
            path.write_text(
                "run_id,pair_index,order,base,candidate\n"
                "run-01,0,base-first,10,11\n"
                "run-01,1,candidate-first,12,13\n",
                encoding="utf-8",
            )
            self.assertEqual(len(PAIRED.parse_composed_csv(path, bindings)), 2)
            path.write_text(
                "run_id,pair_index,order,base,candidate\n"
                "run-01,0,base-first,10,11\n"
                "run-01,0,candidate-first,12,13\n",
                encoding="utf-8",
            )
            with self.assertRaises(PAIRED.ProtocolError):
                PAIRED.parse_composed_csv(path, bindings)

    def make_rejected_source(self, directory):
        output = Path(directory) / "attempt"
        output.mkdir(mode=0o700)
        (output / "invocations").mkdir()
        (output / PAIRED.INCOMPLETE_CAPTURE).write_text("incomplete\n")
        sample = output / "invocations/alpine-aa-0000-0-base-alpine.csv"
        sample.write_bytes(b"sample_index,elapsed_ns\n0,17\n")
        return output, sample

    def test_rejected_copy_is_private_hash_bound_unique_and_non_destructive(self):
        with self.temporary_directory() as directory:
            output, sample = self.make_rejected_source(directory)
            (output / "run.toml").write_text("unpublished manifest\n")
            context = {"phase": "manifest-publication", "invocation": None}
            first = PAIRED.retain_rejected_capture(output, context, OSError("publication failed"))
            original_receipt = (first / "rejection.json").read_bytes()
            second = PAIRED.retain_rejected_capture(output, context, OSError("publication failed"))
            self.assertNotEqual(first, second)
            self.assertEqual((first / "rejection.json").read_bytes(), original_receipt)
            self.assertEqual(first.stat().st_mode & 0o777, 0o700)
            record = json.loads(original_receipt)
            self.assertEqual(record["state"], "rejected")
            self.assertFalse(record["performance_qualified"])
            self.assertEqual(record["performance_claim"], "none")
            self.assertTrue(record["original_preserved"])
            self.assertTrue(sample.is_file())
            self.assertFalse(any(path.name == "run.toml" for path in first.rglob("*")))
            for item in record["files"]:
                payload = (first / item["retained_path"]).read_bytes()
                self.assertEqual(hashlib.sha256(payload).hexdigest(), item["retained_sha256"])
                self.assertEqual(len(payload), item["retained_bytes"])
            with self.assertRaisesRegex(PAIRED.ProtocolError, "capture is incomplete"):
                PAIRED.regular_file(output / "run.toml", "run manifest")

    def test_rejected_prefix_and_total_budgets_preserve_full_originals(self):
        with self.temporary_directory() as directory:
            output, sample = self.make_rejected_source(directory)
            sample.write_bytes(b"x" * (PAIRED.REJECTED_FILE_BYTES + 1))
            context = {"phase": "validation", "invocation": {"csv": str(sample)}}
            rejected = PAIRED.retain_rejected_capture(output, context, ValueError("oversized"))
            record = json.loads((rejected / "rejection.json").read_text())
            item = next(value for value in record["files"] if value["source"].endswith(".csv"))
            self.assertEqual(item["retained_bytes"], PAIRED.REJECTED_FILE_BYTES)
            self.assertTrue(item["truncated"])
            self.assertIsNone(item["source_sha256"])
            self.assertEqual(sample.stat().st_size, PAIRED.REJECTED_FILE_BYTES + 1)
            with mock.patch.object(PAIRED, "REJECTED_PAYLOAD_BYTES", 10):
                limited = PAIRED.retain_rejected_capture(output, context, ValueError("limited"))
            limited_record = json.loads((limited / "rejection.json").read_text())
            self.assertEqual(limited_record["payload_bytes"], 10)
            self.assertEqual(sum(item["retained_bytes"] for item in limited_record["files"]), 10)
            self.assertTrue(any(item["retained_path"] is None for item in limited_record["files"]))

    def test_rejected_copy_refuses_symlinks_hardlinks_unknown_paths_and_file_overflow(self):
        for kind in ("symlink", "hardlink", "unknown", "overflow"):
            with self.subTest(kind=kind), self.temporary_directory() as directory:
                output, sample = self.make_rejected_source(directory)
                external = Path(directory) / "outside.txt"
                external.write_text("outside sentinel\n")
                if kind in ("symlink", "hardlink"):
                    sample.unlink()
                    if kind == "symlink":
                        sample.symlink_to(external)
                    else:
                        os.link(external, sample)
                elif kind == "unknown":
                    (output / "unexpected").mkdir()
                with mock.patch.object(PAIRED, "REJECTED_MAXIMUM_FILES", 0 if kind == "overflow" else PAIRED.REJECTED_MAXIMUM_FILES):
                    with self.assertRaises(PAIRED.ProtocolError):
                        PAIRED.retain_rejected_capture(output, {}, ValueError("invalid"))
                self.assertEqual(external.read_text(), "outside sentinel\n")
                self.assertTrue(output.is_dir())

    def test_rejected_copy_hash_manifest_budget_and_creation_failures_leave_originals(self):
        for failure in ("hash", "manifest-budget", "creation"):
            with self.subTest(failure=failure), self.temporary_directory() as directory:
                output, sample = self.make_rejected_source(directory)
                before = sample.read_bytes()
                if failure == "hash":
                    patch = mock.patch.object(PAIRED, "sha256_file", return_value="0" * 64)
                elif failure == "manifest-budget":
                    patch = mock.patch.object(PAIRED, "REJECTED_MANIFEST_BYTES", 1)
                else:
                    patch = mock.patch.object(PAIRED.tempfile, "mkdtemp", side_effect=OSError("retention unavailable"))
                with patch, self.assertRaises((PAIRED.ProtocolError, OSError)):
                    PAIRED.retain_rejected_capture(output, {}, ValueError("failure"))
                self.assertEqual(sample.read_bytes(), before)
                self.assertFalse(list(Path(directory).glob(".rejected-paired-*/rejection.json")))

    def test_real_sampler_timeout_preserves_partial_streams_and_unknown_status(self):
        with self.temporary_directory() as directory:
            output, sample = self.make_rejected_source(directory)
            sample.unlink()
            sampler = Path(directory) / "timeout-sampler"
            sampler.write_text(
                f"#!{sys.executable}\nimport sys, time\n"
                "print('partial-timeout-stdout', flush=True)\n"
                "print('partial-timeout-stderr', file=sys.stderr, flush=True)\n"
                "time.sleep(30)\n"
            )
            sampler.chmod(0o700)
            log = sample.with_suffix(".log")
            context = {}
            with mock.patch.object(PAIRED, "SAMPLER_TIMEOUT_SECONDS", 1):
                with self.assertRaises(PAIRED.ProtocolError) as caught:
                    PAIRED.invoke_sampler("alpine", sampler, {"absolute_path": "unused"}, sample, 2, log, context)
            self.assertIsInstance(caught.exception.__cause__, subprocess.TimeoutExpired)
            retained = log.read_text()
            self.assertIn("partial-timeout-stdout", retained)
            self.assertIn("partial-timeout-stderr", retained)
            self.assertIn("returncode=unavailable", retained)
            self.assertEqual(context["invocation"]["state"], "timeout")
            self.assertIsNone(context["invocation"]["returncode"])

    def test_spawn_failure_and_output_collision_do_not_invent_success(self):
        with self.temporary_directory() as directory:
            output, sample = self.make_rejected_source(directory)
            log = sample.with_suffix(".log")
            with self.assertRaisesRegex(PAIRED.ProtocolError, "sampler output collision"):
                PAIRED.invoke_sampler("alpine", Path(directory) / "missing", {"absolute_path": "unused"}, sample, 2, log)
            self.assertFalse(log.exists())
            sample.unlink()
            context = {}
            with self.assertRaises(PAIRED.ProtocolError):
                PAIRED.invoke_sampler("alpine", Path(directory) / "missing", {"absolute_path": "unused"}, sample, 2, log, context)
            self.assertEqual(context["invocation"]["state"], "execution-error")
            self.assertIsNone(context["invocation"]["returncode"])
            self.assertIn("returncode=unavailable", log.read_text())


if __name__ == "__main__":
    unittest.main()
