#!/usr/bin/env bash
# Purpose: build the static musl `sixways-probe` (the runtime policy canary probe client,
#          architecture docs/protocols/runtime-policy-probe.md) that base/Dockerfile bakes into
#          every CLI sandbox image (/usr/local/bin/sixways-probe) and verify it against the
#          committed pins. Every image build path (publish workflow, CI, build.sh) runs this first.
# Usage:   scripts/build-probe.sh [--checkout] [--update] <endpoint-checkout>
#            (default)   the checkout must already be at `source_commit`; build, then fail
#                        unless both binaries match common/probe/SHA256SUMS
#            --checkout  CI only: check the pinned commit out in <endpoint-checkout> first
#                        (fetching it if needed). Never use on a checkout you work in.
#            --update    maintainers: rewrite SHA256SUMS from the build instead of verifying
# Inputs:  common/probe/PROVENANCE (source_commit, rustc), a sixways-endpoint-dev checkout
#          with its ../sibling path deps, and rustup (installs the pinned rustc and the two
#          musl targets). The client is std-only, so rust-lld links it
#          statically and no C toolchain is needed.
# Output:  common/probe/sixways-probe-linux-{amd64,arm64} (gitignored; the Dockerfile
#          re-verifies them against SHA256SUMS). Exit non-zero on any mismatch; the binaries
#          are deleted when they do not match.
# The build remaps the checkout, CARGO_HOME and the rust sysroot so no host path or user name is
# embedded, and pins rustc, so the checksums do not depend on who builds.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${here}/.." && pwd)"
dest="${root}/common/probe"
do_checkout=0
update=0
src=""
for a in "$@"; do
  case "$a" in
    --checkout) do_checkout=1 ;;
    --update) update=1 ;;
    -*) echo "unknown option: $a" >&2; exit 2 ;;
    *) src="$a" ;;
  esac
done
[[ -n "${src}" && -d "${src}/.git" || -f "${src}/.git" ]] || {
  echo "usage: $0 [--checkout] [--update] <sixways-endpoint-dev checkout>" >&2
  exit 2
}
src="$(cd "${src}" && pwd)"

want="$(sed -n 's/^source_commit=//p' "${dest}/PROVENANCE")"
rust="$(sed -n 's/^rustc=//p' "${dest}/PROVENANCE")"
[[ -n "${want}" && -n "${rust}" ]] || { echo "error: PROVENANCE needs source_commit and rustc" >&2; exit 1; }

if [[ "${do_checkout}" == "1" ]]; then
  if ! git -C "${src}" checkout -q --detach "${want}" 2>/dev/null; then
    git -C "${src}" fetch -q origin "${want}" && git -C "${src}" checkout -q --detach "${want}" \
      || { echo "error: cannot check out ${want} in ${src}" >&2; exit 1; }
  fi
fi
have="$(git -C "${src}" rev-parse HEAD)"
if [[ "${have}" != "${want}" ]]; then
  echo "error: ${src} is at ${have}, PROVENANCE pins ${want}" >&2
  exit 1
fi
if [[ -n "$(git -C "${src}" status --porcelain --untracked-files=no)" ]]; then
  echo "error: ${src} has uncommitted changes to tracked files" >&2
  exit 1
fi

export RUSTUP_TOOLCHAIN="${rust}"
rustup toolchain install "${rust}" --profile minimal \
  -t x86_64-unknown-linux-musl -t aarch64-unknown-linux-musl >&2 || exit 1
target_dir="${CARGO_TARGET_DIR:-${src}/target}"
sysroot="$(rustc --print sysroot)"
rustc_hash="$(rustc -vV | sed -n 's/^commit-hash: //p')"

rm -f "${dest}"/sixways-probe-linux-*
build() { # <rust arch> <docker arch>
  local rarch="$1" darch="$2"
  (
    cd "${src}" || exit 1
    RUSTFLAGS="-C linker=rust-lld --remap-path-prefix=${src}=/src --remap-path-prefix=${CARGO_HOME:-${HOME}/.cargo}=/cargo --remap-path-prefix=${sysroot}=/rustc --remap-path-prefix=${sysroot}/lib/rustlib/src/rust=/rustc/${rustc_hash}" \
      CARGO_PROFILE_RELEASE_STRIP=symbols \
      cargo build --release --locked --target "${rarch}-unknown-linux-musl" \
        -p sixways-probe
  ) || { echo "error: build for ${rarch} failed" >&2; exit 1; }
  install -m 0755 "${target_dir}/${rarch}-unknown-linux-musl/release/sixways-probe" \
    "${dest}/sixways-probe-linux-${darch}"
}
build x86_64 amd64 || exit 1
build aarch64 arm64 || exit 1

if [[ "${update}" == "1" ]]; then
  ( cd "${dest}" && shasum -a 256 sixways-probe-linux-amd64 sixways-probe-linux-arm64 ) > "${dest}/SHA256SUMS" || exit 1
  cat "${dest}/SHA256SUMS"
  exit 0
fi
if ( cd "${dest}" && shasum -a 256 -c SHA256SUMS ); then
  echo "ok: build matches the committed SHA256SUMS (source ${want}, rustc ${rust})"
  exit 0
fi
rm -f "${dest}"/sixways-probe-linux-*
echo "error: build does not match common/probe/SHA256SUMS; binaries removed" >&2
exit 1
