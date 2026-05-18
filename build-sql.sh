#!/bin/bash
# Build the Fiesta SQL Server runtime image (Linux variant).
#
# Parallel to ./build.sh -- same shape, just the sql image instead of the
# game runtime. See PLAN.md and Dockerfile.sql.linux for the contract.
#
# Usage:
#   ./build-sql.sh                                       # build local image only
#   ./build-sql.sh --push ghcr.io/you/fiesta-sql-runtime:latest

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

PUSH=0
IMAGE="fiesta-sql-runtime:linux"

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
    docker buildx build \
        --file Dockerfile.sql.linux \
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
        --file Dockerfile.sql.linux \
        --tag "${IMAGE}" \
        .
    echo
    echo "Built local image: ${IMAGE}"
    echo "Try it:"
    echo "    docker run --rm -e SA_PASSWORD=YourStrongPassword1 \\"
    echo "        -e ACCEPT_EULA=Y -p 1433:1433 \\"
    echo "        -v /path/to/Server/Databases:/var/opt/mssql/backup:ro \\"
    echo "        ${IMAGE}"
fi
