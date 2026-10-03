# BASE_TAG selects the parent tag on GHCR (default path: the ghcr publish
# workflow passes BASE_TAG=base). BASE_IMAGE is the fully-qualified parent
# reference; it defaults to the GHCR ref built from BASE_TAG so the existing
# GHCR workflow is unchanged, but a registry-agnostic build (the signed
# Forgejo workflow) can override it to base off any registry host.
ARG BASE_TAG=latest
ARG BASE_IMAGE=ghcr.io/sixways-ai/sixways-sandbox:${BASE_TAG}
FROM ${BASE_IMAGE}

# Cargo's home. The strict tier mounts the rootfs read-only and runs the agent
# as uid 1000, so every path cargo writes (registry cache, git checkouts, build
# artifacts) must be under the sandbox user's writable HOME. `base`
# already creates /home/sandbox/.cargo/registry and the endpoint can mount the
# sixways-cache-cargo volume there for cross-session dependency reuse.
ENV CARGO_HOME=/home/sandbox/.cargo
ENV PATH="/home/sandbox/.cargo/bin:${PATH}"

# The Wolfi `rust` package provides rustc and cargo (there is no separate `cargo`
# package). The linker is `cc` from base's build-base. rustc does not link on
# its own, it drives the system C compiler, so this variant is only usable
# because `base` provides the toolchain.
#
# Agent runtimes also come from `base`. A Rust project can use a Node.js-based
# agent such as Claude Code, so this image must support `npm install -g` at
# startup. Removing either runtime inherited from `base` would prevent some
# agents from starting in this image.
RUN apk add --no-cache \
    rust \
    && mkdir -p /home/sandbox/.cargo/registry \
    && chown -R sandbox:sandbox /home/sandbox/.cargo \
    && echo 'export PATH="/home/sandbox/.cargo/bin:$PATH"' >> /home/sandbox/.bash_profile \
    && chown sandbox:sandbox /home/sandbox/.bash_profile
