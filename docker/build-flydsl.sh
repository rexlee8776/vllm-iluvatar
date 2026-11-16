#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright (c) 2026 Shanghai Iluvatar CoreX Semiconductor Co., Ltd.
set -euo pipefail
[[ ${COREX_ARCH} == ivcore11 ]] || { echo "FlyDSL is validated for ivcore11 only" >&2; exit 1; }
export COREX_ROOT=/usr/local/corex IXA_ROOT=/usr/local/corex ARCH=ivcore11
export FLYDSL_COMPILE_BACKEND=iluvatar FLYDSL_RUNTIME_KIND=iluvatar
export MLIR_PATH=/opt/flydsl/ixcc
export FLYDSL_COMPILE_IXCC_DIR="$MLIR_PATH"
export MAX_JOBS=${MAX_JOBS:-32}
NANOBIND_DIR=/build/nanobind-install/nanobind/cmake
cmake -G Ninja -S /build/flydsl-sources/flydsl -B /build/flydsl-sources/flydsl/build-fly \
 -DCMAKE_BUILD_TYPE=Release -DFLYDSL_BACKENDS=iluvatar \
 -DMLIR_DIR="$MLIR_PATH/lib/cmake/mlir" -DLLVM_DIR="$MLIR_PATH/lib/cmake/llvm" \
 -DCUDAToolkit_ROOT="$COREX_ROOT" -DPython3_EXECUTABLE=/usr/bin/python3 \
 -Dnanobind_DIR="$NANOBIND_DIR" \
 -DCMAKE_SHARED_LINKER_FLAGS='-static-libstdc++ -static-libgcc' \
 -DCMAKE_MODULE_LINKER_FLAGS='-static-libstdc++ -static-libgcc'
cmake --build /build/flydsl-sources/flydsl/build-fly -j "$MAX_JOBS"
mkdir -p /flydsl-dist/wheels
FLY_REBUILD=0 python -m pip wheel --no-deps --no-build-isolation /build/flydsl-sources/flydsl -w /flydsl-dist/wheels

mkdir -p /flydsl-dist/licenses
cp /build/flydsl-sources/ixcc/llvm/LICENSE.TXT /flydsl-dist/licenses/ixcc-LICENSE
cp /build/flydsl-sources/flydsl/LICENSE /flydsl-dist/licenses/flydsl-LICENSE
cp /build/nanobind/LICENSE /flydsl-dist/licenses/nanobind-LICENSE
