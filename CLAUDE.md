# SixWays Sandbox

Hardened container images for AI coding agent sandboxing.

## Stack

- **Base**: Wolfi (minimal, CVE-tracked container OS)
- **Build**: Dockerfile (multi-stage)
- **Variants**: base (~30 MB), node (~80 MB), python (~60 MB), devcontainer (~100 MB)

## Build

```bash
# Build base (tag as GHCR name so variants resolve locally)
docker build -t sixways-sandbox:base -t ghcr.io/sixways-ai/sixways-sandbox:latest -f base/Dockerfile .

# Build variants
docker build -t sixways-sandbox:node -t ghcr.io/sixways-ai/sixways-sandbox:node -f node/Dockerfile node/
docker build -t sixways-sandbox:python -f python/Dockerfile python/
docker build -t sixways-sandbox:devcontainer -f devcontainer/Dockerfile devcontainer/
```

## Test

```bash
ssh-keygen -t ed25519 -f /tmp/test_key -N ""
docker run -d -p 2222:22 -e AUTHORIZED_KEY="$(cat /tmp/test_key.pub)" sixways-sandbox:base
ssh -i /tmp/test_key -p 2222 -o StrictHostKeyChecking=no sandbox@127.0.0.1
which sudo  # should fail
```

## Architecture

- `base/Dockerfile` — Wolfi base with SSH + git + bash
- `node/Dockerfile` — Inherits base, adds Node.js 22 LTS
- `python/Dockerfile` — Inherits base, adds Python 3.12
- `devcontainer/Dockerfile` — Inherits node, adds VS Code Dev Container support
- `entrypoint.sh` — Generates host keys, writes authorized_keys from AUTHORIZED_KEY env, unsets env, execs sshd
- `sshd_config` — Pubkey only, no root login, no PAM, no password auth

## Security Design

- Non-root sandbox user (uid 1000)
- No sudo (removed at build time)
- SSH-only entry (no HTTP/API surface)
- Fresh host keys per container
- Ephemeral AUTHORIZED_KEY injection
