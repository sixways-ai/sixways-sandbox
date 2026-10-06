# BASE_TAG selects the parent tag on GHCR (default path: .github/workflows/
# docker.yml passes BASE_TAG=base). BASE_IMAGE is the fully-qualified parent
# reference; it defaults to the GHCR ref built from BASE_TAG so the existing
# GHCR workflow is unchanged, but a registry-agnostic build (the signed
# Forgejo workflow) can override it to base off any registry host.
ARG BASE_TAG=latest
ARG BASE_IMAGE=ghcr.io/sixways-ai/sixways-sandbox:${BASE_TAG}
FROM ${BASE_IMAGE}

# `base` provides Node.js 22, npm with node-gyp, Python 3.12, pip,
# NPM_CONFIG_PREFIX, and the agent PATH. This variant adds no packages.
#
# SixWays installs agents when the container starts. Because agents that use
# Node.js can run against projects in any language, every variant inherits the
# Node.js runtime from `base`.
#
# The tag is kept because it is a published contract: the endpoint pulls
# `sixways-sandbox:node` for Node projects, `:devcontainer` is built FROM it, and
# the signed per-tag manifests are keyed by variant name.
#
# Add packages here only when Node projects require them and projects in other
# languages do not. Packages required by agents belong in `base`.
LABEL org.opencontainers.image.title="SixWays Sandbox (Node.js)"
LABEL org.opencontainers.image.description="Node.js project variant. Node 22 + npm + Python 3.12 + pip are inherited from base, so this image can host any SixWays agent."
