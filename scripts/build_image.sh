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
# The image is tagged for the Harbor registry with a CPU-arch + build-date suffix:
#   <REGISTRY>/<PROJECT>/<NAME>:<BASE_TAG>-<ARCH>-<BUILD_DATE>
# e.g. 10.150.9.98:80/aac-llmfp/vllm-iluvatar-0.31.0:corex5.0.1-ubuntu24.04-python3.12-x86_64-20261028
# The vLLM version is part of the repository name, not the tag. ARCH defaults to
# the build host's `uname -m` (x86_64 / aarch64); the registry/project prefix is
# REQUIRED to `docker push` to Harbor.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

REGISTRY="${REGISTRY:-10.150.9.98:80}"
PROJECT="${PROJECT:-aac-llmfp}"
NAME="${NAME:-vllm-iluvatar-0.31.0}"
BASE_TAG="${BASE_TAG:-corex5.0.1-ubuntu24.04-python3.12}"
ARCH="${ARCH:-$(uname -m)}"
BUILD_DATE="${BUILD_DATE:-$(date +%Y%m%d)}"
IMAGE="${REGISTRY}/${PROJECT}/${NAME}:${BASE_TAG}-${ARCH}-${BUILD_DATE}"

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
  --ssh "${SSH_ARG}" \
  --build-arg MAX_JOBS="${MAX_JOBS:-$(nproc)}" \
  -t "${IMAGE}" \
  "$@" \
  .

echo "==> built ${IMAGE}"
echo "==> push with: docker push ${IMAGE}"
