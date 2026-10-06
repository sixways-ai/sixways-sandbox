# Development Guide: sixways-sandbox

Local build, test, and troubleshooting guide for the first-release CLI images.

## Release scope

The container targets are `base`, `node`, `python`, `rust` and `go`. They have no
hosted IDE or desktop service. Agents attach through `docker exec` or the
endpoint's governed SSH bridge. The external SixWays VS Code extension is built
and released separately; these scripts do not compile or embed its VSIX.

Hosted code-server (`devcontainer/`) and Selkies/Xfce (`desktop/`) sources are
retained in the private development tree for later work. They are excluded from
default builds, release signing/promotion, and public source snapshots. Their
behavioral suites can still be selected by explicit variant name for maintenance.
This repository change does not remove session choices from the endpoint UI.

## Prerequisites

- Docker Desktop on macOS/Windows, or Docker Engine on Linux.
- Python 3 and PyYAML 6.0.3 for release-selection tests.
- ShellCheck for shell verification.

The CLI image build does not require a sibling extension checkout or host npm.

## Build the CLI image chain

From the repository root:

```bash
./build.sh                # detect the current architecture
./build.sh arm64          # build Linux ARM64 images
./build.sh amd64          # build Linux x86_64 images
```

On Windows, use `build.bat [arm64|amd64]`; its default is amd64. Both scripts build
base first, followed by node/python/rust/go, and verify the base architecture.
They build local images without publishing them.

The hierarchy is:

```text
base (Wolfi + tools + native build toolchain + Node.js 22 + Python 3.12)
  +-- node (project-language tag; inherits the runtimes)
  +-- python (project-language tag; inherits the runtimes)
  +-- rust (+ rustc + cargo)
  +-- go (+ Go toolchain)
```

Rebuild children whenever their parent changes. Agents run as uid 1000 with a
read-only root filesystem under the strict tier, so the base must contain the
native toolchain and both agent runtimes before launch.

The existing `--clean` option removes matching sandbox containers and persistent
sandbox volumes, then builds with `--no-cache --pull`. Use it only when that data
can be discarded. A regular build preserves those volumes.

## Existing microVM images

The premium image path remains separate:

```bash
scripts/build-microvm.sh            # microvm-base, microvm-node, microvm-python
scripts/build-microvm.sh node       # only the requested variant
scripts/build-microvm.sh --skip-binaries # reuse pre-staged guest binaries
```

These builds target Linux amd64 and require the documented endpoint/premium
sibling repositories and guest binaries. The private development tree contains `microvm/README.md`
with signed disk-image delivery details. Retaining that path does not qualify a new
OpenShell runtime driver.

## Verify selection and images

Selection tests use a Docker command spy and inspect release workflows in the
private development tree. Checks for omitted private/premium files are skipped in
public snapshots. They do
not build images, contact registries, or execute publication:

```bash
python3 tests/test-release-selection.py
bash -n build.sh tests/test-sandbox-images.sh scripts/build-microvm.sh
shellcheck --severity=warning build.sh tests/test-sandbox-images.sh scripts/build-microvm.sh
```

Run the actual image suite against already-built tags:

```bash
tests/test-sandbox-images.sh        # base node python rust go
tests/test-sandbox-images.sh all    # the same first-release CLI variants
```

Use `TAG_PREFIX` or `IMAGE_<VARIANT>` to select existing scan images. The suite
checks runtime/toolchain availability, unprivileged startup, strict runtime
flags, command passthrough, workspace ownership, and brokered Git. A failure
blocks release; selection tests cannot establish that an image is safe.

Check architecture and runtime access manually:

```bash
docker inspect sixways-sandbox:base --format '{{.Architecture}}'
cid=$(docker run -d sixways-sandbox:base)
docker exec -u sandbox -it "$cid" bash
docker rm -f "$cid"
```

## ARM64 and troubleshooting

Specify `--platform` when building manually. The Wolfi SHA-256 pin must refer to
the multi-platform index; a single-platform digest can force emulation or fail on
the other architecture. `scripts/refresh-base-digests.sh` defaults to Wolfi pins
for CLI and microVM images. The deferred Selkies target requires an explicit
`selkies` argument.

Persistent home/cache volumes can contain binaries from an earlier architecture.
Inspect those volumes before deciding whether to remove them. Container logs and
`docker inspect` distinguish wrong-platform images from missing runtime tools:

```bash
docker logs <container-id>
docker inspect <container-id> --format '{{.Platform}}'
docker exec -u sandbox <container-id> id
```

Do not make the strict root filesystem writable to compensate for missing tools.
Refresh the image and rerun the actual image suite instead.
