# sixways-sandbox

Hardened container images for AI coding agent sandboxing, used by [SixWays Nforcer](https://github.com/sixways-ai).

Published to `ghcr.io/sixways-ai/sixways-sandbox`.

## Variants

| Tag | Contents | Size |
|-----|----------|------|
| `base` | SSH + git + bash | ~30 MB |
| `node` | base + Node.js 22 LTS + npm | ~80 MB |

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

For the Node.js variant, replace `:base` with `:node`.

## Security design

- **Wolfi base** - minimal, CVE-tracked OS built for containers
- **Non-root sandbox user** - uid 1000, no privilege escalation path
- **Pubkey-only SSH** - password auth, PAM, root login all disabled
- **No sudo, no curl, no wget** - removed at image build time to reduce escape surface
- **Fresh host keys per container** - no host keys are baked into the image; unique keys are generated at container startup, preventing fingerprint-based MITM
- **AUTHORIZED_KEY injection** - the Nforcer client passes an ephemeral public key via environment variable at container creation; the entrypoint writes it to `authorized_keys` and unsets the variable before exec'ing sshd
- **SSH is the only entry point** - no exposed HTTP, no API surface

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

If the agent needs outbound access (e.g. `npm install`, `git clone`), replace `--network none` with a restricted Docker network or firewall rules.

## Building locally

```bash
# Build base image
docker build -t sixways-sandbox:base -f base/Dockerfile .

# Build node variant (using local base - sed replaces the registry prefix)
sed 's|FROM ghcr.io/sixways-ai/sixways-sandbox:|FROM sixways-sandbox:|' node/Dockerfile | \
  docker build -t sixways-sandbox:node -f - --build-arg BASE_TAG=base .
```

## Testing

```bash
ssh-keygen -t ed25519 -f /tmp/test_key -N ""
docker run -d -p 2222:22 -e AUTHORIZED_KEY="$(cat /tmp/test_key.pub)" sixways-sandbox:base
ssh -i /tmp/test_key -p 2222 -o StrictHostKeyChecking=no sandbox@127.0.0.1

# Verify no dangerous tools
which curl  # should fail
which wget  # should fail
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
