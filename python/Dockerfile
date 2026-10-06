# BASE_TAG selects the parent tag on GHCR (default path: .github/workflows/
# docker.yml passes BASE_TAG=base). BASE_IMAGE is the fully-qualified parent
# reference; it defaults to the GHCR ref built from BASE_TAG so the existing
# GHCR workflow is unchanged, but a registry-agnostic build (the signed
# Forgejo workflow) can override it to base off any registry host.
ARG BASE_TAG=latest
ARG BASE_IMAGE=ghcr.io/sixways-ai/sixways-sandbox:${BASE_TAG}
FROM ${BASE_IMAGE}

# `base` provides Python 3.12, pip, the development headers, setuptools, and
# wheel. This variant adds no packages.
#
# SixWays installs agents when the container starts. Pip-installed agents such
# as Aider and Omnigent can run against projects in any language, so every
# variant inherits Python from `base`. The same rule allows a Python project to
# run a Node.js-based agent without switching images.
#
# The tag is kept because it is a published contract: the endpoint pulls
# `sixways-sandbox:python` for Python projects, and the signed per-tag manifests
# are keyed by variant name.
#
# Add packages here only when Python projects require them and projects in other
# languages do not. Packages required by agents belong in `base`.
LABEL org.opencontainers.image.title="SixWays Sandbox (Python)"
LABEL org.opencontainers.image.description="Python project variant. Python 3.12 + pip + headers + Node 22 + npm are inherited from base, so this image can host any SixWays agent."
