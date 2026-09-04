import csv
import importlib.util
import tempfile
import unittest
from pathlib import Path


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


if __name__ == "__main__":
    unittest.main()
