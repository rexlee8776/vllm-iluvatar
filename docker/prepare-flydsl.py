#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright (c) 2026 Shanghai Iluvatar CoreX Semiconductor Co., Ltd.
"""Fetch the FlyDSL source pair locked by the selected ixformer checkout."""

import json
import os
import re
import subprocess
from pathlib import Path


def main():
    root = Path("/build/flydsl-sources")
    root.mkdir()
    pins = json.loads(Path("/build/ixformer-pin/version.json").read_text())["pins"]
    sources = {}
    for name, directory in [("flydsl_ixcc", "ixcc"), ("flydsl", "flydsl")]:
        pin = pins[name]
        commit = pin["commit"]
        if not re.fullmatch(r"[0-9a-f]{40}", commit):
            raise ValueError(f"{name} requires a full source commit")
        if os.environ["COREX_ARCH"] not in pin["architectures"]:
            raise ValueError(f"{name} has not been validated for this GPU architecture")
        target = root / directory
        subprocess.run(["git", "init", str(target)], check=True)
        subprocess.run(
            ["git", "-C", str(target), "remote", "add", "origin", pin["repository"]],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(target), "fetch", "--depth=1", "origin", commit],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(target), "checkout", "--detach", commit], check=True
        )
        subprocess.run(
            ["git", "-C", str(target), "submodule", "update", "--init", "--recursive"],
            check=True,
        )
        actual = subprocess.check_output(
            ["git", "-C", str(target), "rev-parse", "HEAD"], text=True
        ).strip()
        if actual != commit:
            raise ValueError(f"{name} source differs from the locked commit")
        sources[name] = {"repository": pin["repository"], "commit": actual}
    dist = Path("/flydsl-dist")
    dist.mkdir()
    (dist / "build-info.json").write_text(
        json.dumps(
            {
                "sources": sources,
                "ixformer": os.environ["IXFORMER_COMMIT"],
                "nanobind": os.environ["NANOBIND_COMMIT"],
                "architecture": os.environ["COREX_ARCH"],
                "toolchain": "/opt/flydsl/ixcc",
            },
            indent=2,
        )
        + "\n"
    )


if __name__ == "__main__":
    main()
