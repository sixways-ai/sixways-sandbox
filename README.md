# sixways-sandbox

Hardened container images for AI coding agent sandboxing.
Published to `ghcr.io/sixways-ai/sixways-sandbox`.

## Variants

| Tag | Contents | Size |
|-----|----------|------|
| `base` | SSH + git + bash | ~30 MB |
| `node` | base + Node.js 22 LTS + npm | ~80 MB |
| `python` | base + Python 3.12 + pip | ~60 MB |
| `devcontainer` | node + VSCode Dev Container support | ~100 MB |

## Quick start

```bash
# Generate a throwaway key pair
ssh-keygen -t ed25519 -f /tmp/sandbox_key -N ""

# Start a sandbox container
docker run -d \
  -p 2222:22 \
  -e AUTHORIZED_KEY="$(cat /tmp/sandbox_key.pub)" \
  ghcr.io/sixways-ai/sixways-sandbox:base

# Connect
ssh -i /tmp/sandbox_key -p 2222 -o StrictHostKeyChecking=no sandbox@127.0.0.1
```

For the Node.js variant, replace `:base` with `:node`. For Python, use `:python`. For Dev Containers, use `:devcontainer`.

## Security design

- **Wolfi base** - minimal, CVE-tracked OS built for containers
- **Non-root sandbox user** - uid 1000, no privilege escalation path
- **Pubkey-only SSH** - password auth, PAM, root login all disabled
- **No sudo** - removed at image build time to reduce escape surface
- **Fresh host keys per container** - no host keys are baked into the image; unique keys are generated at container startup, preventing fingerprint-based MITM
- **AUTHORIZED_KEY injection** - the SixWays Endpoint client passes an ephemeral public key via environment variable at container creation; the entrypoint writes it to `authorized_keys` and unsets the variable before exec'ing sshd
- **SSH is the only entry point** - no exposed HTTP, no API surface
- **seccomp profile** - default-deny syscall filter (`seccomp-sandbox.json`) with explicit allowlist for SSH, git, and build tools
- **TCP forwarding disabled** - `AllowTcpForwarding no` and `AllowStreamLocalForwarding no` in sshd_config prevent tunnel-based escapes

## Recommended runtime flags

For maximum isolation, run containers with these flags:

```bash
docker run -d \
  -p 2222:22 \
  -e AUTHORIZED_KEY="$(cat /tmp/sandbox_key.pub)" \
  --cap-drop=ALL \
  --read-only \
  --tmpfs /tmp \
  --tmpfs /run \
  -v sandbox-workspace:/workspace \
  -v sandbox-home:/home/sandbox \
  --network none \
  --security-opt seccomp=seccomp-sandbox.json \
  ghcr.io/sixways-ai/sixways-sandbox:base
```

| Flag | Purpose |
|------|---------|
| `--cap-drop=ALL` | Drop all Linux capabilities - the sandbox needs none |
| `--read-only` | Prevent modification of system binaries and config |
| `--tmpfs /tmp --tmpfs /run` | Writable scratch areas on a read-only root |
| `-v ...:/workspace` | Persistent writable workspace for the agent |
| `-v ...:/home/sandbox` | Persistent home dir for SSH keys, shell history, npm cache |
| `--network none` | No outbound network access; only the exposed SSH port is reachable |
| `--security-opt seccomp=seccomp-sandbox.json` | Default-deny syscall filter with allowlist for SSH, git, and build tools |

If the agent needs outbound access (e.g. `npm install`, `git clone`), replace `--network none` with a restricted Docker network or firewall rules.

## Running AI coding agents

The sandbox images don't ship with any agent pre-installed - agents are installed at runtime so you always get the latest version. The orchestrator (e.g. SixWays Endpoint) SSHs into the sandbox, installs the agent, and runs it.

### Claude Code (Anthropic) - uses `:node`

```bash
docker run -d -p 2222:22 \
  -e AUTHORIZED_KEY="$(cat /tmp/sandbox_key.pub)" \
  ghcr.io/sixways-ai/sixways-sandbox:node

ssh -i /tmp/sandbox_key -p 2222 sandbox@127.0.0.1 bash -lc '
  npm install -g @anthropic-ai/claude-code
  ANTHROPIC_API_KEY=sk-ant-... claude "fix the failing tests"
'
```

### Codex CLI (OpenAI) - uses `:node`

```bash
ssh -i /tmp/sandbox_key -p 2222 sandbox@127.0.0.1 bash -lc '
  npm install -g @openai/codex
  OPENAI_API_KEY=sk-... codex "refactor the auth module"
'
```

### Gemini CLI (Google) - uses `:node`

```bash
ssh -i /tmp/sandbox_key -p 2222 sandbox@127.0.0.1 bash -lc '
  npm install -g @google/gemini-cli
  GEMINI_API_KEY=... gemini
'
```

### OpenClaw - uses `:node`

```bash
ssh -i /tmp/sandbox_key -p 2222 sandbox@127.0.0.1 bash -lc '
  npm install -g openclaw
  openclaw agent
'
```

### Aider - uses `:python`

```bash
docker run -d -p 2222:22 \
  -e AUTHORIZED_KEY="$(cat /tmp/sandbox_key.pub)" \
  ghcr.io/sixways-ai/sixways-sandbox:python

ssh -i /tmp/sandbox_key -p 2222 sandbox@127.0.0.1 bash -lc '
  pip install --user aider-chat
  ANTHROPIC_API_KEY=sk-ant-... aider --model claude-sonnet-4-6
'
```

> **Note:** These examples show API keys inline for clarity. In production, pass keys via environment variables at `docker run` time or mount a secrets file - never hardcode them.

## Dev Container usage

The `devcontainer` variant is designed for running AI agent extensions (Copilot, Claude Code, Cline, etc.) inside VSCode, Cursor, or Windsurf Dev Containers with endpoint monitoring. It builds on the node variant and adds the packages VSCode needs to bootstrap its Extension Host inside the container.

Add a `.devcontainer/devcontainer.json` to your project:

```json
{
  "image": "ghcr.io/sixways-ai/sixways-sandbox:devcontainer",
  "customizations": {
    "vscode": {
      "extensions": [
        "sixways.endpoint"
      ]
    }
  },
  "remoteUser": "sandbox",
  "workspaceFolder": "/workspace"
}
```

The container stays alive via `sleep infinity` and VSCode attaches via `docker exec`. SSH is started in the background as an optional secondary access path.

## Building locally

The variant Dockerfiles inherit from `ghcr.io/sixways-ai/sixways-sandbox`. To build entirely from source, tag images with the GHCR name so derived builds resolve locally:

**Linux / macOS / WSL:**

```bash
# Build base image (tag it as the GHCR name so variants resolve locally)
docker build -t sixways-sandbox:base \
  -t ghcr.io/sixways-ai/sixways-sandbox:latest \
  -f base/Dockerfile .

# Build node variant (tag with GHCR name so devcontainer resolves locally)
docker build -t sixways-sandbox:node \
  -t ghcr.io/sixways-ai/sixways-sandbox:node \
  -f node/Dockerfile node/

# Build python variant
docker build -t sixways-sandbox:python -f python/Dockerfile python/

# Build devcontainer variant
docker build -t sixways-sandbox:devcontainer -f devcontainer/Dockerfile devcontainer/
```

**Windows (PowerShell):**

```powershell
docker build -t sixways-sandbox:base -t ghcr.io/sixways-ai/sixways-sandbox:latest -f base/Dockerfile .
docker build -t sixways-sandbox:node -t ghcr.io/sixways-ai/sixways-sandbox:node -f node/Dockerfile node/
docker build -t sixways-sandbox:python -f python/Dockerfile python/
docker build -t sixways-sandbox:devcontainer -f devcontainer/Dockerfile devcontainer/
```

## CI / GHCR publishing

Images are built and pushed to GHCR via [`.github/workflows/docker.yml`](.github/workflows/docker.yml). Three triggers:

| Trigger | When | Purpose |
|---------|------|---------|
| **Tag push** | `git tag v1.0.0 && git push origin v1.0.0` | Release a new version |
| **Scheduled** | Every Monday at 08:00 EST | Pick up upstream CVE fixes from Wolfi, Node, Python |
| **Manual** | Actions > "Docker Images" > "Run workflow" | On-demand rebuild |

## Testing

```bash
ssh-keygen -t ed25519 -f /tmp/test_key -N ""
docker run -d -p 2222:22 -e AUTHORIZED_KEY="$(cat /tmp/test_key.pub)" sixways-sandbox:base
ssh -i /tmp/test_key -p 2222 -o StrictHostKeyChecking=no sandbox@127.0.0.1

# Verify no privilege escalation tools
which sudo  # should fail
```

## Customizing

To add language runtimes or tools, create a new `Dockerfile` in a subdirectory that inherits from the base image:

```dockerfile
ARG BASE_TAG=latest
FROM ghcr.io/sixways-ai/sixways-sandbox:${BASE_TAG}

RUN apk add --no-cache python-3
```

Keep additions minimal - every binary is a potential escape vector.

## License

Apache 2.0 - see [LICENSE](LICENSE).
