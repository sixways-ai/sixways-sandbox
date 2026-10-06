# Pin the current wolfi-base index digest for reproducible builds. The weekly
# freshness job resolves and updates this pin. The published image has a
# separate digest that is signed with cosign and recorded in the Ed25519
# manifest.
FROM cgr.dev/chainguard/wolfi-base@sha256:65e1acb87a2bf356b92c5f70f3980f03b4bb51dfd483c834e01557525f15c1d9

# Node major and Python minor are pinned here, in the one place every variant
# inherits from. The regression suite asserts these majors so an unnoticed
# runtime jump fails the publish gate rather than the customer's launch.
ARG NODE_PACKAGE=nodejs-22
ARG PYTHON_VERSION=3.12

# Agent installation and runtime PATH. `npm install -g` installs executables in
# NPM_CONFIG_PREFIX, while `pip install --user` uses ~/.local. Both directories
# are under the sandbox user's HOME because /usr is read-only on the strict
# tier. Defining the paths in `base` gives every variant the same configuration.
ENV NPM_CONFIG_PREFIX=/home/sandbox/.npm-global
ENV PATH="/home/sandbox/.npm-global/bin:/home/sandbox/.local/bin:${PATH}"

COPY --chmod=755 common/patch-npm-deps.sh /tmp/patch-npm-deps.sh

# Upgrade preinstalled base packages, then install ours. Both commands use the latest
# Wolfi package versions at build time (apk --no-cache fetches a fresh index).
RUN apk upgrade --no-cache \
    && apk add --no-cache \
    openssh-client \
    git \
    bash \
    ca-certificates \
    shadow \
    # Common tools expected by AI coding agents (Claude Code, Codex, etc.)
    # Already in wolfi-base: tar, sed, grep, less, find, xargs, unzip
    curl \
    wget \
    jq \
    netcat-openbsd \
    gawk \
    rsync \
    ripgrep \
    # --- Native build toolchain (required at runtime) ---
    # The sandbox has no sudo, uses a read-only root filesystem on the strict
    # tier, and runs the agent as uid 1000. An agent cannot add a compiler with
    # `apk add`. Common compilers must therefore be included in the image.
    #
    # Without the toolchain, `npm install` fails for packages with native
    # addons (node-gyp runs make and g++, for example for
    # better-sqlite3, bcrypt, canvas) and `pip install` fails for every wheel
    # built from source (psycopg2, lxml).
    #
    # `build-base` is the Wolfi meta-package: gcc + g++ + make + pkgconf +
    # binutils + glibc-dev + libstdc++-dev + linux-headers + posix-cc-wrappers.
    # There is no separate `g++` or `pkg-config` package in Wolfi: `gcc` ships
    # the C++ driver and `pkgconf` provides the `pkg-config` binary.
    # cmake is not in build-base and is added explicitly (cmake-js, scikit-build,
    # and most C/C++ projects want it).
    build-base \
    cmake \
    # --- Agent runtimes (required at startup) ---
    # SixWays does not include agents in the images; it installs the agent in
    # the container at launch (`npm install -g @anthropic-ai/claude-code`,
    # `pip install --user aider-chat`, ... see `agent_install` in the
    # endpoint). Installation runs as uid 1000 without sudo on a read-only root
    # filesystem. The image must already contain the agent's interpreter.
    #
    # Both runtimes are included in `base` because the project language selects
    # the image, while the selected agent determines its runtime. For example,
    # Claude Code requires Node.js even when it runs in the `:rust` image. Keep
    # both runtimes in `base` so every variant can start every supported agent.
    ${NODE_PACKAGE} \
    npm \
    python-${PYTHON_VERSION} \
    py${PYTHON_VERSION}-pip \
    # Headers (Python.h) for building C extensions. The runtime `python`
    # package ships only pyconfig.h. Without this package, every source-built
    # wheel fails with "fatal error: Python.h: No such file or directory" even though
    # base provides gcc. The compiler and the headers are only useful together.
    # setuptools + wheel complete the sdist build path so pip does not have to
    # fetch a build backend over the network on every source build.
    python-${PYTHON_VERSION}-dev \
    py${PYTHON_VERSION}-setuptools \
    py${PYTHON_VERSION}-wheel \
    # Reinstall npm from npmjs into /usr so its bundled deps (notably node-gyp,
    # which the apk-packaged npm strips) are present. Without this, any
    # `npm install -g <pkg>` whose dep tree includes native code fails with
    # "Cannot find module 'node-gyp/bin/node-gyp.js'".
    # Remove the distribution npm package before replacing it so its original
    # package inventory/SBOM does not describe the patched upstream installation.
    && cp -a /usr/lib/node_modules/npm /tmp/sixways-npm-bootstrap \
    && apk del npm \
    && HOME=/root node /tmp/sixways-npm-bootstrap/bin/npm-cli.js install -g --prefix=/usr --cache /root/.npm npm@latest \
    && rm -rf /tmp/sixways-npm-bootstrap \
    && /tmp/patch-npm-deps.sh \
    && rm -f /tmp/patch-npm-deps.sh \
    # Drop the legacy apk-shipped builtin npmrc: its `python` and
    # `globalignorefile` keys aren't recognized by modern npm and produce
    # "Unknown builtin config" warnings on every command.
    && rm -f /usr/lib/node_modules/npm/npmrc \
    && rm -rf /root/.npm \
    && useradd -m -s /bin/bash -u 1000 sandbox \
    && usermod -p '*' sandbox \
    && apk del shadow \
    && mkdir -p /home/sandbox/.ssh \
    && chmod 700 /home/sandbox/.ssh \
    && chown sandbox:sandbox /home/sandbox/.ssh \
    && mkdir -p /workspace \
    && chown sandbox:sandbox /workspace \
    && mkdir -p /mnt \
    && chown sandbox:sandbox /mnt \
    # Writable install + cache targets for the launch-time agent install. The
    # endpoint mounts the sixways-cache-{npm,pip,cargo} volumes over these for
    # cross-session reuse; they must exist and be sandbox-owned either way.
    && mkdir -p /home/sandbox/.npm \
    /home/sandbox/.npm-global \
    /home/sandbox/.local/bin \
    /home/sandbox/.cache/pip \
    /home/sandbox/.cargo/registry \
    && chown -R sandbox:sandbox \
    /home/sandbox/.npm \
    /home/sandbox/.npm-global \
    /home/sandbox/.local \
    /home/sandbox/.cache \
    /home/sandbox/.cargo \
    && echo 'export PATH="/home/sandbox/.npm-global/bin:/home/sandbox/.local/bin:$PATH"' \
    >> /home/sandbox/.bash_profile \
    && chown sandbox:sandbox /home/sandbox/.bash_profile \
    # --- Privilege-escalation surface ---
    # `sudo` is removed and must stay removed: nothing in the sandbox may reach
    # root, and the toolchain above exists precisely so no agent ever needs to.
    #
    # Keep the BusyBox `su` applet. The endpoint starts as root and uses
    # `su -s /bin/sh sandbox -c '<install + exec>'` to switch to the sandbox
    # user; removing the applet prevents agents from starting. This `su` is a
    # symlink to non-setuid /usr/bin/busybox, and the root password is locked,
    # so uid 1000 cannot use it to become root. The regression suite verifies
    # that no setuid-root binary exists and that `su` cannot elevate privileges.
    && rm -f /usr/bin/sudo

# --- Brokered Git configuration (WI-SB-01, spec 5.4) ---
# The endpoint bind-mounts the host-side broker shim read-only at
# /usr/local/bin/sixways-git-shim and injects GIT_CONFIG_* variables at launch.
# Command-scope settings override the system settings defined here:
#   - credential.helper -> guarded wrapper: delegates to the shim when
#     mounted (read-scoped fetch tokens via the broker), returns nothing when
#     absent so plain `docker run` git keeps working.
#   - gpg.format ssh + gpg.ssh.program -> guarded wrapper: brokered agent
#     commit signing via the shim; falls back to ssh-keygen when run standalone.
#     commit.gpgsign is not set, so the program is inactive until
#     signing is requested.
#   - core.hooksPath is not set: the endpoint mounts the
#     commit-gate hooks and owns core.hooksPath via GIT_CONFIG_* env.
#     Nothing in this image may set core.hooksPath.
#   - No other credential helper, no url.*.insteadOf rewrites, no tokens may
#     ever be baked; the build fails if a stored-credential manager (e.g.
#     git-credential-manager) is installed by a package.
COPY --chmod=755 common/git-credential-sixways /opt/sixways/git-credential-sixways
COPY --chmod=755 common/git-ssh-sign-sixways /opt/sixways/git-ssh-sign-sixways
RUN git config --system credential.helper /opt/sixways/git-credential-sixways \
    && git config --system gpg.format ssh \
    && git config --system gpg.ssh.program /opt/sixways/git-ssh-sign-sixways \
    && ! command -v git-credential-manager \
    && ! command -v git-credential-manager-core \
    && ! git config --system --get core.hooksPath \
    && ! git config --system --list | grep -qi insteadof

# --- sixways-mcp-proxy (MCP governance wrapper) ---
# Static musl build of sixways-endpoint-dev's crates/sixways-mcp-proxy, built
# --no-default-features (stdio MCP servers only), staged in common/mcp-proxy/ by
# scripts/build-mcp-proxy.sh. Provenance (source commit, build command) is in
# common/mcp-proxy/PROVENANCE; the per-arch SHA-256 pins are in SHA256SUMS and are
# verified here, so a missing or altered binary fails the build rather than ship.
# Installed at the path the endpoint uses (MCP_PROXY_CONTAINER_PATH). When MCP
# governance is on, the endpoint bind-mounts the host's proxy over this file; the
# baked copy is what runs for `docker run` and for hosts that do not mount one.
# BuildKit sets TARGETARCH (amd64 | arm64).
ARG TARGETARCH
COPY common/mcp-proxy/SHA256SUMS common/mcp-proxy/PROVENANCE /tmp/mcp-proxy/
COPY common/mcp-proxy/sixways-mcp-proxy-linux-${TARGETARCH} /tmp/mcp-proxy/
RUN set -eu; \
    case "${TARGETARCH}" in amd64|arm64) ;; *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; esac; \
    cd /tmp/mcp-proxy; \
    grep " sixways-mcp-proxy-linux-${TARGETARCH}\$" SHA256SUMS | sha256sum -c -; \
    install -D -m 0755 -o root -g root "sixways-mcp-proxy-linux-${TARGETARCH}" /usr/local/bin/sixways-mcp-proxy; \
    install -D -m 0644 -o root -g root PROVENANCE /usr/local/share/sixways/mcp-proxy.PROVENANCE; \
    cd /; rm -rf /tmp/mcp-proxy

# --- sixways-probe (runtime policy canary probe client) ---
# Static musl build of sixways-endpoint-dev's crates/sixways-probe, staged in common/probe/
# by scripts/build-probe.sh and verified here against the committed SHA256SUMS. It is the
# in-sandbox client of the runtime policy probe (architecture
# docs/protocols/runtime-policy-probe.md): two HTTP GETs, one the applied policy must deny and
# one it must allow, and nothing else. Installed root-owned at the fixed path the managed
# policy's reserved canary rule lists; the connector delivers the same binary to
# /tmp/sixways-probe for images that lack it. The digest is per architecture.
COPY common/probe/SHA256SUMS common/probe/PROVENANCE /tmp/probe/
COPY common/probe/sixways-probe-linux-${TARGETARCH} /tmp/probe/
RUN set -eu; \
    case "${TARGETARCH}" in amd64|arm64) ;; *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; esac; \
    cd /tmp/probe; \
    grep " sixways-probe-linux-${TARGETARCH}\$" SHA256SUMS | sha256sum -c -; \
    install -D -m 0755 -o root -g root "sixways-probe-linux-${TARGETARCH}" /usr/local/bin/sixways-probe; \
    install -D -m 0644 -o root -g root PROVENANCE /usr/local/share/sixways/probe.PROVENANCE; \
    cd /; rm -rf /tmp/probe

COPY --chmod=755 entrypoint.sh /entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/entrypoint.sh"]
