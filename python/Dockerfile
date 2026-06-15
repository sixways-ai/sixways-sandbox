# BASE_TAG selects the parent tag on GHCR (default path: .github/workflows/
# docker.yml passes BASE_TAG=base). BASE_IMAGE is the fully-qualified parent
# reference; it defaults to the GHCR ref built from BASE_TAG so the existing
# GHCR workflow is unchanged, but a registry-agnostic build (the signed
# Forgejo workflow) can override it to base off any registry host.
ARG BASE_TAG=latest
ARG BASE_IMAGE=ghcr.io/sixways-ai/sixways-sandbox:${BASE_TAG}
FROM ${BASE_IMAGE}

ARG PYTHON_VERSION=3.12

ENV PATH="/home/sandbox/.local/bin:${PATH}"

RUN apk add --no-cache \
    python-${PYTHON_VERSION} \
    py${PYTHON_VERSION}-pip \
    && mkdir -p /home/sandbox/.local \
    && chown sandbox:sandbox /home/sandbox/.local \
    && echo 'export PATH="/home/sandbox/.local/bin:$PATH"' >> /home/sandbox/.bash_profile \
    && chown sandbox:sandbox /home/sandbox/.bash_profile
