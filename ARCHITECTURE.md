# SixWays Sandbox -- Architecture

Hardened container images for AI agent sandboxing.

## High-Level Design

Sandbox provides a hierarchy of minimal, security-hardened container images built on Wolfi. CLI-profile containers expose SSH as the primary entry point, with ephemeral public key injection and no root access. IDE and Desktop profiles add an NGINX mTLS reverse proxy to secure web-based endpoints (code-server and Selkies-GStreamer). Agents are installed at runtime rather than baked into images.

## Project Structure

```
base/Dockerfile        # Wolfi-based minimal image with SSH + git + bash
node/Dockerfile        # Inherits base, adds Node.js 22 LTS
python/Dockerfile      # Inherits base, adds Python 3.12
devcontainer/Dockerfile # Inherits node, adds VS Code Dev Container support
desktop/Dockerfile     # Ubuntu-based, Selkies-GStreamer + Xfce4 + NGINX mTLS
desktop/desktop-entrypoint.sh  # Desktop session bootstrap (Xvfb, Selkies, NGINX)
desktop/config/        # NGINX mTLS config, supervisord, Selkies startup scripts
entrypoint.sh          # Generates host keys, writes authorized_keys, execs sshd
sshd_config            # Hardened SSH config (pubkey only, no root, no PAM)
```

## Key Abstractions

- **Image hierarchy**: `base` -> `node` / `python` -> `devcontainer`. The `desktop` variant is a separate Ubuntu-based image (not Wolfi) because Selkies-GStreamer and Xfce4 require packages not available in Wolfi. Each layer adds only what is needed.
- **Security layers**: Wolfi base OS, non-root user (uid 1000), pubkey-only SSH authentication, no sudo, fresh host keys generated per container start, seccomp profile (`seccomp-sandbox.json`) -- default-deny with explicit syscall allowlist for SSH, git, and build tools, TCP forwarding and tunneling disabled in sshd_config.
- **Supply chain**: Base image pinned by SHA-256 digest for reproducible, supply-chain-safe builds.
- **AUTHORIZED_KEY injection**: An ephemeral public key is passed via environment variable, written to `authorized_keys` at startup, and the environment variable is unset before execing sshd.
- **NGINX mTLS proxy**: IDE and Desktop profiles run an NGINX reverse proxy with mutual TLS client certificate authentication. Code-server (IDE) and Selkies-GStreamer (Desktop) bind to localhost only; NGINX terminates TLS and verifies the client certificate before proxying requests.
- **Selkies-GStreamer**: The Desktop profile uses Selkies-GStreamer to stream an Xfce4 desktop session over WebRTC. The stream is exposed through the NGINX mTLS proxy rather than directly.
- **SSH as primary entry point**: CLI-profile containers expose no HTTP server or API surface -- all access is through SSH. IDE and Desktop profiles additionally expose an NGINX mTLS proxy for web-based access.

## Cross-Repo Dependencies

- Images used by **sixways-endpoint** in container sandbox mode.
- The devcontainer variant is used by **endpoint-vscode** for Dev Container-based agent sandboxing.

## Design Decisions

- **Wolfi over Alpine** -- Wolfi provides better CVE tracking and a more predictable patching story for security-sensitive workloads.
- **SSH over exec** -- SSH enables IDE attachment (VS Code Remote, JetBrains Gateway) which exec-based access cannot support.
- **No pre-installed agents** -- The latest agent version is installed at runtime to avoid stale binaries and reduce image rebuild frequency.
- **Planned**: eBPF sidecar for kernel-level visibility inside containers.

## See Also

- [System Overview](https://github.com/sixways-ai/architecture/blob/main/docs/system-overview.md)
- [Repository Map](https://github.com/sixways-ai/architecture/blob/main/docs/repo-map.md)
- [Endpoint Modes](https://github.com/sixways-ai/architecture/blob/main/docs/concepts/endpoint-modes.md)
