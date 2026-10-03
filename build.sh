#!/bin/bash
set -euo pipefail

# SixWays Sandbox -- Local CLI Image Build Script
#
# Usage:
#   ./build.sh              # Build for current platform (auto-detect)
#   ./build.sh arm64        # Build for ARM64 (Apple Silicon)
#   ./build.sh amd64        # Build for x86_64
#   ./build.sh --clean      # Clean slate: remove volumes, rebuild with --no-cache
#   ./build.sh arm64 --clean
#
# Builds base/node/python/rust/go only. The external IDE extension is released
# separately; hosted IDE and desktop sources are deferred. microVM images use
# scripts/build-microvm.sh. This script does not publish images.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Parse arguments ---
PLATFORM=""
CLEAN=false
BUILD_FLAGS=(--pull=false)
for arg in "$@"; do
    case "$arg" in
        arm64|aarch64) PLATFORM="linux/arm64" ;;
        amd64|x86_64|x64) PLATFORM="linux/amd64" ;;
        --clean) CLEAN=true ;;
        --help|-h)
            echo "Usage: $0 [arm64|amd64] [--clean]"
            echo ""
            echo "  arm64/amd64   Target platform (default: auto-detect)"
            echo "  --clean       Remove volumes, rebuild with --no-cache --pull"
            exit 0
            ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

# Auto-detect platform if not specified
if [[ -z "$PLATFORM" ]]; then
    ARCH=$(uname -m)
    case "$ARCH" in
        arm64|aarch64) PLATFORM="linux/arm64" ;;
        x86_64|amd64)  PLATFORM="linux/amd64" ;;
        *) echo "Unknown architecture: $ARCH"; exit 1 ;;
    esac
fi

echo ""
echo "  SixWays Sandbox — Local Build"
echo "  Platform: $PLATFORM"
echo "  Clean:    $CLEAN"
echo ""

# --- Clean slate (if requested) ---
if [[ "$CLEAN" == "true" ]]; then
    echo "[1/7] Cleaning up..."
    # Stop and remove sandbox containers
    CONTAINERS=$(docker ps -a --filter "name=sixways" -q 2>/dev/null || true)
    if [[ -n "$CONTAINERS" ]]; then
        echo "  Stopping containers..."
        echo "$CONTAINERS" | xargs docker rm -f 2>/dev/null || true
    fi
    # Remove persistent volumes
    for vol in sixways-sandbox-home sixways-cache-npm sixways-cache-pip sixways-cache-cargo; do
        docker volume rm "$vol" 2>/dev/null && echo "  Removed volume: $vol" || true
    done
    BUILD_FLAGS=(--no-cache --pull)
    echo "  Done."
else
    echo "[1/7] Skipping cleanup (use --clean for full rebuild)"
fi

# --- sixways-mcp-proxy (baked into base) ---
# Built from the sixways-endpoint-dev commit pinned in common/mcp-proxy/PROVENANCE and
# verified against common/mcp-proxy/SHA256SUMS. Point SIXWAYS_ENDPOINT_DIR at a checkout
# of that commit (default ../sixways-endpoint-dev) if the binaries are not staged yet.
if ! (cd "$SCRIPT_DIR/common/mcp-proxy" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1); then
    echo ""
    echo "Staging sixways-mcp-proxy..."
    "$SCRIPT_DIR/scripts/build-mcp-proxy.sh" "${SIXWAYS_ENDPOINT_DIR:-$SCRIPT_DIR/../sixways-endpoint-dev}" || exit 1
fi

# --- Build image chain ---
echo ""
echo "[2/7] Building base image..."
docker build --platform "$PLATFORM" "${BUILD_FLAGS[@]}" \
    -t sixways-sandbox:base \
    -t ghcr.io/sixways-ai/sixways-sandbox:latest \
    -f base/Dockerfile "$SCRIPT_DIR"

echo ""
echo "[3/7] Building node image..."
docker build --platform "$PLATFORM" "${BUILD_FLAGS[@]}" \
    -t sixways-sandbox:node \
    -t ghcr.io/sixways-ai/sixways-sandbox:node \
    --build-arg BASE_IMAGE=sixways-sandbox:base \
    -f node/Dockerfile "$SCRIPT_DIR"

echo ""
echo "[4/7] Building python image..."
docker build --platform "$PLATFORM" "${BUILD_FLAGS[@]}" \
    -t sixways-sandbox:python \
    -t ghcr.io/sixways-ai/sixways-sandbox:python \
    --build-arg BASE_IMAGE=sixways-sandbox:base \
    -f python/Dockerfile "$SCRIPT_DIR"

echo ""
echo "[5/7] Building rust + go images..."
docker build --platform "$PLATFORM" "${BUILD_FLAGS[@]}" \
    -t sixways-sandbox:rust \
    -t ghcr.io/sixways-ai/sixways-sandbox:rust \
    --build-arg BASE_IMAGE=sixways-sandbox:base \
    -f rust/Dockerfile "$SCRIPT_DIR"
docker build --platform "$PLATFORM" "${BUILD_FLAGS[@]}" \
    -t sixways-sandbox:go \
    -t ghcr.io/sixways-ai/sixways-sandbox:go \
    --build-arg BASE_IMAGE=sixways-sandbox:base \
    -f go/Dockerfile "$SCRIPT_DIR"

# --- Verify ---
echo ""
echo "[6/7] Verifying..."
ACTUAL_ARCH=$(docker inspect sixways-sandbox:base --format '{{.Architecture}}')
EXPECTED_ARCH=$(echo "$PLATFORM" | cut -d/ -f2)
if [[ "$ACTUAL_ARCH" == "$EXPECTED_ARCH" ]]; then
    echo "  Architecture: $ACTUAL_ARCH (correct)"
else
    echo "  WARNING: Expected $EXPECTED_ARCH but got $ACTUAL_ARCH"
    echo "  Try: $0 $EXPECTED_ARCH --clean"
    exit 1
fi

# List built images
echo ""
echo "[7/7] Built CLI images:"
docker images --format "  {{.Repository}}:{{.Tag}}\t{{.Size}}" | grep -E 'sixways-sandbox:(base|latest|node|python|rust|go)[[:space:]]' | sort

echo ""
echo "  Build complete."
echo ""
