# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright (c) 2026 Shanghai Iluvatar CoreX Semiconductor Co., Ltd.
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('image_build_info', Path(__file__).resolve().parents[2] / 'docker/build-info.py')
info = importlib.util.module_from_spec(spec)
spec.loader.exec_module(info)

class BuildInfoRevisionTests(unittest.TestCase):
    def write_manifest(self, root, revision, override=None):
        revision_file = root / 'ixinfer-revision.txt'
        if revision is not None:
            revision_file.write_text(revision)
        base = root / 'base.json'
        base.write_text(json.dumps({'corex_version': '5.0.1'}))
        output = root / 'result.json'
        paths = {'/ixinfer-dist/ixinfer-revision.txt': revision_file,
                 '/opt/iluvatar-base/manifest.json': base}
        def local_path(value):
            return paths.get(str(value), Path(value))
        environment = {'IXFORMER_COMMIT': 'b'*40, 'VLLM_COMMIT': 'c'*40,
                       'VLLM_ILUVATAR_COMMIT': 'd'*40}
        if override is not None:
            environment['IXINFER_COMMIT'] = override
        with patch.dict(os.environ, environment, clear=True), patch.object(info, 'Path', local_path), patch.object(info.subprocess, 'run', return_value=SimpleNamespace(returncode=128)), patch.object(info.sys if hasattr(info, 'sys') else __import__('sys'), 'argv', ['build-info.py', '--write', str(output)]):
            info.main()
        return json.loads(output.read_text())

    def test_compiled_revision_needs_no_second_pin(self):
        for override in (None, 'e'*40):
            with self.subTest(override=override), tempfile.TemporaryDirectory() as folder:
                manifest = self.write_manifest(Path(folder), 'a'*40+'\n', override)
                self.assertEqual(manifest['sources']['ixinfer'], 'a'*40)
                self.assertEqual(manifest['sources']['ixformer'], 'b'*40)

    def test_missing_revision_cannot_fall_back_to_an_external_pin(self):
        with tempfile.TemporaryDirectory() as folder, contextlib.redirect_stderr(io.StringIO()) as errors:
            with self.assertRaises(SystemExit) as failure:
                self.write_manifest(Path(folder), None, 'e'*40)
            self.assertEqual(failure.exception.code, 2)
            self.assertIn('Cannot read compiled ixinfer revision', errors.getvalue())

    def test_invalid_compiled_revision_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder, contextlib.redirect_stderr(io.StringIO()) as errors:
            with self.assertRaises(SystemExit) as failure:
                self.write_manifest(Path(folder), 'not-a-commit', 'e'*40)
            self.assertEqual(failure.exception.code, 2)
            self.assertIn('Invalid compiled ixinfer revision', errors.getvalue())

if __name__ == '__main__':
    unittest.main()
