#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright (c) 2026 Shanghai Iluvatar CoreX Semiconductor Co., Ltd.
"""Check base compatibility using metadata only; do not import driver-dependent Torch."""
import argparse
import hashlib
import importlib.metadata as metadata
import json
import os
from pathlib import Path
import sys

ROOT = Path('/opt/iluvatar-base')
MANIFEST = ROOT / 'manifest.json'


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write-manifest', action='store_true')
    parser.add_argument('--sdk-url')
    parser.add_argument('--check-requirements', type=Path)
    parser.add_argument('--match-manifest', type=Path)
    args = parser.parse_args()
    if args.write_manifest:
        if not args.sdk_url:
            parser.error('--write-manifest requires --sdk-url')
        packages = {name: metadata.version(name) for name in
                    ('torch', 'torchvision', 'triton', 'numpy', 'setuptools')}
        manifest = {
            'schema': 1,
            'python': list(sys.version_info[:2]),
            'corex_version': os.environ['COREX_VERSION'],
            'corex_arch': os.environ['COREX_ARCH'],
            'sdk_url': args.sdk_url.rstrip('/'),
            'requirements_sha256': sha256(ROOT / 'requirements.txt'),
            'build_requirements_sha256': sha256(ROOT / 'requirements-build.txt'),
            'packages': packages,
        }
        MANIFEST.write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    manifest = json.loads(MANIFEST.read_text())
    if args.check_requirements and sha256(args.check_requirements) != manifest['requirements_sha256']:
        raise SystemExit('Base requirements differ from this checkout; rebuild Dockerfile.base and use the matching base pair.')
    if args.match_manifest and json.loads(args.match_manifest.read_text()) != manifest:
        raise SystemExit('BASE_IMAGE and BUILD_BASE_IMAGE do not match; build both from the same Dockerfile.base inputs.')
    print('CoreX base compatibility check passed')


if __name__ == '__main__':
    main()
