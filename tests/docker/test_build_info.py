# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright (c) 2026 Shanghai Iluvatar CoreX Semiconductor Co., Ltd.
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

script = Path(__file__).resolve().parents[2] / 'docker/build-info.py'
spec = importlib.util.spec_from_file_location('image_build_info', script)
info = importlib.util.module_from_spec(spec)
spec.loader.exec_module(info)


class BuildInfoSourceTests(unittest.TestCase):
    def write_manifest(self, root, environment):
        base = root / 'base.json'
        base.write_text(json.dumps({'corex_version': '5.0.1'}))
        output = root / 'result.json'

        def local_path(value):
            if str(value) == '/opt/iluvatar-base/manifest.json':
                return base
            return Path(value)

        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.dict(os.environ, environment, clear=True))
            stack.enter_context(patch.object(info, 'Path', local_path))
            stack.enter_context(patch.object(
                info.subprocess, 'run',
                return_value=SimpleNamespace(returncode=128)))
            stack.enter_context(patch.object(
                sys, 'argv', ['build-info.py', '--write', str(output)]))
            info.main()
        return json.loads(output.read_text())

    def environment(self):
        return {'IXFORMER_COMMIT': 'b' * 40, 'VLLM_COMMIT': 'c' * 40,
                'VLLM_ILUVATAR_COMMIT': 'd' * 40}

    def test_only_ixformer_is_required_as_native_source(self):
        for override in (None, 'not-an-independent-pin'):
            with self.subTest(override=override):
                environment = self.environment()
                if override is not None:
                    environment['IXINFER_COMMIT'] = override
                with tempfile.TemporaryDirectory() as folder:
                    result = self.write_manifest(Path(folder), environment)
                self.assertEqual(set(result['sources']),
                                 {'ixformer', 'vllm', 'vllm_iluvatar'})
                self.assertEqual(result['sources']['ixformer'], 'b' * 40)

    def test_ixformer_revision_remains_required_and_validated(self):
        for value in (None, 'not-a-commit'):
            with self.subTest(value=value):
                environment = self.environment()
                if value is None:
                    del environment['IXFORMER_COMMIT']
                else:
                    environment['IXFORMER_COMMIT'] = value
                with tempfile.TemporaryDirectory() as folder:
                    with contextlib.redirect_stderr(io.StringIO()) as errors:
                        with self.assertRaises(SystemExit) as failure:
                            self.write_manifest(Path(folder), environment)
                    self.assertEqual(failure.exception.code, 2)
                    self.assertIn('IXFORMER_COMMIT', errors.getvalue())


if __name__ == '__main__':
    unittest.main()
