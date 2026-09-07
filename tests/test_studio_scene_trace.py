"""Synthetic converter controls; none is a captured Studio workload."""

import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
from contextlib import redirect_stderr, redirect_stdout


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("studio_scene_trace", ROOT / "scripts/studio_scene_trace.py")
CONVERTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONVERTER)


def fixture():
    background = dict(sequence=0, kind="solid-quad", source_id=0, clip=None,
                      x=0.0, y=0.0, width=4.0, height=2.0,
                      red=0.0, green=0.0, blue=1.0, alpha=1.0)
    glyph = dict(sequence=1, kind="monochrome-glyph", source_id=0, clip=0,
                 x=0.0, y=0.0, width=2.0, height=2.0,
                 red=1.0, green=1.0, blue=1.0, alpha=1.0,
                 atlas_x=0, atlas_y=0, atlas_width=2, atlas_height=2)
    foreground = dict(background, sequence=2, source_id=1, clip=0, width=1.0,
                      height=1.0, red=1.0, blue=0.0)
    return dict(
        schema="alpine-studio-scene-capture/v1", origin="studio-app-delegate-frame",
        process_id=123, capture_index=0, capture_limit=16, scene_revision=7,
        visible_editor_lines=1, renderer_trace_admitted=False, timing_invalidated=True,
        viewport=dict(width=4.0, height=2.0, backing_scale_factor=None),
        counts=dict(clips=1, quads=2, glyphs=1, operations=3),
        omissions=sorted(CONVERTER.BASE_OMISSIONS),
        atlas=dict(file="scene-123-0000.a8", width=2, height=2, revision=5, bytes=4,
                   cumulative_row_patches=0),
        clips=[dict(id=0, x=0.0, y=0.0, width=4.0, height=2.0)],
        operations=[background, glyph, foreground],
    )


class StudioSceneTraceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="studio-converter-control-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.capture = self.root / "synthetic-capture.json"
        self.atlas = self.root / "scene-123-0000.a8"
        self.atlas.write_bytes(bytes([255, 0, 0, 255]))
        self.output = self.root / "candidate"
        self.raw = fixture()

    def arguments(self, raw=None):
        self.capture.write_text(json.dumps(self.raw if raw is None else raw), encoding="utf-8")
        return dict(capture_sha256=hashlib.sha256(self.capture.read_bytes()).hexdigest(),
                    atlas_sha256=hashlib.sha256(self.atlas.read_bytes()).hexdigest(),
                    workload_id="synthetic-converter-control", scale_factor=2.0,
                    pixel_width=8, pixel_height=4, clear_color=[0.0, 0.0, 0.0, 1.0])

    def convert(self, raw=None, **overrides):
        args = self.arguments(raw)
        args.update(overrides)
        return CONVERTER.convert(self.capture, self.output, **args)

    def rejects(self, raw=None, **overrides):
        with self.assertRaises((CONVERTER.CaptureError, OSError)):
            self.convert(raw, **overrides)
        self.assertFalse(self.output.exists())

    def test_canonical_hash_omits_only_the_complete_hash_line(self):
        body = b'schema = "example"\r\nid = "control"\n'
        source = b'schema = "example"\r\nworkload_hash = "anything"\r\nid = "control"\n'
        self.assertEqual(CONVERTER.canonical_workload_hash(source), hashlib.sha256(body).hexdigest())
        self.assertNotEqual(CONVERTER.canonical_workload_hash(source), hashlib.sha256(body.replace(b"\r\n", b"\n")).hexdigest())
        for invalid in (body, source + b'workload_hash = "again"\n'):
            with self.assertRaises(CONVERTER.CaptureError):
                CONVERTER.canonical_workload_hash(invalid)

    def test_success_preserves_order_identity_atlas_and_unqualified_status(self):
        report = self.convert()
        trace = (self.output / "scene.toml").read_bytes()
        text = trace.decode("ascii")
        self.assertEqual(report["trace_sha256"], hashlib.sha256(trace).hexdigest())
        self.assertEqual(report["workload_hash"], CONVERTER.canonical_workload_hash(trace))
        self.assertIn('workload_hash = "' + report["workload_hash"] + '"', text)
        self.assertIn('content_hash = "' + hashlib.sha256(self.atlas.read_bytes()).hexdigest() + '"', text)
        self.assertIn("255, 0, 0, 255,", text)
        self.assertIn('clip = "clip-0"', text)
        self.assertIn("scale_factor = 2.0\npixel_width = 8\npixel_height = 4", text)
        operations = text.split("[[operations]]")[1:]
        self.assertEqual(len(operations), 3)
        for index, operation in enumerate(operations):
            self.assertIn("sequence = " + str(index), operation)
        self.assertIn('kind = "monochrome-glyph"', operations[1])
        self.assertIn("red = 1.0", operations[2])
        self.assertNotIn("source_id", text)
        self.assertEqual(report["source_process_id"], 123)
        self.assertEqual(report["state"], "candidate-only")
        for field in ("production_origin_verified", "native_backing_scale_verified", "native_clear_color_verified", "renderer_output_equivalence", "physical_qualification", "performance_qualified"):
            self.assertIs(report[field], False)
        self.assertIn("native-clear-color", report["unresolved_omissions"])
        self.assertFalse((self.output / "run.toml").exists())
        stored = json.loads((self.output / "candidate.json").read_text())
        self.assertEqual(stored["workload_hash"], report["workload_hash"])

    def test_quad_only_and_empty_clip_array_remain_valid_candidates(self):
        raw = fixture()
        raw["atlas"] = None
        raw["clips"] = []
        raw["operations"] = [raw["operations"][0]]
        raw["counts"] = dict(clips=0, quads=1, glyphs=0, operations=1)
        self.convert(raw, atlas_sha256=None)
        text = (self.output / "scene.toml").read_text()
        self.assertIn("clips = []\nresources = []\n\n[viewport]", text)
        self.assertNotIn("[[resources]]", text)

    def test_f32_and_signed_zero_serialization(self):
        self.assertEqual(CONVERTER.float_text(CONVERTER.f32(-0.0, "x")), "-0.0")
        self.assertEqual(CONVERTER.float_text(CONVERTER.f32(0.1, "x")), "0.100000001")
        for invalid in (True, float("inf"), float("nan"), 1e100):
            with self.assertRaises(CONVERTER.CaptureError):
                CONVERTER.f32(invalid, "x")

    def test_missing_unknown_and_qualification_fields_are_rejected(self):
        for key, value in (("renderer_trace_admitted", True), ("timing_invalidated", False),
                           ("capture_limit", True), ("capture_index", 16), ("process_id", 0),
                           ("visible_editor_lines", 0), ("schema", "new-schema")):
            with self.subTest(key=key):
                raw = fixture()
                raw[key] = value
                self.rejects(raw)
        raw = fixture()
        raw["unreviewed"] = 1
        self.rejects(raw)
        raw = fixture()
        raw["omissions"].remove("font-file-identities")
        self.rejects(raw)

    def test_invalid_operation_mutations_are_rejected(self):
        cases = (("sequence", 9), ("source_id", 8), ("kind", "shadow"), ("clip", 1),
                 ("width", 0), ("height", 1e-100), ("x", True), ("red", 2),
                 ("atlas_x", 2), ("atlas_height", 0))
        for key, value in cases:
            with self.subTest(key=key):
                raw = fixture()
                raw["operations"][1][key] = value
                self.rejects(raw)
        raw = fixture()
        raw["operations"][2]["source_id"] = 0
        self.rejects(raw)
        raw = fixture()
        raw["operations"][0]["atlas_x"] = 0
        self.rejects(raw)

    def test_mismatched_counts_clips_and_atlas_are_rejected(self):
        for key in ("clips", "quads", "glyphs", "operations"):
            raw = fixture()
            raw["counts"][key] += 1
            self.rejects(raw)
        for key, value in (("file", "../unowned.a8"), ("bytes", 5), ("width", 0),
                           ("revision", 0), ("cumulative_row_patches", 65)):
            raw = fixture()
            raw["atlas"][key] = value
            self.rejects(raw)
        raw = fixture()
        raw["clips"][0]["id"] = 1
        self.rejects(raw)

    def test_tampered_hashes_and_short_sidecar_are_rejected(self):
        self.rejects(capture_sha256="0" * 64)
        self.rejects(atlas_sha256="0" * 64)
        self.atlas.write_bytes(b"short")
        self.rejects()

    def test_duplicate_json_keys_and_nonfinite_constants_are_rejected(self):
        for source in (b'{"schema":1,"schema":2}', b'{"value":NaN}', b'{"value":' + b"9" * 65 + b'}'):
            self.capture.write_bytes(source)
            with self.assertRaises(CONVERTER.CaptureError):
                CONVERTER.load_capture(self.capture, hashlib.sha256(source).hexdigest(), None)

    def test_source_and_sidecar_symlinks_are_rejected(self):
        args = self.arguments()
        alias = self.root / "alias.json"
        alias.symlink_to(self.capture)
        with self.assertRaises(OSError):
            CONVERTER.convert(alias, self.output, **args)
        real_atlas = self.root / "owned-atlas"
        self.atlas.rename(real_atlas)
        self.atlas.symlink_to(real_atlas)
        with self.assertRaises(OSError):
            CONVERTER.convert(self.capture, self.output, **args)
        self.assertFalse(self.output.exists())

    def test_explicit_scale_pixel_and_opaque_clear_contracts(self):
        for values in (dict(scale_factor=0), dict(pixel_width=7), dict(pixel_height=True),
                       dict(clear_color=[0, 0, 0, 0.5]), dict(clear_color=[0, 2, 0, 1]),
                       dict(workload_id="../escape")):
            self.rejects(**values)

    def test_existing_destination_is_preserved(self):
        self.output.mkdir()
        sentinel = self.output / "owner-data"
        sentinel.write_bytes(b"unchanged")
        with self.assertRaises(FileExistsError):
            self.convert()
        self.assertEqual(sentinel.read_bytes(), b"unchanged")
        self.assertEqual([path.name for path in self.output.iterdir()], ["owner-data"])

    def test_partial_failure_is_retained_without_manifest(self):
        original = CONVERTER.publish
        def fail_manifest(path, chunks, limit):
            if path.name == "candidate.json":
                raise OSError("injected manifest publication failure")
            return original(path, chunks, limit)
        with mock.patch.object(CONVERTER, "publish", side_effect=fail_manifest):
            with self.assertRaisesRegex(OSError, "injected"):
                self.convert()
        self.assertTrue((self.output / "scene.toml").is_file())
        self.assertFalse((self.output / "candidate.json").exists())
        self.assertFalse((self.output / "run.toml").exists())

    def test_stream_bound_leaves_incomplete_not_published_output(self):
        path = self.root / "bounded"
        with self.assertRaises(CONVERTER.CaptureError):
            CONVERTER.publish(path, [b"1234", b"5"], 4)
        self.assertFalse(path.exists())
        self.assertEqual(path.with_name("bounded.incomplete").read_bytes(), b"1234")

    def test_cli_rejects_missing_explicit_render_parameters(self):
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as result:
            CONVERTER.main([str(self.capture), str(self.output), "--capture-sha256", "a" * 64])
        self.assertEqual(result.exception.code, 2)

    def test_cli_success_and_error_are_terminal_and_distinct(self):
        args = self.arguments()
        argv = [str(self.capture), str(self.output), "--capture-sha256", args["capture_sha256"],
                "--atlas-sha256", args["atlas_sha256"], "--id", args["workload_id"],
                "--scale-factor", "2", "--pixel-width", "8", "--pixel-height", "4",
                "--clear-color", "0", "0", "0", "1"]
        output, errors = io.StringIO(), io.StringIO()
        with redirect_stdout(output), redirect_stderr(errors):
            self.assertEqual(CONVERTER.main(argv), 0)
        self.assertEqual(json.loads(output.getvalue())["state"], "candidate-only")
        with redirect_stdout(io.StringIO()), redirect_stderr(errors):
            self.assertEqual(CONVERTER.main(argv), 1)
        self.assertIn("conversion rejected", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
