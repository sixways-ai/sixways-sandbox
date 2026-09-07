# Pinned to the latest wolfi-base index digest for reproducibility; bumped on
# each freshness pass (and re-resolved by the weekly scheduled rebuild). The
# published image's own digest is what gets cosign-signed + recorded in the
# Ed25519 manifest, so the supply-chain anchor is the output, not this input.
FROM cgr.dev/chainguard/wolfi-base@sha256:918a593b8268c222afd4e2c4f06860ac984e60719b4697e4c71d796bc8fcd042

# Upgrade preinstalled base packages, then install ours — both pull the latest
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
    && mkdir -p /home/sandbox/.npm /home/sandbox/.cache/pip /home/sandbox/.cargo/registry \
    && chown -R sandbox:sandbox /home/sandbox/.npm /home/sandbox/.cache /home/sandbox/.cargo \
    && rm -f /usr/bin/sudo /usr/bin/su

# --- Brokered git plumbing (WI-SB-01, spec 5.4) ---
# The endpoint bind-mounts the host-side broker shim READ-ONLY at
# /usr/local/bin/sixways-git-shim and injects hermetic GIT_CONFIG_* env at
# launch. Env (command scope) beats system scope, so the entries baked here
# can never fight the launch env; they make brokered git work before env
# injection settles and keep the image fully standalone:
#   - credential.helper -> guarded wrapper: delegates to the shim when
#     mounted (read-scoped fetch tokens via the broker), vends nothing when
#     absent so plain `docker run` git keeps working.
#   - gpg.format ssh + gpg.ssh.program -> guarded wrapper: brokered agent
#     commit signing via the shim; falls back to real ssh-keygen standalone.
#     commit.gpgsign is deliberately NOT set, so the program is inert until
#     signing is requested.
#   - core.hooksPath is deliberately NOT set: the endpoint mounts the
#     commit-gate hooks and owns core.hooksPath via GIT_CONFIG_* env.
#     Nothing in this image may set core.hooksPath.
#   - No other credential helper, no url.*.insteadOf rewrites, no tokens may
#     ever be baked; the build fails if a stored-credential manager (e.g.
#     git-credential-manager) sneaks in via a package.
COPY --chmod=755 common/git-credential-sixways /opt/sixways/git-credential-sixways
COPY --chmod=755 common/git-ssh-sign-sixways /opt/sixways/git-ssh-sign-sixways
RUN git config --system credential.helper /opt/sixways/git-credential-sixways \
    && git config --system gpg.format ssh \
    && git config --system gpg.ssh.program /opt/sixways/git-ssh-sign-sixways \
    && ! command -v git-credential-manager \
    && ! command -v git-credential-manager-core \
    && ! git config --system --get core.hooksPath \
    && ! git config --system --list | grep -qi insteadof

COPY --chmod=755 entrypoint.sh /entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/entrypoint.sh"]
