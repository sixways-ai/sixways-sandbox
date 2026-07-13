# Pinned to the latest wolfi-base index digest for reproducibility; bumped on
# each freshness pass (and re-resolved by the weekly scheduled rebuild). The
# published image's own digest is what gets cosign-signed + recorded in the
# Ed25519 manifest, so the supply-chain anchor is the output, not this input.
FROM cgr.dev/chainguard/wolfi-base@sha256:02dab76bd852a70556b5b2002195c8a5fdab77d323c433bf6642aab080489795

# Upgrade preinstalled base packages, then install ours — both pull the latest
# Wolfi package versions at build time (apk --no-cache fetches a fresh index).
RUN apk upgrade --no-cache \
    && apk add --no-cache \
    openssh-server \
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
    && mkdir -p /var/run/sshd /etc/ssh /var/empty \
    && mkdir -p /home/sandbox/.ssh \
    && chmod 700 /home/sandbox/.ssh \
    && chown sandbox:sandbox /home/sandbox/.ssh \
    && mkdir -p /workspace \
    && chown sandbox:sandbox /workspace \
    && mkdir -p /mnt \
    && chown sandbox:sandbox /mnt \
    && mkdir -p /home/sandbox/.npm /home/sandbox/.cache/pip /home/sandbox/.cargo/registry \
    && chown -R sandbox:sandbox /home/sandbox/.npm /home/sandbox/.cache /home/sandbox/.cargo \
    && rm -f /usr/bin/sudo /usr/bin/su \
    && rm -f /etc/ssh/ssh_host_*

COPY sshd_config /etc/ssh/sshd_config
COPY --chmod=755 entrypoint.sh /entrypoint.sh

EXPOSE 22
WORKDIR /workspace
ENTRYPOINT ["/entrypoint.sh"]
