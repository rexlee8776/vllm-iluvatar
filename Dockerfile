# Source-only build: ixinfer, ixformer, vLLM and vllm-iluvatar.
# Build Dockerfile.base first; see docker/README.md. No SDK/PyPI downloads here.
ARG BASE_IMAGE=10.150.9.98:80/aac-llmfp/vllm-iluvatar-base:0.31.0-corex5.0.1-ubuntu24.04-python3.12-20261023
ARG BUILD_BASE_IMAGE=10.150.9.98:80/aac-llmfp/vllm-iluvatar-base:0.31.0-corex5.0.1-ubuntu24.04-python3.12-20261023-build
ARG MAX_JOBS=64
ARG VLLM_ILUVATAR_COMMIT
ARG IXINFER_REPO=ssh://git@bitbucket.iluvatar.ai:7999/csyslib/ixinfer.git
ARG IXINFER_BRANCH=ixinfer
ARG IXINFER_COMMIT=774e4da569dcc63c5460deadefb937d9dfbae186
ARG IXINFER_CMAKE_ARGS=
ARG IXFORMER_REPO=ssh://git@bitbucket.iluvatar.ai:7999/swapp/ixformer.git
ARG IXFORMER_BRANCH=master
ARG IXFORMER_COMMIT=e6c95fe6d37116519847b6a58faaede4850f085c
ARG VLLM_REPO=ssh://git@bitbucket.iluvatar.ai:7999/swapp/vllm.git
ARG VLLM_BRANCH=feat/v0.31.0
ARG VLLM_COMMIT=341bf7d4d1244424c94296ce4fc5626ad14b827a
ARG VLLM_SCM_VERSION=0.31.0

FROM ${BUILD_BASE_IMAGE} AS ixinfer-builder
ARG MAX_JOBS
ENV PIP_NO_INDEX=1 UV_OFFLINE=1
WORKDIR /build
COPY requirements.txt /tmp/plugin-requirements.txt
RUN iluvatar-check-base --check-requirements /tmp/plugin-requirements.txt

# ---- 1) ixinfer -> libcuinfer.so -------------------------------------------
# Built from source so the kernel-library commit is under your control. With
# -DSWHOME=OFF the install target writes libcuinfer*.so* into
# /usr/local/corex/lib64 and ixinfer.h into /usr/local/corex/include — exactly
# where the FTP ixinfer SDK used to land them, so the later ixformer build picks
# it up via -lcuinfer. Only spdlog/msgpack/ixmma submodules are compile inputs
# (eigen/googletest are test-only; TESTS=OFF skips them). It links cudart/cublas/
# curand/gdrapi/ixthunk from corex-toolkit. If a toolkit lacks libgdrapi, pass
# IXINFER_CMAKE_ARGS=-DDISABLE_GDR=ON.
ARG IXINFER_REPO
ARG IXINFER_BRANCH
# Lockstep with ixformer ${IXFORMER_COMMIT}'s third_party/ixinfer submodule.
# Do NOT bump to the ixinfer branch HEAD independently.
ARG IXINFER_COMMIT
ARG IXINFER_CMAKE_ARGS
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


FROM ixinfer-builder AS ixformer-builder
ARG IXINFER_COMMIT
# ---- 2) ixformer -----------------------------------------------------------
# Only two submodules are compile inputs: third_party/pybind11 (add_subdirectory)
# and third_party/ixmma (FMHA/MMA headers). third_party/json is in-tree;
# googletest only compiles under -DBUILD_TEST. The pin also carries
# third_party/ixinfer / third_party/ixmm. Use the matching public header and
# libcuinfer installed by step 1 for compilation and linking.
ARG IXFORMER_REPO
ARG IXFORMER_BRANCH
# Merged master includes the MiniMax-M3 FP8 APIs, shared-storage producer
# and 64-bit KV-cache addressing fixes. Keep ixinfer in lockstep above.
ARG IXFORMER_COMMIT
RUN --mount=type=ssh \
    mkdir -p -m 0700 ~/.ssh \
    && ssh-keyscan -p 7999 bitbucket.iluvatar.ai >> ~/.ssh/known_hosts 2>/dev/null \
    && git clone --branch "${IXFORMER_BRANCH}" "${IXFORMER_REPO}" ixformer \
    && git -C ixformer fetch origin "${IXFORMER_COMMIT}" \
    && git -C ixformer checkout "${IXFORMER_COMMIT}" \
    && git -C ixformer submodule update --init --recursive \
         third_party/pybind11 third_party/ixmma \
    && test "$(git -C ixformer ls-tree HEAD third_party/ixinfer | awk '{print $3}')" = "${IXINFER_COMMIT}" \
    && cd ixformer \
    && COREX_ARCH=${COREX_ARCH} CUDA_ARCH=${COREX_ARCH} \
       MAX_JOBS=${MAX_JOBS:-$(nproc)} COREX_VERSION=${COREX_VERSION} \
       bash scripts/build_ixformer.sh \
    && python3 -m pip install --no-deps build_pip/ixformer-*.whl


# vLLM packaging is independent of the ixinfer/ixformer source commits.
FROM ${BUILD_BASE_IMAGE} AS vllm-builder
ARG MAX_JOBS
ENV PIP_NO_INDEX=1 UV_OFFLINE=1
WORKDIR /build
COPY requirements.txt /tmp/plugin-requirements.txt
RUN iluvatar-check-base --check-requirements /tmp/plugin-requirements.txt

# ---- 3) vLLM ---------------------------------------------------------------
# VLLM_TARGET_DEVICE=empty: GPU ops come from ixformer + the plugin, not vLLM's
# own NVIDIA build path. Rust frontend is optional in vLLM's setup.py; no Rust
# toolchain is installed, so it is skipped. Installed --no-deps.
ARG VLLM_REPO
ARG VLLM_BRANCH
ARG VLLM_COMMIT
ARG VLLM_SCM_VERSION
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


FROM ixformer-builder AS builder
ARG VLLM_COMMIT
ARG VLLM_ILUVATAR_COMMIT
COPY --from=vllm-builder /build/vllm/build_pip/vllm-*.whl /wheels/
RUN python3 -m pip install --no-deps /wheels/vllm-*.whl
# ---- 4) vllm-iluvatar plugin ----------------------------------------------
# The plugin source is THIS repository (the build context), so the image always
# reflects the checked-out code — no circular self-clone and no pin to bump for
# local changes. ixinfer/ixformer/vllm above are the only pinned external deps.
# .dockerignore keeps the context lean (build artifacts out, .git kept so the
# wheel can stamp its git id).
COPY . /build/vllm-iluvatar
RUN python3 /build/vllm-iluvatar/docker/build-info.py --write /build/iluvatar-build-info.json
LABEL org.opencontainers.image.revision="${VLLM_ILUVATAR_COMMIT}" \
      ai.iluvatar.source.ixinfer.revision="${IXINFER_COMMIT}" \
      ai.iluvatar.source.ixformer.revision="${IXFORMER_COMMIT}" \
      ai.iluvatar.source.vllm.revision="${VLLM_COMMIT}"

RUN cd /build/vllm-iluvatar \
    && COREX_ARCH=${COREX_ARCH} CUDA_ARCH=${COREX_ARCH} \
       MAX_JOBS=${MAX_JOBS:-$(nproc)} \
       bash build_vllm_iluvatar.sh

# Install the plugin wheel + sanity-import the native extension while the driver
# libs are still present (this is the only place import can run before runtime).
RUN python3 -m pip install --no-deps /build/vllm-iluvatar/build_pip/vllm_iluvatar-*.whl \
    && python3 -c "import importlib; importlib.import_module('vllm_iluvatar'); importlib.import_module('vllm_iluvatar._C'); print('builder: vllm_iluvatar._C import OK')"



RUN cp /build/ixformer/build_pip/ixformer-*.whl /wheels/ \
    && cp /build/vllm-iluvatar/build_pip/vllm_iluvatar-*.whl /wheels/

FROM ${BASE_IMAGE} AS runtime
ARG IXINFER_COMMIT
ARG IXFORMER_COMMIT
ARG VLLM_COMMIT
ARG VLLM_ILUVATAR_COMMIT
ARG VLLM_ILUVATAR_VERSION=0.31.0
ARG UBUNTU_VERSION=24.04
COPY --from=builder /build/iluvatar-build-info.json /etc/iluvatar-build-info.json
COPY docker/build-info.py /usr/local/bin/iluvatar-build-info
RUN chmod +x /usr/local/bin/iluvatar-build-info
COPY requirements.txt /tmp/plugin-requirements.txt
COPY --from=builder /opt/iluvatar-base/manifest.json /tmp/build-base-manifest.json
RUN iluvatar-check-base --check-requirements /tmp/plugin-requirements.txt \
         --match-manifest /tmp/build-base-manifest.json \
    && rm /tmp/plugin-requirements.txt /tmp/build-base-manifest.json
COPY --from=ixinfer-builder /ixinfer-dist/ /usr/local/corex/lib64/
COPY --from=ixinfer-builder /usr/local/corex/include/ixinfer.h /usr/local/corex/include/ixinfer.h
RUN test -s /usr/local/corex/include/ixinfer.h && ldconfig
COPY --from=builder /wheels/ /tmp/wheels/
# All dependencies already live in BASE_IMAGE. Never resolve/replace CoreX Torch here.
RUN PIP_NO_INDEX=1 python3 -m pip install --no-deps /tmp/wheels/*.whl \
    && rm -rf /tmp/wheels \
    && python3 -c "import importlib.metadata as m; print('vllm_iluvatar', m.version('vllm_iluvatar'))"
LABEL org.opencontainers.image.revision="${VLLM_ILUVATAR_COMMIT}" \
      ai.iluvatar.source.ixinfer.revision="${IXINFER_COMMIT}" \
      ai.iluvatar.source.ixformer.revision="${IXFORMER_COMMIT}" \
      ai.iluvatar.source.vllm.revision="${VLLM_COMMIT}" \
      org.opencontainers.image.title="vllm-iluvatar" \
      org.opencontainers.image.version="${VLLM_ILUVATAR_VERSION}-corex${COREX_VERSION}-py${COREX_PYTHON_VERSION}-ubuntu${UBUNTU_VERSION}" \
      ai.iluvatar.corex.version="${COREX_VERSION}" \
      ai.iluvatar.corex.arch="${COREX_ARCH}"
EXPOSE 8000
ENTRYPOINT ["vllm", "serve"]
