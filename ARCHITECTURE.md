# SixWays Sandbox — Architecture

Hardened container images for AI agent sandboxing.

## High-Level Design

Sandbox provides a hierarchy of minimal, security-hardened container images built on Wolfi. Containers expose only SSH as an entry point, with ephemeral public key injection and no root access. Agents are installed at runtime rather than baked into images.

## Project Structure

```
base/Dockerfile        # Wolfi-based minimal image with SSH + git + bash
node/Dockerfile        # Inherits base, adds Node.js 22 LTS
python/Dockerfile      # Inherits base, adds Python 3.12
devcontainer/Dockerfile # Inherits node, adds VS Code Dev Container support
entrypoint.sh          # Generates host keys, writes authorized_keys, execs sshd
sshd_config            # Hardened SSH config (pubkey only, no root, no PAM)
```

## Key Abstractions

- **Image hierarchy**: `base` -> `node` / `python` -> `devcontainer`. Each layer adds only what is needed.
- **Security layers**: Wolfi base OS, non-root user (uid 1000), pubkey-only SSH authentication, no sudo, fresh host keys generated per container start.
- **AUTHORIZED_KEY injection**: An ephemeral public key is passed via environment variable, written to `authorized_keys` at startup, and the environment variable is unset before execing sshd.
- **SSH as sole entry point**: No HTTP server, no API surface. All access is through SSH, which provides IDE compatibility and auditability.

## Cross-Repo Dependencies

- Images used by **sixways-endpoint** in container sandbox mode.
- The devcontainer variant is used by **endpoint-vscode** for Dev Container-based agent sandboxing.

## Design Decisions

- **Wolfi over Alpine** — Wolfi provides better CVE tracking and a more predictable patching story for security-sensitive workloads.
- **SSH over exec** — SSH enables IDE attachment (VS Code Remote, JetBrains Gateway) which exec-based access cannot support.
- **No pre-installed agents** — The latest agent version is installed at runtime to avoid stale binaries and reduce image rebuild frequency.
- **Planned**: eBPF sidecar for kernel-level visibility inside containers.

## See Also

- [System Overview](https://github.com/sixways-ai/architecture/blob/main/docs/system-overview.md)
- [Repository Map](https://github.com/sixways-ai/architecture/blob/main/docs/repo-map.md)
- [Endpoint Modes](https://github.com/sixways-ai/architecture/blob/main/docs/concepts/endpoint-modes.md)
