#!/usr/bin/env bash
# Build the vllm-iluvatar runtime image from source.
#
# The Dockerfile clones+compiles ixinfer / ixformer / vllm at the commits pinned
# in version.json, builds this plugin from the local checkout, and produces a
# runtime image (CoreX SDK + torch/triton + source-built libcuinfer + wheels).
#
# Cloning the pinned internal repos needs SSH access to bitbucket.iluvatar.ai.
# Provide it through an ssh-agent (default) or point SSH_KEY at a key file.
#
# The image is tagged for the Harbor registry with a CPU-arch + GPU-arch + build-date suffix:
#   <REGISTRY>/<PROJECT>/<NAME>:<BASE_TAG>-<CPU_ARCH>-<COREX_ARCH>-<BUILD_DATE>
# e.g. 10.150.9.98:80/aac-llmfp/vllm-iluvatar-0.31.0:corex5.0.1-ubuntu24.04-python3.12-x86_64-ivcore11-20261028
# CPU_ARCH defaults to uname -m; ARCH remains a compatibility alias.
# GPU selection requires matching runtime/build bases; renaming a tag is not
# sufficient. The vLLM version remains in the repository name.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

REGISTRY="${REGISTRY:-10.150.9.98:80}"
PROJECT="${PROJECT:-aac-llmfp}"
NAME="${NAME:-vllm-iluvatar-0.31.0}"
BASE_TAG="${BASE_TAG:-corex5.0.1-ubuntu24.04-python3.12}"
CPU_ARCH="${CPU_ARCH:-${ARCH:-$(uname -m)}}"
COREX_ARCH="${COREX_ARCH:-ivcore11}"
case "${CPU_ARCH}" in
  x86_64) PLATFORM=linux/amd64 ;;
  aarch64) PLATFORM=linux/arm64 ;;
  *) echo "Unsupported CPU_ARCH: ${CPU_ARCH}" >&2; exit 2 ;;
esac
case "${COREX_ARCH}" in
  ivcore11|ivcore30) ;;
  *) echo "Unsupported COREX_ARCH: ${COREX_ARCH}" >&2; exit 2 ;;
esac
if [[ "${CPU_ARCH}" != x86_64 || "${COREX_ARCH}" != ivcore11 ]]; then
  : "${BASE_IMAGE:?Provide a verified runtime base for the requested CPU/GPU architecture}"
  : "${BUILD_BASE_IMAGE:?Provide the matching build base}"
fi
BUILD_DATE="${BUILD_DATE:-$(TZ=Asia/Shanghai date +%Y%m%d)}"
IMAGE="${REGISTRY}/${PROJECT}/${NAME}:${BASE_TAG}-${CPU_ARCH}-${COREX_ARCH}-${BUILD_DATE}"
BASE_ARGS=()
[[ -z "${BASE_IMAGE:-}" ]] || BASE_ARGS+=(--build-arg "BASE_IMAGE=${BASE_IMAGE}")
[[ -z "${BUILD_BASE_IMAGE:-}" ]] || BASE_ARGS+=(--build-arg "BUILD_BASE_IMAGE=${BUILD_BASE_IMAGE}")

# SSH forwarding for the in-build git clones. Default to the running ssh-agent;
# set SSH_KEY=/path/to/key to use a specific private key instead.
if [[ -n "${SSH_KEY:-}" ]]; then
  SSH_ARG="default=${SSH_KEY}"
else
  SSH_ARG="default"
fi

echo "==> building ${IMAGE}"
DOCKER_BUILDKIT=1 docker build \
  -f Dockerfile \
  --platform "${PLATFORM}" \
  --build-arg CPU_ARCH="${CPU_ARCH}" \
  --build-arg TARGET_COREX_ARCH="${COREX_ARCH}" \
  "${BASE_ARGS[@]}" \
  --ssh "${SSH_ARG}" \
  --build-arg MAX_JOBS="${MAX_JOBS:-$(nproc)}" \
  -t "${IMAGE}" \
  "$@" \
  .

echo "==> built ${IMAGE}"
echo "==> push with: docker push ${IMAGE}"
