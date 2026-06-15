#!/bin/bash
set -euo pipefail

# SixWays Sandbox — Local Image Build Script
#
# Usage:
#   ./build.sh              # Build for current platform (auto-detect)
#   ./build.sh arm64        # Build for ARM64 (Apple Silicon)
#   ./build.sh amd64        # Build for x86_64
#   ./build.sh --clean      # Clean slate: remove volumes, rebuild with --no-cache
#   ./build.sh arm64 --clean

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXTENSION_REPO="${SCRIPT_DIR}/../endpoint-vscode"

# --- Parse arguments ---
PLATFORM=""
CLEAN=false
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
    echo "[1/6] Cleaning up..."
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
    CACHE_FLAG="--no-cache --pull"
    echo "  Done."
else
    CACHE_FLAG=""
    echo "[1/6] Skipping cleanup (use --clean for full rebuild)"
fi

# --- Build VS Code extension ---
echo ""
echo "[2/6] Building VS Code extension..."
if [[ -d "$EXTENSION_REPO" ]]; then
    (
        cd "$EXTENSION_REPO"
        # Install deps if needed
        if [[ ! -d "node_modules" ]]; then
            echo "  Installing npm dependencies..."
            npm install --silent
        fi
        npm run build --silent
        npm run package --silent 2>&1 | tail -1
    )
    # Copy .vsix into sandbox extensions dir
    VSIX=$(ls -t "$EXTENSION_REPO"/endpoint-*.vsix 2>/dev/null | head -1)
    if [[ -n "$VSIX" ]]; then
        cp "$VSIX" "$SCRIPT_DIR/devcontainer/extensions/"
        echo "  Copied $(basename "$VSIX") to devcontainer/extensions/"
    else
        echo "  WARNING: No .vsix file found after build"
    fi
else
    echo "  WARNING: endpoint-vscode repo not found at $EXTENSION_REPO"
    echo "  The devcontainer image will install from Open VSX at runtime instead."
fi

# --- Build image chain ---
echo ""
echo "[3/6] Building base image..."
docker build --platform "$PLATFORM" $CACHE_FLAG --pull=false \
    -t sixways-sandbox:base \
    -t ghcr.io/sixways-ai/sixways-sandbox:latest \
    -f base/Dockerfile "$SCRIPT_DIR"

echo ""
echo "[4/6] Building node image..."
docker build --platform "$PLATFORM" $CACHE_FLAG --pull=false \
    -t sixways-sandbox:node \
    -t ghcr.io/sixways-ai/sixways-sandbox:node \
    -f node/Dockerfile "$SCRIPT_DIR/node/"

echo ""
echo "[5/6] Building devcontainer image..."
docker build --platform "$PLATFORM" $CACHE_FLAG --pull=false \
    -t sixways-sandbox:devcontainer \
    -f devcontainer/Dockerfile "$SCRIPT_DIR"

# --- Verify ---
echo ""
echo "[6/6] Verifying..."
ACTUAL_ARCH=$(docker inspect sixways-sandbox:devcontainer --format '{{.Architecture}}')
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
echo "  Built images:"
docker images --format "  {{.Repository}}:{{.Tag}}\t{{.Size}}" | grep sixways-sandbox | sort

echo ""
echo "  Build complete."
echo ""
