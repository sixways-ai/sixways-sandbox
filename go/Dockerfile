# BASE_TAG selects the parent tag on GHCR (default path: the ghcr publish
# workflow passes BASE_TAG=base). BASE_IMAGE is the fully-qualified parent
# reference; it defaults to the GHCR ref built from BASE_TAG so the existing
# GHCR workflow is unchanged, but a registry-agnostic build (the signed
# Forgejo workflow) can override it to base off any registry host.
ARG BASE_TAG=latest
ARG BASE_IMAGE=ghcr.io/sixways-ai/sixways-sandbox:${BASE_TAG}
FROM ${BASE_IMAGE}

# Go's writable state. The strict tier mounts the rootfs read-only and runs the
# agent as uid 1000, so the module cache and build cache must point at the
# sandbox user's HOME. The defaults (~/go, ~/.cache/go-build) are already under
# HOME, but they are set explicitly here so a container launched with a
# different HOME still resolves to a writable path rather than failing with
# "failed to initialize build cache ... read-only file system".
ENV GOPATH=/home/sandbox/go
ENV GOCACHE=/home/sandbox/.cache/go-build
ENV GOMODCACHE=/home/sandbox/go/pkg/mod
ENV PATH="/home/sandbox/go/bin:${PATH}"

# The Wolfi `go` package ships the full toolchain (compiler, linker, `go`
# driver). cgo additionally needs a C compiler, which base provides via
# build-base; without it any module importing a cgo package (sqlite3, confluent
# kafka) fails to build.
#
# Agent runtimes also come from `base`. A Go project can use a Node.js-based
# agent such as Claude Code, so this image must support `npm install -g` at
# startup. Removing either runtime inherited from `base` would prevent some
# agents from starting in this image.
RUN apk add --no-cache \
    go \
    && mkdir -p /home/sandbox/go/bin /home/sandbox/go/pkg/mod /home/sandbox/.cache/go-build \
    && chown -R sandbox:sandbox /home/sandbox/go /home/sandbox/.cache \
    && echo 'export PATH="/home/sandbox/go/bin:$PATH"' >> /home/sandbox/.bash_profile \
    && chown sandbox:sandbox /home/sandbox/.bash_profile
