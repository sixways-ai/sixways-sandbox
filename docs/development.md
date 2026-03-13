# Development Guide: sixways-sandbox

## Prerequisites

- **Docker**

## First-Time Setup

No additional setup required beyond having Docker installed.

## Build

### Base image

```bash
docker build -t sixways-sandbox:base -t ghcr.io/sixways-ai/sixways-sandbox:latest -f base/Dockerfile .
```

### Language runtime variants

After building the base image, build the Node, Python, and devcontainer variants using their respective Dockerfiles (e.g., `node/Dockerfile`, `python/Dockerfile`, `devcontainer/Dockerfile`).

## Run

```bash
docker run -d -p 2222:22 \
  -e AUTHORIZED_KEY="$(cat ~/.ssh/id_ed25519.pub)" \
  sixways-sandbox:base
```

## Test

- SSH into the running container and verify:
  - No `sudo` access is available.
  - No privilege escalation paths exist.

```bash
ssh -p 2222 user@localhost
```

## Debug

Inspect container logs:

```bash
docker logs <container-id>
```

## Common Tasks

| Task | Description |
|---|---|
| Update the base image | Modify `base/Dockerfile` and rebuild |
| Add a language runtime variant | Create a new Dockerfile extending the base image |
| Modify SSH configuration | Edit the SSH config in the base Dockerfile |
