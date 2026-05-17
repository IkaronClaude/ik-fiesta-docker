#!/bin/bash
# Stitch the linux/amd64 and windows/amd64 variants pushed by build.sh /
# build.ps1 into a single multi-platform manifest list.
#
# After this runs, `docker pull <image>` will fetch the correct variant for
# the host's OS automatically.
#
# Usage:
#   ./combine-manifest.sh ghcr.io/you/fiesta-runtime:latest

set -eo pipefail

IMAGE="${1:?usage: $0 <image:tag>}"

LINUX_TAG="${IMAGE}-linux-amd64"
WINDOWS_TAG="${IMAGE}-windows-amd64"

echo "Combining:"
echo "  ${LINUX_TAG}"
echo "  ${WINDOWS_TAG}"
echo "  -> ${IMAGE}"
echo

docker buildx imagetools create \
    --tag "${IMAGE}" \
    "${LINUX_TAG}" \
    "${WINDOWS_TAG}"

echo
echo "Done. Verify with:"
echo "    docker buildx imagetools inspect ${IMAGE}"
