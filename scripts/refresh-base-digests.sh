#!/usr/bin/env bash
set -uo pipefail

# ---------------------------------------------------------------------------
# Refresh pinned base-image digests.
#
# The variant Dockerfiles pull the latest Wolfi *apk packages* at build time
# (`apk upgrade`/`apk add --no-cache` fetch a fresh index), so a plain rebuild
# already applies package-level CVE fixes. A rebuild does not update the pinned
# base image used by the image chain:
#
#   base/Dockerfile, microvm/base/Dockerfile : cgr.dev/chainguard/wolfi-base@<digest>
#   desktop/Dockerfile                       : SELKIES_DIGEST=<digest>
#
# The pins make builds reproducible and change only when this script updates
# them. The script resolves each upstream `:latest` reference and writes the new
# digest. Run the sanity suite before publishing an image with updated pins.
#
# Usage:
#   scripts/refresh-base-digests.sh              # report CLI/microVM Wolfi pin (no writes)
#   scripts/refresh-base-digests.sh --check      # report; exit 3 if any pin is stale
#   scripts/refresh-base-digests.sh --write      # rewrite stale pins in place
#   scripts/refresh-base-digests.sh --write wolfi # limit to a target (wolfi|selkies)
#
# Exit codes: 0 ok / up to date (or --write done), 2 resolve error,
#             3 stale pin found (--check only).
#
# Resolver: `docker buildx imagetools inspect`, falling back to crane, then
# oras. One of these is present on every build host and CI runner we use.
# ---------------------------------------------------------------------------

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "error: not inside a git repository" >&2; exit 2; }
cd "$REPO_ROOT" || exit 2

# --- Targets: name | upstream :latest ref | files (space-sep) | sed-anchor ---
# The sed-anchor is the literal text before `sha256:...` in the file. It limits
# the replacement to the intended digest.
TARGETS=(
  "wolfi|cgr.dev/chainguard/wolfi-base:latest|base/Dockerfile microvm/base/Dockerfile|wolfi-base@"
  "selkies|ghcr.io/selkies-project/selkies-gstreamer/gst-py-example:latest|desktop/Dockerfile|SELKIES_DIGEST="
)

MODE="report"          # report | check | write
WANT_TARGETS=()

for arg in "$@"; do
  case "$arg" in
    --check) MODE="check" ;;
    --write) MODE="write" ;;
    --report) MODE="report" ;;
    wolfi|selkies) WANT_TARGETS+=("$arg") ;;
    -h|--help) sed -n '5,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# Deferred desktop refresh is available only via an explicit selkies target.
[ "${#WANT_TARGETS[@]}" -eq 0 ] && WANT_TARGETS=(wolfi)

if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'
else RED=''; GREEN=''; YELLOW=''; BOLD=''; RESET=''; fi

# --- Resolve a registry ref to its (index) digest ---------------------------
resolve_digest() {
  local ref="$1" d=""
  if command -v docker >/dev/null 2>&1; then
    d="$(docker buildx imagetools inspect "$ref" --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
  fi
  if [ -z "$d" ] && command -v crane >/dev/null 2>&1; then
    d="$(crane digest "$ref" 2>/dev/null || true)"
  fi
  if [ -z "$d" ] && command -v oras >/dev/null 2>&1; then
    d="$(oras manifest fetch --descriptor "$ref" 2>/dev/null | jq -r '.digest' 2>/dev/null || true)"
  fi
  # Validate the digest before using it in a replacement.
  if [[ "$d" =~ ^sha256:[0-9a-f]{64}$ ]]; then echo "$d"; return 0; fi
  return 1
}

# Portable in-place replace (BSD & GNU sed differ only on -i; pipe to a temp).
replace_in_file() {
  local file="$1" anchor="$2" new="$3" tmp
  tmp="$(mktemp)"
  # Anchor is a literal prefix; match its trailing sha256:<64hex>.
  sed -E "s#(${anchor})sha256:[0-9a-f]{64}#\\1${new}#g" "$file" > "$tmp" && mv "$tmp" "$file"
}

want() {
  [ "${#WANT_TARGETS[@]}" -eq 0 ] && return 0
  local t="$1" w
  for w in "${WANT_TARGETS[@]}"; do [ "$w" = "$t" ] && return 0; done
  return 1
}

printf "${BOLD}Base-image freshness pass${RESET}  (mode: %s)\n" "$MODE"

STALE=0
CHANGED=0
RESOLVE_ERR=0

for record in "${TARGETS[@]}"; do
  IFS='|' read -r name upstream files anchor <<< "$record"
  want "$name" || continue

  printf "\n${BOLD}%s${RESET}  <- %s\n" "$name" "$upstream"

  # Current pinned digest (read from the first file; all files for a target
  # share the same pin by construction).
  local_first="${files%% *}"
  current="$(grep -oE "${anchor}sha256:[0-9a-f]{64}" "$local_first" 2>/dev/null | head -1 | sed -E "s#^${anchor}##")"
  if [ -z "$current" ]; then
    printf "  ${RED}error:${RESET} no pin matching '%s' in %s\n" "$anchor" "$local_first" >&2
    RESOLVE_ERR=1; continue
  fi

  latest="$(resolve_digest "$upstream")" || {
    printf "  ${RED}error:${RESET} could not resolve %s (offline? no buildx/crane/oras?)\n" "$upstream" >&2
    RESOLVE_ERR=1; continue
  }

  printf "  current: %s\n" "$current"
  printf "  latest:  %s\n" "$latest"

  if [ "$current" = "$latest" ]; then
    printf "  ${GREEN}up to date${RESET}\n"
    continue
  fi

  STALE=1
  printf "  ${YELLOW}STALE${RESET} — pin is behind upstream :latest\n"
  for f in $files; do
    printf "    affects: %s\n" "$f"
  done

  if [ "$MODE" = write ]; then
    for f in $files; do
      replace_in_file "$f" "$anchor" "$latest"
    done
    CHANGED=1
    printf "  ${GREEN}rewrote${RESET} %s -> %s\n" "$name" "$latest"
  fi
done

echo ""
if [ "$RESOLVE_ERR" -ne 0 ]; then
  printf "${RED}${BOLD}Resolve/read errors above — nothing safe to trust; aborting.${RESET}\n" >&2
  exit 2
fi

case "$MODE" in
  write)
    if [ "$CHANGED" -ne 0 ]; then
      printf "${GREEN}${BOLD}Pins updated.${RESET} Rebuild + run tests/test-sandbox-images.sh before publishing.\n"
      printf "Changed files:\n"; git diff --name-only
    else
      printf "${GREEN}${BOLD}All pins already current — no changes.${RESET}\n"
    fi
    exit 0 ;;
  check)
    if [ "$STALE" -ne 0 ]; then
      printf "${YELLOW}${BOLD}Stale pin(s) found.${RESET} Run: scripts/refresh-base-digests.sh --write\n"
      exit 3
    fi
    printf "${GREEN}${BOLD}All base pins are current.${RESET}\n"; exit 0 ;;
  *)
    if [ "$STALE" -ne 0 ]; then
      printf "${YELLOW}${BOLD}Stale pin(s) found.${RESET} Run with --write to update.\n"
    else
      printf "${GREEN}${BOLD}All base pins are current.${RESET}\n"
    fi
    exit 0 ;;
esac
