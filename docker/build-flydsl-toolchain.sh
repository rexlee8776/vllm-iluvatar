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
# Use nanobind's CMake install rules to generate its versioned package config.
cmake -S /build/nanobind -B /build/nanobind-build \
 -DNB_TEST=OFF -DCMAKE_INSTALL_PREFIX=/build/nanobind-install
cmake --install /build/nanobind-build
NANOBIND_DIR=/build/nanobind-install/nanobind/cmake
cmake -G Ninja -S /build/flydsl-sources/ixcc/llvm -B /build/ixcc-build \
 -DCMAKE_C_COMPILER=/usr/bin/gcc -DCMAKE_CXX_COMPILER=/usr/bin/g++ \
 -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$MLIR_PATH" \
 -DLLVM_ENABLE_PROJECTS='mlir;clang;lld' -DLLVM_TARGETS_TO_BUILD='X86;NVPTX;Iluvatar' \
 -DLLVM_ENABLE_RUNTIMES=compiler-rt -DLLVM_ENABLE_ASSERTIONS=ON -DLLVM_INSTALL_UTILS=ON \
 -DMLIR_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_TESTS=OFF -DCLANG_INCLUDE_TESTS=OFF \
 -DMLIR_ENABLE_BINDINGS_PYTHON=ON -DMLIR_BINDINGS_PYTHON_NB_DOMAIN=mlir \
 -DMLIR_INSTALL_AGGREGATE_OBJECTS=ON -DPython3_EXECUTABLE=/usr/bin/python3 \
 -Dnanobind_DIR="$NANOBIND_DIR" -DBUILD_SHARED_LIBS=OFF \
 -DLLVM_BUILD_LLVM_DYLIB=OFF -DLLVM_LINK_LLVM_DYLIB=OFF \
 -DLLVM_PARALLEL_LINK_JOBS=2 -DCMAKE_INSTALL_RPATH='$ORIGIN'
cmake --build /build/ixcc-build -j "$MAX_JOBS"
cmake --install /build/ixcc-build
mkdir -p /flydsl-dist/licenses
cp /build/flydsl-sources/ixcc/llvm/LICENSE.TXT /flydsl-dist/licenses/ixcc-LICENSE
cp /build/nanobind/LICENSE /flydsl-dist/licenses/nanobind-LICENSE
