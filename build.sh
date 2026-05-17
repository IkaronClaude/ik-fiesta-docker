#!/bin/bash
# Build the Fiesta runtime image.
#
# This script builds the linux/amd64 variant on a Linux Docker host.
# For windows/amd64, build on a Windows host using build.ps1 and push to the
# same image:tag, then run `combine-manifest.sh` to create the multi-arch
# manifest list.
#
# Usage:
#   ./build.sh                                  # build local image only
#   ./build.sh --push ghcr.io/you/fiesta-runtime:latest   # build + push linux variant
#
# To produce a true multi-platform image:
#   1. On Linux:    ./build.sh --push  ghcr.io/you/fiesta-runtime:latest
#   2. On Windows:  .\build.ps1 -Push ghcr.io/you/fiesta-runtime:latest
#   3. On either:   ./combine-manifest.sh ghcr.io/you/fiesta-runtime:latest

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

PUSH=0
IMAGE="fiesta-server-runtime:linux"

while [ $# -gt 0 ]; do
    case "$1" in
        --push)
            PUSH=1
            shift
            IMAGE="${1:?--push requires an image:tag argument}"
            shift
            ;;
        -h|--help)
            sed -n '2,12p' "$0"
            exit 0
            ;;
        *)
            IMAGE="$1"
            shift
            ;;
    esac
done

if [ "${PUSH}" -eq 1 ]; then
    # Push linux/amd64 variant with explicit platform, required so a later
    # `docker buildx imagetools create` can stitch this and the Windows variant
    # into a single multi-arch manifest list.
    docker buildx build \
        --file Dockerfile.linux \
        --platform linux/amd64 \
        --tag "${IMAGE}-linux-amd64" \
        --push \
        .
    echo
    echo "Pushed: ${IMAGE}-linux-amd64"
    echo "Next: build the windows/amd64 variant on a Windows host, then run:"
    echo "    ./combine-manifest.sh ${IMAGE}"
else
    docker build \
        --file Dockerfile.linux \
        --tag "${IMAGE}" \
        .
    echo
    echo "Built local image: ${IMAGE}"
    echo "Try it:"
    echo "    docker run --rm -v /path/to/fiesta-server:/fiesta \\"
    echo "        -e FIESTA_EXE=Login/Login.exe ${IMAGE}"
fi
