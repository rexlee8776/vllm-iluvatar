# vllm-iluvatar source build for CoreX 5.0.1 / Python 3.12 / Ubuntu 24.04.
# Uses Docker's built-in BuildKit frontend; no external frontend image is needed.
#
# Straight build-through (no per-component cache sub-stages). Two real stages:
#   builder : clone + compile ixinfer -> libcuinfer.so, ixformer, vLLM and the
#             vllm-iluvatar plugin.  The CoreX user-space driver libs
#             (libcuda.so.1 / libixml.so) are installed HERE because `import
#             torch` is required during compilation; they are NOT carried into
#             the final image.
#   runtime : the ONLY output image.  Gets the source-built libcuinfer + the
#             three wheels + runtime deps, but NO compiler / source / .git and
#             NO driver libraries.
#
# Why the driver is not baked into the runtime image: the CoreX kernel module +
# matching user-space driver must match the HOST kernel, so they are installed
# AFTER the container starts, from inside the (privileged) container, e.g.:
#   corex-driver-linux64-5.0.1_x86_64.run
# Until then `import torch` will fail in the runtime image by design.
#
# Both stages share a common base (corex-base) so the SDK/torch/triton layers
# are built once; corex-base itself installs no driver and runs no torch import.
#
# Build on shuguang-10.112.0.26 (Docker Hub is blocked here, use the mirror):
#   cd /home/zejun.cai
#   docker build --progress=plain -f Dockerfile.vllm-iluvatar \
#     --ssh default=/home/zejun.cai/.ssh/id_ed25519_vllm_build \
#     --build-arg MAX_JOBS=64 \
#     -t vllm-iluvatar:0.31.0-corex5.0.1-py3.12-ubuntu24.04 .
#
# SDK/torch/torchvision/triton come from the frozen 20261010 FTP directory
# (CoreX 5.0.1: torch 2.13.0 / torchvision 0.28.0 / triton 3.6.0). torchvision is
# required even for text-only models (vLLM 0.31 kernel_warmup imports qwen3_vl ->
# torchvision). All four source repos keep selectable repo/branch/commit
# build-args. No prebuilt ixinfer SDK is used — libcuinfer.so is compiled from
# the pinned ixinfer source (kept in lockstep with the ixformer pin).
# =============================================================================

# Base: Docker-Hub-blocked hosts need a reachable mirror; this default works on
# 0.26. Point BASE_IMAGE at ubuntu:24.04 (or a Harbor base) elsewhere.
ARG BASE_IMAGE=docker.m.daocloud.io/library/ubuntu:24.04

ARG PYTHON_VERSION=3.12
ARG COREX_ARCH=ivcore11
ARG COREX_VERSION=5.0.1

# CoreX FTP roots. COREX_PKG_URL feeds the SDK + driver; torch/triton default to
# the same root. Keep them on the same CoreX release (ABI risk otherwise).
ARG COREX_PKG_URL=http://sw.iluvatar.ai/download/corex/release_packages/5.0.1/x86_64/20261010
ARG TORCH_PKG_URL=${COREX_PKG_URL}
ARG TRITON_PKG_URL=${COREX_PKG_URL}

# numpy pin. CoreX torch (even the 2.13 build in 5.0.1) is compiled against the
# NumPy 1.x C ABI — the vllm-iluvatar requirements.txt still pins numpy<2 on the
# 0.31.0 branch for exactly this reason — so keep it unless a future CoreX torch
# is rebuilt against numpy 2.x.
ARG NUMPY_SPEC=numpy<2

# Faster pip inside China; applies to the build-time pip installs too.
ARG PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/

############################# COREX-BASE #####################################
# ubuntu + CoreX SDK + torch + triton. Shared by builder and runtime.
# Installs NO driver libs and runs NO torch import (torch cannot import without
# the driver, which is intentionally absent here).
FROM ${BASE_IMAGE} AS corex-base
SHELL ["/bin/bash", "-c"]

ARG PYTHON_VERSION
ARG COREX_ARCH
ARG COREX_VERSION
ARG COREX_PKG_URL
ARG TORCH_PKG_URL
ARG TRITON_PKG_URL
ARG NUMPY_SPEC

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    LANG=C.UTF-8 \
    COREX_HOME=/usr/local/corex \
    COREX_ARCH=${COREX_ARCH} \
    CUDA_ARCH=${COREX_ARCH} \
    COREX_VERSION=${COREX_VERSION}
ENV PATH=/usr/local/corex/bin:${PATH} \
    LD_LIBRARY_PATH=/usr/local/corex/lib64:/usr/local/lib

# System + Python runtime deps.
RUN apt-get update -y \
    && apt-get install -y --no-install-recommends \
        ca-certificates wget curl git jq \
        python${PYTHON_VERSION} python${PYTHON_VERSION}-dev python3-pip python-is-python3 \
        libgl1 libglib2.0-0 libgomp1 libnuma1 numactl \
        libopenmpi3t64 \
    && rm -f /usr/lib/python*/EXTERNALLY-MANAGED \
    && ln -sf /usr/bin/python${PYTHON_VERSION} /usr/local/bin/python3 \
    && ln -sf /usr/bin/python${PYTHON_VERSION} /usr/local/bin/python \
    && rm -rf /var/lib/apt/lists/*

# numpy pin (CoreX torch is NumPy-1.x ABI) + setuptools<82 (pkg_resources).
# Applies to every pip resolve below via PIP_CONSTRAINT.
RUN printf '%s\nsetuptools<82\n' "${NUMPY_SPEC}" > /etc/pip-constraint.txt
ENV PIP_CONSTRAINT=/etc/pip-constraint.txt
RUN python3 -m pip install --no-cache-dir --ignore-installed -U pip 'setuptools<82' wheel

# Generic CoreX FTP installer: finds the single matching artifact in a dir and
# installs it (.run via bash, .whl via pip).
COPY <<'SH' /usr/local/bin/ftp_install
#!/usr/bin/env bash
set -euo pipefail
# ftp_install <base_url> <subdir> <name> <run|whl> [extra pip/run args...]
base="${1%/}"; sub="$2"; name="$3"; kind="$4"; shift 4
norm="$(echo "$name" | sed 's/[-.]/_/g')"
if [ "$kind" = "whl" ]; then pat="(^|/)${norm}-.*\.whl$"; else pat="${name}.*\.(run|sh)$"; fi
page="$(wget -qO- "${base}/${sub}/")"
file="$(printf '%s' "$page" | grep -oE 'href="[^"]+"' | sed 's/^href="//;s/"$//' | grep -E "$pat" | grep -v md5 | head -1)"
[ -n "$file" ] || { echo "ftp_install: no match for '$name' ($kind) in ${base}/${sub}" >&2; exit 1; }
bn="$(basename "$file")"
echo "ftp_install: fetching ${base}/${sub}/${bn}"
wget -nv "${base}/${sub}/${file}" -O "/tmp/${bn}"
case "$kind" in
  run) bash "/tmp/${bn}" "$@" ;;
  whl) pip3 install --no-cache-dir --prefer-binary "$@" "/tmp/${bn}" ;;
esac
rm -f "/tmp/${bn}"
SH
RUN chmod +x /usr/local/bin/ftp_install

# CoreX cmake (newer than apt's; the native builds need a recent cmake).
RUN set -euo pipefail; U="${COREX_PKG_URL%/}"; \
    f="$(wget -qO- "$U/tools/" | grep -oE 'href="cmake[^"]+\.sh"' | sed 's/^href="//;s/"$//' | grep -v md5 | head -1)"; \
    wget -nv "$U/tools/$f" -O /tmp/cmake.sh; \
    bash /tmp/cmake.sh --skip-license --prefix=/usr/local; \
    rm -f /tmp/cmake.sh

# CoreX SDK (.run). Only what this source-build chain links/loads:
#   * corex-toolkit : clang/ixcc + CUDA-compat runtime (cudart/cublas/curand/
#                     gdrapi/ixthunk) used by ixinfer/ixformer/vllm.
#   * ixdnn / ixccl : cudnn / nccl equivalents linked by ixformer.
#   * ixshmem / ucx : ixformer comm layer / NIXL transport.
#   * ixattention-backend : CoreX Torch loads libixattnbkd.so.1 at import time.
# The ixinfer SDK is deliberately NOT installed; libcuinfer.so is compiled from
# the pinned source in the builder stage and copied into the runtime image.
RUN set -euo pipefail; U="${COREX_PKG_URL}"; \
    ftp_install "$U" sdk corex-toolkit       run --silent --toolkit --toolbox; \
    ftp_install "$U" sdk ixdnn               run; \
    ftp_install "$U" sdk ixccl               run; \
    ftp_install "$U" sdk ixshmem             run; \
    ftp_install "$U" sdk ucx                 run; \
    ftp_install "$U" sdk ixattention-backend run; \
    ldconfig

# torch + torchvision + triton (.whl). Versions follow *_PKG_URL (CoreX 5.0.1:
# torch 2.13.0 / torchvision 0.28.0 / triton 3.6.0). No import check here — torch
# cannot import without the driver. torchvision is REQUIRED: vLLM 0.31's
# kernel_warmup unconditionally imports qwen3_vl -> transformers qwen2_vl image
# processor -> torchvision, even for text-only models, so a missing torchvision
# aborts engine startup. The ftp_install "torch" pattern anchors a literal
# trailing dash (torch-), so it never matches the torchvision wheel.
RUN set -euo pipefail; PYV="py${PYTHON_VERSION}"; \
    ftp_install "${TORCH_PKG_URL}"  "apps/${PYV}" torch       whl; \
    ftp_install "${TORCH_PKG_URL}"  "apps/${PYV}" torchvision whl --no-deps; \
    ftp_install "${TRITON_PKG_URL}" "apps/${PYV}" triton      whl

############################# BUILDER ########################################
# Clone + compile everything. Driver user-space libs live here (needed so that
# `import torch` works during the ixformer/vllm/plugin builds) and never leave.
FROM corex-base AS builder

ARG COREX_ARCH
ARG COREX_VERSION
ARG COREX_PKG_URL
ARG NUMPY_SPEC
ARG MAX_JOBS
ARG PIP_INDEX_URL
ENV PIP_INDEX_URL=${PIP_INDEX_URL}

# Build toolchain + openssh-client (for the SSH-only Bitbucket clones).
RUN apt-get update -y \
    && apt-get install -y --no-install-recommends \
        build-essential ninja-build openssh-client \
    && rm -rf /var/lib/apt/lists/*

# CoreX user-space driver libs (libcuda.so.1 / libixml.so) — BUILD-TIME ONLY.
# Extract the vendor package without running its kernel-module installer. These
# are what make `import torch` succeed during compilation; the runtime image
# does NOT copy them (the user installs the matching driver inside the container).
RUN set -euo pipefail; \
    ftp_install "${COREX_PKG_URL}" sdk corex-driver run --noexec --target /tmp/corex-driver \
    && install -m 0755 /tmp/corex-driver/corex/lib64/libcuda.so.1 /usr/local/corex/lib64/libcuda.so.1 \
    && ln -sf libcuda.so.1 /usr/local/corex/lib64/libcuda.so \
    && install -m 0755 /tmp/corex-driver/corex/lib64/libixml.so /usr/local/corex/lib64/libixml.so \
    && rm -rf /tmp/corex-driver \
    && ldconfig \
    && python3 -c "import torch, triton; print('torch', torch.__version__, '| triton', triton.__version__)"

WORKDIR /build

# ---- 1) ixinfer -> libcuinfer.so -------------------------------------------
# Built from source so the kernel-library commit is under your control. With
# -DSWHOME=OFF the install target writes libcuinfer*.so* into
# /usr/local/corex/lib64 and ixinfer.h into /usr/local/corex/include — exactly
# where the FTP ixinfer SDK used to land them, so the later ixformer build picks
# it up via -lcuinfer. Only spdlog/msgpack/ixmma submodules are compile inputs
# (eigen/googletest are test-only; TESTS=OFF skips them). It links cudart/cublas/
# curand/gdrapi/ixthunk from corex-toolkit. If a toolkit lacks libgdrapi, pass
# IXINFER_CMAKE_ARGS=-DDISABLE_GDR=ON.
ARG IXINFER_REPO=ssh://git@bitbucket.iluvatar.ai:7999/csyslib/ixinfer.git
ARG IXINFER_BRANCH=ixinfer
# Lockstep with ixformer ${IXFORMER_COMMIT}'s third_party/ixinfer submodule.
# Do NOT bump to the ixinfer branch HEAD independently.
ARG IXINFER_COMMIT=b9666bf28a82c9cec1101532365a391939a7f99f
ARG IXINFER_CMAKE_ARGS=
RUN --mount=type=ssh \
    mkdir -p -m 0700 ~/.ssh \
    && ssh-keyscan -p 7999 bitbucket.iluvatar.ai >> ~/.ssh/known_hosts 2>/dev/null \
    && git clone --branch "${IXINFER_BRANCH}" "${IXINFER_REPO}" ixinfer \
    && git -C ixinfer fetch origin "${IXINFER_COMMIT}" \
    && git -C ixinfer checkout "${IXINFER_COMMIT}" \
    && git -C ixinfer submodule update --init \
         3rdparty/spdlog 3rdparty/msgpack 3rdparty/ixmma \
    && cmake -S ixinfer -B ixinfer/build -G Ninja \
         -DSWHOME=OFF \
         -DCUDA_ARCH=${COREX_ARCH} \
         -DCMAKE_BUILD_TYPE=Release \
         -DTESTS=OFF \
         ${IXINFER_CMAKE_ARGS} \
    && cmake --build ixinfer/build -j "${MAX_JOBS:-$(nproc)}" \
    && cmake --install ixinfer/build \
    && ldconfig \
    && mkdir -p /ixinfer-dist \
    && cp -a /usr/local/corex/lib64/libcuinfer*.so* /ixinfer-dist/ \
    && ls -l /ixinfer-dist

# ---- 2) ixformer -----------------------------------------------------------
# Only two submodules are compile inputs: third_party/pybind11 (add_subdirectory)
# and third_party/ixmma (FMHA/MMA headers). third_party/json is in-tree;
# googletest only compiles under -DBUILD_TEST. The pin also carries
# third_party/ixinfer / third_party/ixmm, but CMakeLists references neither —
# ixinfer is the source-built libcuinfer from step 1 (ixformer links -lcuinfer
# and uses its own vendored headers under src/kernels/infer/ixinfer).
ARG IXFORMER_REPO=ssh://git@bitbucket.iluvatar.ai:7999/swapp/ixformer.git
ARG IXFORMER_BRANCH=master
# ixformer master already contains the V4.1 kernels previously pinned at
# 739abab2 (deepseekv41 files are identical on 573eda3f). Keep ixinfer in
# lockstep above.
ARG IXFORMER_COMMIT=573eda3fbdb44756c21124ba61f3fabfac0f0ef9
RUN --mount=type=ssh \
    mkdir -p -m 0700 ~/.ssh \
    && ssh-keyscan -p 7999 bitbucket.iluvatar.ai >> ~/.ssh/known_hosts 2>/dev/null \
    && git clone --branch "${IXFORMER_BRANCH}" "${IXFORMER_REPO}" ixformer \
    && git -C ixformer fetch origin "${IXFORMER_COMMIT}" \
    && git -C ixformer checkout "${IXFORMER_COMMIT}" \
    && git -C ixformer submodule update --init --recursive \
         third_party/pybind11 third_party/ixmma \
    && cd ixformer \
    && COREX_ARCH=${COREX_ARCH} CUDA_ARCH=${COREX_ARCH} \
       MAX_JOBS=${MAX_JOBS:-$(nproc)} COREX_VERSION=${COREX_VERSION} \
       bash scripts/build_ixformer.sh \
    && python3 -m pip install --no-deps build_pip/ixformer-*.whl

# The plugin's CMake imports ixformer to locate its native libs; ixformer's
# import chain pulls in numpy / tabulate / tqdm.
RUN python3 -m pip install --no-cache-dir "${NUMPY_SPEC}" tabulate tqdm

# ---- 3) vLLM ---------------------------------------------------------------
# VLLM_TARGET_DEVICE=empty: GPU ops come from ixformer + the plugin, not vLLM's
# own NVIDIA build path. Rust frontend is optional in vLLM's setup.py; no Rust
# toolchain is installed, so it is skipped. Installed --no-deps.
ARG VLLM_REPO=ssh://git@bitbucket.iluvatar.ai:7999/swapp/vllm.git
ARG VLLM_BRANCH=feat/v0.31.0
ARG VLLM_COMMIT=341bf7d4d1244424c94296ce4fc5626ad14b827a
ARG VLLM_SCM_VERSION=0.31.0
RUN --mount=type=ssh \
    mkdir -p -m 0700 ~/.ssh \
    && ssh-keyscan -p 7999 bitbucket.iluvatar.ai >> ~/.ssh/known_hosts 2>/dev/null \
    && git clone --branch "${VLLM_BRANCH}" "${VLLM_REPO}" vllm \
    && git -C vllm fetch origin "${VLLM_COMMIT}" \
    && git -C vllm checkout "${VLLM_COMMIT}" \
    && (git -C vllm submodule update --init --recursive 2>/dev/null || true) \
    && cd vllm \
    && VLLM_TARGET_DEVICE=empty SETUPTOOLS_SCM_PRETEND_VERSION=${VLLM_SCM_VERSION} \
       MAX_JOBS=${MAX_JOBS:-$(nproc)} COREX_VERSION=${COREX_VERSION} \
       bash build_vllm.sh \
    && python3 -m pip install --no-deps build_pip/vllm-*.whl

# ---- 4) vllm-iluvatar plugin ----------------------------------------------
# The plugin source is THIS repository (the build context), so the image always
# reflects the checked-out code — no circular self-clone and no pin to bump for
# local changes. ixinfer/ixformer/vllm above are the only pinned external deps.
# .dockerignore keeps the context lean (build artifacts out, .git kept so the
# wheel can stamp its git id).
COPY . /build/vllm-iluvatar
RUN cd vllm-iluvatar \
    && COREX_ARCH=${COREX_ARCH} CUDA_ARCH=${COREX_ARCH} \
       MAX_JOBS=${MAX_JOBS:-$(nproc)} \
       bash build_vllm_iluvatar.sh

# Install the plugin wheel + sanity-import the native extension while the driver
# libs are still present (this is the only place import can run before runtime).
RUN python3 -m pip install --no-deps vllm-iluvatar/build_pip/vllm_iluvatar-*.whl \
    && python3 -c "import importlib; importlib.import_module('vllm_iluvatar'); importlib.import_module('vllm_iluvatar._C'); print('builder: vllm_iluvatar._C import OK')"

# ---- collect wheels --------------------------------------------------------
RUN mkdir -p /wheels \
    && cp ixformer/build_pip/ixformer-*.whl           /wheels/ \
    && cp vllm/build_pip/vllm-*.whl                   /wheels/ \
    && cp vllm-iluvatar/build_pip/vllm_iluvatar-*.whl /wheels/ \
    && ls -l /wheels

############################# RUNTIME ########################################
# The ONLY output image: corex-base (SDK/torch/triton) + source-built libcuinfer
# + three wheels + runtime deps. No source, no .git, NO driver libs — the user
# installs the CoreX driver *inside* the started container (see header). That
# in-container driver install compiles+loads a kernel module, so the image must
# carry a minimal build toolchain: gcc/g++/make/binutils + kmod + libc headers.
# g++ also provides libstdc++-dev (the -lstdc++ link symlink) so compiling any
# CoreX C++ extension (e.g. ixformer) in the container does not fail with
# "cannot find -lstdc++".
FROM corex-base AS runtime

ARG COREX_ARCH
ARG COREX_VERSION
ARG PYTHON_VERSION
ARG VLLM_ILUVATAR_VERSION=0.31.0
ARG UBUNTU_VERSION=24.04
ARG PIP_INDEX_URL
ENV PIP_INDEX_URL=${PIP_INDEX_URL}

# Minimal toolchain for the in-container CoreX driver install (builds+loads a
# kernel module against the host-mounted /usr/src + /lib/modules) and for
# compiling CoreX C++ extensions in the container. g++ pulls libstdc++-*-dev,
# which supplies the libstdc++.so link symlink (fixes "cannot find -lstdc++").
RUN apt-get update -y \
    && apt-get install -y --no-install-recommends \
        gcc g++ make binutils kmod libc6-dev \
    && rm -rf /var/lib/apt/lists/*

# Source-built libcuinfer.so (+ module libs). corex-base ships no ixinfer SDK, so
# this is how libcuinfer.so enters the runtime image.
COPY --from=builder /ixinfer-dist/ /usr/local/corex/lib64/
RUN ldconfig

COPY --from=builder /wheels /tmp/wheels
COPY --from=builder /build/vllm-iluvatar/requirements.txt /tmp/requirements.txt


# uv parallelises the (slow, single-connection) mirror downloads.
RUN python3 -m pip install --only-binary=:all: --no-cache-dir uv && uv --version

RUN python3 -m pip install --index-url "${PIP_INDEX_URL}" --only-binary :all: \
         --constraint /etc/pip-constraint.txt /tmp/wheels/ixformer-*.whl \
    && python3 -m pip install --no-deps /tmp/wheels/vllm-*.whl \
    && python3 -m pip install --no-deps /tmp/wheels/vllm_iluvatar-*.whl \
    && uv pip install --system --index-url "${PIP_INDEX_URL}" --only-binary :all: \
         --constraint /etc/pip-constraint.txt -r /tmp/requirements.txt \
    && uv cache clean || true \
    && rm -rf /root/.cache/uv /tmp/wheels /tmp/requirements.txt

# Metadata-only check: confirms the wheel installed without importing torch
# (which cannot load until the driver is installed inside the container).
RUN python3 -c "import importlib.metadata as m; print('vllm_iluvatar wheel version', m.version('vllm_iluvatar'))"

LABEL org.opencontainers.image.title="vllm-iluvatar" \
      org.opencontainers.image.version="${VLLM_ILUVATAR_VERSION}-corex${COREX_VERSION}-py${PYTHON_VERSION}-ubuntu${UBUNTU_VERSION}" \
      ai.iluvatar.corex.version="${COREX_VERSION}" \
      ai.iluvatar.corex.arch="${COREX_ARCH}"

# vLLM auto-discovers the plugin through its entry points at startup.
# NOTE: install the CoreX driver inside the (privileged) container before
# starting the server, otherwise torch cannot initialise the device.
EXPOSE 8000
ENTRYPOINT ["vllm", "serve"]
