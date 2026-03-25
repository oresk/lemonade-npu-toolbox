#!/bin/bash
# Build lemonade-npu-toolbox locally for development/testing.
# Usage: ./refresh-toolboxes.sh [FLM_VERSION]

set -euo pipefail

FLM_VERSION="${1:-}"

if [ -z "$FLM_VERSION" ]; then
    FLM_VERSION=$(curl -fsSL https://api.github.com/repos/FastFlowLM/FastFlowLM/releases/latest \
        | jq -r '.tag_name' | sed 's/^v//')
    echo "Using latest FastFlowLM: ${FLM_VERSION}"
fi

IMAGE="lemonade-npu-toolbox:flm-${FLM_VERSION}"

echo "Building ${IMAGE}..."
podman build \
    --no-cache \
    --build-arg "FLM_VERSION=${FLM_VERSION}" \
    -t "${IMAGE}" \
    -t "lemonade-npu-toolbox:latest" \
    -f toolboxes/Dockerfile.lemonade-npu \
    toolboxes/

echo "Done: ${IMAGE}"
echo ""
echo "Test run:"
echo "  podman run --rm -it \\"
echo "    --device /dev/accel/accel0 \\"
echo "    --ulimit memlock=-1:-1 \\"
echo "    --security-opt seccomp=unconfined \\"
echo "    -v /mnt/models:/mnt/models \\"
echo "    -p 8000:8000 -p 52625:52625 \\"
echo "    ${IMAGE}"
