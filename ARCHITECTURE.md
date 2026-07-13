# SixWays Sandbox -- Architecture

Hardened container images for AI agent sandboxing.

## High-Level Design

Sandbox provides a hierarchy of minimal, security-hardened container images built on Wolfi. CLI-profile containers ship no listening service: the agent is launched and reached over `docker exec`, and "ssh into the sandbox" is served by the governed SSH bridge in the SixWays daemon (the in-container sshd was retired, SixWays #560). IDE and Desktop profiles add an NGINX mTLS reverse proxy to secure web-based endpoints (code-server and Selkies-GStreamer). Agents are installed at runtime rather than baked into images.

## Project Structure

```
base/Dockerfile        # Wolfi-based minimal image with git + bash + ssh client
node/Dockerfile        # Inherits base, adds Node.js 22 LTS
python/Dockerfile      # Inherits base, adds Python 3.12
devcontainer/Dockerfile # Inherits node, adds VS Code Dev Container support
desktop/Dockerfile     # Ubuntu-based, Selkies-GStreamer + Xfce4 + NGINX mTLS
desktop/desktop-entrypoint.sh  # Desktop session bootstrap (Xvfb, Selkies, NGINX)
desktop/config/        # NGINX mTLS config, supervisord, Selkies startup scripts
entrypoint.sh          # Passthrough: exec "$@" or idle (sleep infinity) for docker exec
```

## Key Abstractions

- **Image hierarchy**: `base` -> `node` / `python` -> `devcontainer`. The `desktop` variant is a separate Ubuntu-based image (not Wolfi) because Selkies-GStreamer and Xfce4 require packages not available in Wolfi. Each layer adds only what is needed.
- **Security layers**: Wolfi base OS, non-root user (uid 1000), no sudo, no in-container sshd (retired, SixWays #560), seccomp profile (`seccomp-sandbox.json`) -- default-deny with explicit syscall allowlist for git, ssh-client, and build tools.
- **Supply chain**: Base image pinned by SHA-256 digest for reproducible, supply-chain-safe builds.
- **NGINX mTLS proxy**: IDE and Desktop profiles run an NGINX reverse proxy with mutual TLS client certificate authentication. Code-server (IDE) and Selkies-GStreamer (Desktop) bind to localhost only; NGINX terminates TLS and verifies the client certificate before proxying requests.
- **Selkies-GStreamer**: The Desktop profile uses Selkies-GStreamer to stream an Xfce4 desktop session over WebRTC. The stream is exposed through the NGINX mTLS proxy rather than directly.
- **No listening service on CLI containers**: base/node/python containers expose no HTTP server, API, or ssh surface -- the agent is launched and reached over `docker exec`, and governed interactive access is the SixWays daemon's SSH bridge. IDE and Desktop profiles additionally expose an NGINX mTLS proxy for web-based access.

## Cross-Repo Dependencies

- Images used by **sixways-endpoint** in container sandbox mode.
- The devcontainer variant is used by **endpoint-vscode** for Dev Container-based agent sandboxing.

## Design Decisions

- **Wolfi over Alpine** -- Wolfi provides better CVE tracking and a more predictable patching story for security-sensitive workloads.
- **exec over in-container sshd** -- CLI containers are reached via `docker exec` and the daemon's governed SSH bridge, so no sshd runs in the image (retired, SixWays #560). IDE attachment (VS Code Remote) is served by the devcontainer's code-server, not sshd.
- **No pre-installed agents** -- The latest agent version is installed at runtime to avoid stale binaries and reduce image rebuild frequency.
- **Planned**: eBPF sidecar for kernel-level visibility inside containers.

## See Also

- [System Overview](https://github.com/sixways-ai/architecture/blob/main/docs/system-overview.md)
- [Repository Map](https://github.com/sixways-ai/architecture/blob/main/docs/repo-map.md)
- [Endpoint Modes](https://github.com/sixways-ai/architecture/blob/main/docs/concepts/endpoint-modes.md)
