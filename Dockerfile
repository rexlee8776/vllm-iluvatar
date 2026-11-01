# Source-only build: ixinfer, ixformer, deep_ep, vLLM, vllm-iluvatar, nixl, dynamo, vllm-router.
# Build Dockerfile.base first; see docker/README.md. No SDK/PyPI downloads here.
ARG BASE_IMAGE=10.150.9.98:80/aac-llmfp/vllm-iluvatar-base-0.31.0:corex5.0.1-ubuntu24.04-python3.12-x86_64-ivcore11-20261023
ARG BUILD_BASE_IMAGE=10.150.9.98:80/aac-llmfp/vllm-iluvatar-base-0.31.0:corex5.0.1-ubuntu24.04-python3.12-x86_64-ivcore11-20261023-build
# Optional expectations: actual GPU compilation target is inherited from base.
# Keep separate names so an ARG cannot disguise an incompatible base ENV.
ARG CPU_ARCH
ARG TARGET_COREX_ARCH
ARG MAX_JOBS=64
ARG VLLM_ILUVATAR_COMMIT
ARG IXINFER_REPO=ssh://git@bitbucket.iluvatar.ai:7999/csyslib/ixinfer.git
ARG IXINFER_BRANCH=ixinfer
# No IXINFER_COMMIT: the ixformer gitlink below is the only pin that can stay in
# lockstep, so the ixinfer stage reads it from there.
ARG IXINFER_CMAKE_ARGS=
ARG IXFORMER_REPO=ssh://git@bitbucket.iluvatar.ai:7999/swapp/ixformer.git
ARG IXFORMER_BRANCH=master
ARG IXFORMER_COMMIT=dc70ca88ea9b2c9d1041e31530b8818d972fde93
ARG VLLM_REPO=ssh://git@bitbucket.iluvatar.ai:7999/swapp/vllm.git
ARG VLLM_BRANCH=feat/v0.31.0
ARG VLLM_COMMIT=341bf7d4d1244424c94296ce4fc5626ad14b827a
ARG VLLM_SCM_VERSION=0.31.0
ARG DEEPEP_REPO=ssh://git@bitbucket.iluvatar.ai:7999/swfw/deepep.git
ARG DEEPEP_BRANCH=release/5.0
ARG DEEPEP_COMMIT=73513f015f7cd5c8fbe181a8840c092ec1522766
ARG NIXL_REPO=ssh://git@bitbucket.iluvatar.ai:7999/swapp/nixl.git
ARG NIXL_BRANCH=release/5.0
ARG NIXL_COMMIT=c84f3bb56f8f58e97a6579b17437d6fb251c3f15
ARG DYNAMO_REPO=ssh://git@bitbucket.iluvatar.ai:7999/swapp/dynamo.git
ARG DYNAMO_BRANCH=feat/v1.5.1
ARG DYNAMO_COMMIT=5b468ab71c8bd9f4490f0eb2aadd1913fbb0d2df
ARG VLLM_ROUTER_REPO=ssh://git@bitbucket.iluvatar.ai:7999/swapp/vllm-router.git
ARG VLLM_ROUTER_BRANCH=main
ARG VLLM_ROUTER_COMMIT=088ddfe4d8c4a4b3568bdbc37b500601cd6fa89f

FROM ${BUILD_BASE_IMAGE} AS ixinfer-builder
ARG CPU_ARCH
ARG TARGET_COREX_ARCH
ARG MAX_JOBS
ENV PIP_NO_INDEX=1 UV_OFFLINE=1
WORKDIR /build
COPY requirements.txt /tmp/plugin-requirements.txt
RUN iluvatar-check-base --check-requirements /tmp/plugin-requirements.txt

# ---- 1) ixinfer -> libcuinfer.so -------------------------------------------
# -DSWHOME=OFF installs libcuinfer*.so* into /usr/local/corex/lib64 and ixinfer.h
# into /usr/local/corex/include, so ixformer links it via -lcuinfer. Only
# spdlog/msgpack/ixmma are compile inputs. If a toolkit lacks libgdrapi, pass
# IXINFER_CMAKE_ARGS=-DDISABLE_GDR=ON.
ARG IXINFER_REPO
ARG IXINFER_BRANCH
ARG IXINFER_CMAKE_ARGS
# The commit is read from ixformer's third_party/ixinfer gitlink below.
ARG IXFORMER_REPO
ARG IXFORMER_BRANCH
ARG IXFORMER_COMMIT
RUN --mount=type=ssh \
    mkdir -p -m 0700 ~/.ssh \
    && ssh-keyscan -p 7999 bitbucket.iluvatar.ai >> ~/.ssh/known_hosts 2>/dev/null \
    && git clone --filter=blob:none --no-checkout \
         --branch "${IXFORMER_BRANCH}" "${IXFORMER_REPO}" ixformer-pin \
    && git -C ixformer-pin fetch origin "${IXFORMER_COMMIT}" \
    && IXINFER_COMMIT="$(git -C ixformer-pin ls-tree "${IXFORMER_COMMIT}" \
         third_party/ixinfer | awk '{print $3}')" \
    && if [ -z "${IXINFER_COMMIT}" ]; then \
         echo "third_party/ixinfer is not a submodule at ${IXFORMER_COMMIT}" >&2; \
         exit 1; \
       fi \
    && echo "ixinfer pinned by ixformer: ${IXINFER_COMMIT}" \
    && rm -rf ixformer-pin \
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
    && printf '%s\n' "${IXINFER_COMMIT}" > /ixinfer-dist/ixinfer-revision.txt \
    && ls -l /ixinfer-dist


FROM ixinfer-builder AS ixformer-builder
# ---- 2) ixformer -----------------------------------------------------------
# Only pybind11 and ixmma are compile inputs. The pin also carries
# third_party/ixinfer, which is what step 1 derives its commit from.
ARG IXFORMER_REPO
ARG IXFORMER_BRANCH
ARG IXFORMER_COMMIT
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


# ---- 3) DeepEP --------------------------------------------------------------
# Source position only; starts from BUILD_BASE_IMAGE, so it is off the ixformer
# and vLLM cache chains. BNXT needs bnxt_re_hsi.h, so MLX is forced.
FROM ${BUILD_BASE_IMAGE} AS deepep-builder
ARG DEEPEP_REPO
ARG DEEPEP_BRANCH
ARG DEEPEP_COMMIT
RUN --mount=type=ssh \
    mkdir -p -m 0700 ~/.ssh \
    && ssh-keyscan -p 7999 bitbucket.iluvatar.ai >> ~/.ssh/known_hosts 2>/dev/null \
    && git clone --branch "${DEEPEP_BRANCH}" "${DEEPEP_REPO}" deepep \
    && git -C deepep fetch origin "${DEEPEP_COMMIT}" \
    && git -C deepep checkout "${DEEPEP_COMMIT}" \
    && cd deepep \
    && NVSHMEM_MLX_SUPPORT=1 NVSHMEM_BNXT_SUPPORT=0 bash build.sh \
    && mkdir -p /deepep-dist \
    && cp build_pip/*.whl /deepep-dist/
# Import here: this stage has the driver libs, so it is the only place deep_ep
# (which imports torch) can be loaded before runtime.
RUN PIP_NO_INDEX=1 python3 -m pip install --no-deps /deepep-dist/*.whl \
    && python3 -c "import deep_ep; print('deepep-builder: deep_ep import OK', deep_ep.Buffer.num_sms)"


# vLLM packaging is independent of the ixinfer/ixformer source commits.
FROM ${BUILD_BASE_IMAGE} AS vllm-builder
ARG CPU_ARCH
ARG TARGET_COREX_ARCH
ARG MAX_JOBS
ENV PIP_NO_INDEX=1 UV_OFFLINE=1
WORKDIR /build
COPY requirements.txt /tmp/plugin-requirements.txt
RUN iluvatar-check-base --check-requirements /tmp/plugin-requirements.txt

# ---- 4) vLLM ---------------------------------------------------------------
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


FROM ixformer-builder AS plugin-builder
ARG VLLM_COMMIT
ARG VLLM_ILUVATAR_COMMIT
COPY --from=vllm-builder /build/vllm/build_pip/vllm-*.whl /wheels/
RUN python3 -m pip install --no-deps /wheels/vllm-*.whl
# ---- 5) vllm-iluvatar plugin ----------------------------------------------
# The build context IS this repository, so the image always reflects the
# checked-out code. .dockerignore keeps the context lean but keeps .git for the
# wheel's git id.
COPY . /build/vllm-iluvatar
RUN python3 /build/vllm-iluvatar/docker/build-info.py --write /build/iluvatar-build-info.json
# The ixinfer revision is not a label: it is resolved inside the ixinfer stage
# rather than passed in, and LABEL cannot read it back. It travels as
# /etc/iluvatar-ixinfer-revision in the runtime image instead.
LABEL org.opencontainers.image.revision="${VLLM_ILUVATAR_COMMIT}" \
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


# ---- 6) NIXL ---------------------------------------------------------------
# Independent of the C++ chain; Dynamo chains off it because kvbm loads nixl._api.
#
# No Rust toolchain is installed anywhere: build_dynamo.sh bootstraps rustup and
# installs the channel from rust-toolchain.toml, and vllm-router reuses it.
FROM ${BUILD_BASE_IMAGE} AS nixl-builder
ARG CPU_ARCH
ARG TARGET_COREX_ARCH
WORKDIR /build

# NIXL pulls liburing/abseil through meson subprojects; curl/unzip/xz fetch them.
RUN apt-get update -y \
    && apt-get install -y --no-install-recommends \
        curl unzip xz-utils pkg-config \
    && rm -rf /var/lib/apt/lists/*

# build_nixl.sh switches to -Dbuild_iluvatar=1 when /usr/local/corex exists.
ARG NIXL_REPO
ARG NIXL_BRANCH
ARG NIXL_COMMIT
RUN --mount=type=ssh \
    mkdir -p -m 0700 ~/.ssh \
    && ssh-keyscan -p 7999 bitbucket.iluvatar.ai >> ~/.ssh/known_hosts 2>/dev/null \
    && git clone --branch "${NIXL_BRANCH}" "${NIXL_REPO}" nixl \
    && git -C nixl fetch origin "${NIXL_COMMIT}" \
    && git -C nixl checkout "${NIXL_COMMIT}" \
    && cd nixl \
    && TARGET_CUDA_DIR=/usr/local/corex bash build_nixl.sh \
    && bash install_nixl.sh \
    && mkdir -p /nixl-dist \
    && cp build_pip/*.whl /nixl-dist/ \
    && python3 -c "import nixl._api; print('nixl-builder: nixl import OK')"


# ---- 7) Dynamo --------------------------------------------------------------
FROM nixl-builder AS dynamo-builder
# build_dynamo.sh owns the whole build, including its own apt deps, protoc,
# patchelf, maturin and the kvbm kernel-library bundling. The one thing it cannot
# infer is the kvbm offload arch: it falls back to a hardcoded ivcore11 and never
# reads COREX_ARCH, so pass it explicitly or an ivcore30 build compiles the wrong
# kernels silently.
ARG KVBM_CUDA_OFFLOAD_ARCH=${COREX_ARCH}
ARG DYNAMO_REPO
ARG DYNAMO_BRANCH
ARG DYNAMO_COMMIT
ARG DYNAMO_RUNTIME_FEATURES=media-ffmpeg,kv-indexer,kv-indexer-metrics,mm-routing,nvtx
RUN --mount=type=ssh \
    mkdir -p -m 0700 ~/.ssh \
    && ssh-keyscan -p 7999 bitbucket.iluvatar.ai >> ~/.ssh/known_hosts 2>/dev/null \
    && git clone --branch "${DYNAMO_BRANCH}" "${DYNAMO_REPO}" dynamo \
    && git -C dynamo fetch origin "${DYNAMO_COMMIT}" \
    && git -C dynamo checkout "${DYNAMO_COMMIT}" \
    && cd dynamo \
    && DYNAMO_WHEEL_DIR=build_pip \
       DYNAMO_RUNTIME_FEATURES="${DYNAMO_RUNTIME_FEATURES}" \
       RUST_MIRROR=rsproxy \
       bash iluvatar_platform/scripts/build_dynamo.sh \
    && mkdir -p /dynamo-dist \
    && cp build_pip/*.whl /dynamo-dist/
# Import here: this stage has the driver libraries, so it is the only place that
# can import torch.
RUN PIP_NO_INDEX=1 python3 -m pip install --no-deps /dynamo-dist/*.whl \
    && python3 -c "import dynamo, kvbm; print('dynamo-builder: dynamo/kvbm import OK')"


# ---- 8) vllm-router ---------------------------------------------------------
FROM dynamo-builder AS vllm-router-builder
# No build script and no rust-toolchain.toml: reuses the toolchain Dynamo
# installed under ~/.cargo.
ARG VLLM_ROUTER_REPO
ARG VLLM_ROUTER_BRANCH
ARG VLLM_ROUTER_COMMIT
# reqwest reaches openssl-sys and kube-rs wants libudev, so both dev packages are
# needed here rather than inherited from Dynamo's apt run.
RUN apt-get update -y \
    && apt-get install -y --no-install-recommends pkg-config libssl-dev libudev-dev \
    && rm -rf /var/lib/apt/lists/*
# crates.io mirror for this repo. Dynamo writes its mirror into its own tree, so
# nothing carries over; CARGO_HOME works here because the router's in-tree
# .cargo/config.toml only sets [build] and [target.*].
RUN mkdir -p "${CARGO_HOME:-${HOME}/.cargo}" \
    && printf '[source.crates-io]\nreplace-with = "rsproxy"\n\n[source.rsproxy]\nregistry = "sparse+https://rsproxy.cn/index/"\n' \
         >> "${CARGO_HOME:-${HOME}/.cargo}/config.toml"
RUN --mount=type=ssh \
    mkdir -p -m 0700 ~/.ssh \
    && ssh-keyscan -p 7999 bitbucket.iluvatar.ai >> ~/.ssh/known_hosts 2>/dev/null \
    && git clone --branch "${VLLM_ROUTER_BRANCH}" "${VLLM_ROUTER_REPO}" vllm-router \
    && git -C vllm-router fetch origin "${VLLM_ROUTER_COMMIT}" \
    && git -C vllm-router checkout "${VLLM_ROUTER_COMMIT}" \
    && cd vllm-router \
    && source "${CARGO_HOME:-${HOME}/.cargo}/env" \
    && cargo build --release --locked \
    && mkdir -p /router-dist \
    && install -m 0755 target/release/vllm-router /router-dist/vllm-router \
    && /router-dist/vllm-router --help > /dev/null


FROM ${BASE_IMAGE} AS runtime
ARG CPU_ARCH
ARG TARGET_COREX_ARCH
ARG IXFORMER_COMMIT
ARG VLLM_COMMIT
ARG VLLM_ILUVATAR_COMMIT
ARG NIXL_COMMIT
ARG DYNAMO_COMMIT
ARG VLLM_ROUTER_COMMIT
ARG DEEPEP_COMMIT
ARG VLLM_ILUVATAR_VERSION=0.31.0
ARG UBUNTU_VERSION=24.04
COPY --from=plugin-builder /build/iluvatar-build-info.json /etc/iluvatar-build-info.json
COPY docker/build-info.py /usr/local/bin/iluvatar-build-info
RUN chmod +x /usr/local/bin/iluvatar-build-info
COPY requirements.txt /tmp/plugin-requirements.txt
COPY --from=plugin-builder /opt/iluvatar-base/manifest.json /tmp/build-base-manifest.json
RUN iluvatar-check-base --check-requirements /tmp/plugin-requirements.txt \
         --match-manifest /tmp/build-base-manifest.json \
    && rm /tmp/plugin-requirements.txt /tmp/build-base-manifest.json
COPY --from=ixinfer-builder /ixinfer-dist/ /usr/local/corex/lib64/
COPY --from=ixinfer-builder /usr/local/corex/include/ixinfer.h /usr/local/corex/include/ixinfer.h
# The revision file ships beside the libraries; keep it out of the library dir.
RUN mv /usr/local/corex/lib64/ixinfer-revision.txt /etc/iluvatar-ixinfer-revision \
    && test -s /usr/local/corex/include/ixinfer.h && ldconfig
COPY --from=plugin-builder /wheels/ /tmp/wheels/
COPY --from=nixl-builder /nixl-dist/*.whl /tmp/wheels/
COPY --from=dynamo-builder /dynamo-dist/*.whl /tmp/wheels/
COPY --from=deepep-builder /deepep-dist/*.whl /tmp/wheels/
# --no-deps: the base already carries torch/triton/vLLM, and resolving here would
# replace the CoreX builds. Nothing imports kvbm at install time, so one
# transaction over all wheels is fine.
RUN PIP_NO_INDEX=1 python3 -m pip install --no-deps /tmp/wheels/*.whl \
    && rm -rf /tmp/wheels \
    && python3 -c "import importlib.metadata as m; print({d.metadata['Name']: d.version for d in m.distributions() if d.metadata['Name'] in ('vllm-iluvatar', 'nixl', 'nixl-cu10', 'nixl-cu12', 'ai-dynamo', 'ai-dynamo-runtime', 'kvbm', 'deep-ep')})"

# ---- 9) Dynamo/FFmpeg runtime libraries and vllm-router ---------------------
# ai-dynamo-runtime's _core and the Python stack import against these.
COPY --from=vllm-router-builder --chmod=755 /router-dist/vllm-router /usr/local/bin/vllm-router
RUN apt-get update -y \
    && apt-get install -y --no-install-recommends \
        libavcodec60 libavdevice60 libavfilter9 libavformat60 libavutil58 \
        libhwloc15 libswresample4 libswscale7 libxrender1 \
    && rm -rf /var/lib/apt/lists/* \
    && vllm-router --help > /dev/null

LABEL org.opencontainers.image.revision="${VLLM_ILUVATAR_COMMIT}" \
      ai.iluvatar.source.ixformer.revision="${IXFORMER_COMMIT}" \
      ai.iluvatar.source.vllm.revision="${VLLM_COMMIT}" \
      ai.iluvatar.source.nixl.revision="${NIXL_COMMIT}" \
      ai.iluvatar.source.dynamo.revision="${DYNAMO_COMMIT}" \
      ai.iluvatar.source.vllm_router.revision="${VLLM_ROUTER_COMMIT}" \
      ai.iluvatar.source.deepep.revision="${DEEPEP_COMMIT}" \
      org.opencontainers.image.title="vllm-iluvatar" \
      org.opencontainers.image.version="${VLLM_ILUVATAR_VERSION}-corex${COREX_VERSION}-py${COREX_PYTHON_VERSION}-ubuntu${UBUNTU_VERSION}" \
      ai.iluvatar.corex.version="${COREX_VERSION}" \
      ai.iluvatar.corex.arch="${COREX_ARCH}"
EXPOSE 8000
ENTRYPOINT ["vllm", "serve"]
