#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright (c) 2026 Shanghai Iluvatar CoreX Semiconductor Co., Ltd.
"""Print the image source versions, or write them during the source build."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write', type=Path)
    args = parser.parse_args()
    if not args.write:
        print(Path('/etc/iluvatar-build-info.json').read_text(), end='')
        return
    sources = {}
    for name in ('ixformer', 'vllm', 'vllm_iluvatar'):
        commit = os.environ.get(name.upper() + '_COMMIT', '')
        if not re.fullmatch(r'[0-9a-f]{40}', commit):
            parser.error('Pass --build-arg ' + name.upper() + '_COMMIT=<full 40-character commit>')
        sources[name] = commit
    # Ordinary clones can also check HEAD and tracked modifications. Worktree
    # .git pointers may be unavailable in Docker's context; the explicit build
    # argument remains required and is recorded in either case.
    cwd = '/build/vllm-iluvatar'
    head = subprocess.run(['git', '-C', cwd, 'rev-parse', 'HEAD'],
                          capture_output=True, text=True)
    dirty = None
    if head.returncode == 0:
        if head.stdout.strip() != sources['vllm_iluvatar']:
            parser.error('VLLM_ILUVATAR_COMMIT differs from the build context HEAD')
        dirty = subprocess.run(['git', '-C', cwd, 'diff', '--quiet', 'HEAD']).returncode != 0
    result = {
        'schema': 1,
        'sources': sources,
        'plugin_tracked_changes': dirty,
        'base': json.loads(Path('/opt/iluvatar-base/manifest.json').read_text()),
    }
    args.write.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')


if __name__ == '__main__':
    main()
