"""Current-build shader selection with stale-cache and provenance controls."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('shader', Path(__file__).resolve().parents[1] / 'scripts/select-gpui-metallib.py')
SHADER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SHADER)


class ShaderSelectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cache = self.root / 'release/build'
        self.current = self.cache / 'gpui_macos-current/out/shaders.metallib'
        self.current.parent.mkdir(parents=True)
        self.current.write_bytes(b'MTLB-current-qualified-shader')
        stale = self.cache / 'gpui_macos-stale/out/shaders.metallib'
        stale.parent.mkdir(parents=True)
        stale.write_bytes(b'MTLB-unrelated-stale-shader')
        self.binary = self.root / 'release/alpine_trace_adapter'
        self.binary.write_bytes(b'executable-prefix' + self.current.read_bytes() + b'executable-suffix')
        self.package = 'path+file:///pinned/zed/crates/gpui_macos#0.1.0'
        self.messages = [
            {'reason': 'build-script-executed', 'package_id': self.package, 'out_dir': str(self.current.parent)},
            {'reason': 'compiler-artifact', 'target': {'name': 'alpine_trace_adapter', 'kind': ['bin']},
             'profile': {'test': False}, 'executable': str(self.binary), 'fresh': True},
            {'reason': 'build-finished', 'success': True},
        ]

    def select(self):
        return SHADER.select(map(json.dumps, self.messages), self.package, self.binary, self.cache)

    def test_fresh_or_recompiled_artifact_ignores_unrelated_cache(self):
        self.assertEqual(self.select(), self.current)
        self.messages[1]['fresh'] = False
        self.assertEqual(self.select(), self.current)

    def test_failed_missing_ambiguous_or_wrong_package_rejected(self):
        original = json.dumps(self.messages)
        for fault in ('failure', 'missing-end', 'missing-output', 'ambiguous', 'wrong-package', 'wrong-binary'):
            with self.subTest(fault=fault):
                self.messages = json.loads(original)
                if fault == 'failure': self.messages[-1]['success'] = False
                elif fault == 'missing-end': self.messages.pop()
                elif fault == 'missing-output': self.messages.pop(0)
                elif fault == 'ambiguous': self.messages.insert(0, dict(self.messages[0], out_dir=str(self.cache / 'other/out')))
                elif fault == 'wrong-package': self.messages[0]['package_id'] += '-wrong'
                else: self.messages[1]['executable'] += '-wrong'
                with self.assertRaises(ValueError): self.select()

    def test_shader_must_be_embedded_and_within_release_cache(self):
        self.binary.write_bytes(b'wrong executable')
        with self.assertRaises(ValueError): self.select()
        self.messages[0]['out_dir'] = str(self.root)
        (self.root / 'shaders.metallib').write_bytes(b'wrong')
        with self.assertRaises(ValueError): self.select()

    def test_empty_or_symlink_shader_rejected(self):
        self.current.write_bytes(b'')
        with self.assertRaises(ValueError): self.select()
        self.current.unlink()
        self.current.symlink_to(self.binary)
        with self.assertRaises(ValueError): self.select()
