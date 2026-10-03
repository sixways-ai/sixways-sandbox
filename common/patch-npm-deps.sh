#!/usr/bin/env bash
# Purpose: replace vulnerable npm-bundled dependencies until npm ships fixes.
# Usage: patch-npm-deps.sh during a sandbox image build, after installing npm.
set -euo pipefail

patch_root="$(mktemp -d /tmp/sixways-npm-security.XXXXXX)"
trap 'rm -rf "$patch_root"' EXIT

# Installing into npm itself resolves unpublished development workspaces.
# Use an empty prefix and disable lifecycle scripts, then copy only the
# reviewed packages and their runtime dependencies into the bundled tree.
npm install --prefix "$patch_root" --cache "$patch_root/cache" \
    --omit=dev --ignore-scripts --no-save --package-lock=false --no-audit --no-fund \
    brace-expansion@5.0.11 ip-address@10.3.1 tar@7.5.21 undici@6.28.1

for package in @isaacs/fs-minipass balanced-match brace-expansion chownr \
    ip-address minipass minizlib tar undici yallist; do
    destination="/usr/lib/node_modules/npm/node_modules/$package"
    test -f "$patch_root/node_modules/$package/package.json"
    rm -rf "$destination"
    mkdir -p "$(dirname "$destination")"
    cp -a "$patch_root/node_modules/$package" "$destination"
done

npm --version
