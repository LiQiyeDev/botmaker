#!/usr/bin/env bash
#
# release.sh — cut a coordinated, dependency-ordered release of the BotMaker submodules.
#
# The submodules form the chain  shared -> sdk -> studio.  JitPack owns each module's OWN version
# (it serves every git tag as com.github.LiQiyeDev:<repo>:<tag>, ignoring the pom version), so this
# script does NOT touch any module's <version>.  What JitPack does NOT rewrite is a build's
# dependencies, so the one cross-module thing that must be managed is the `botmaker.shared.version`
# property in the sdk/studio poms — this script bumps it to the released shared tag and tags each
# module in order.
#
# Usage:
#   ./release.sh --shared 1.1.0 --sdk 1.0.7 --studio 1.0.7   # any subset of the three
#   ./release.sh --sdk 1.0.7                                 # e.g. an SDK-only release
#   ./release.sh --shared 1.1.0 --dry-run                    # print everything, change nothing
#
# Notes:
#   * Tags are `v<version>` (matching the existing studio tags; the sdk's bare `1.0.x` tags still work
#     for JitPack, but we standardise on `v` here — JitPack resolves either).
#   * When --shared is part of the release, the script waits for shared's JitPack build to go green
#     before tagging sdk/studio, so their JitPack builds can resolve the new shared.
#   * When both --sdk and --studio are given, studio's MavenService.SDK_FALLBACK_VERSION is bumped to
#     the new sdk version so freshly-generated bots default to it.

set -euo pipefail

OWNER="LiQiyeDev"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SHARED_VER="" ; SDK_VER="" ; STUDIO_VER=""
DRY_RUN=0

die()  { echo "error: $*" >&2; exit 1; }
info() { echo -e "\033[1;34m==>\033[0m $*"; }

# run <cmd...> — echo, then execute unless --dry-run.
run() {
  echo "    \$ $*"
  if [[ $DRY_RUN -eq 0 ]]; then "$@"; fi
}
# run_sh "<shell string>" — same, for pipelines / redirects.
run_sh() {
  echo "    \$ $1"
  if [[ $DRY_RUN -eq 0 ]]; then bash -c "$1"; fi
}

usage() {
  grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed '/^!/d'
  exit "${1:-0}"
}

# ---- parse args ----
[[ $# -gt 0 ]] || usage 1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --shared) SHARED_VER="${2:?--shared needs a version}"; shift 2 ;;
    --sdk)    SDK_VER="${2:?--sdk needs a version}";        shift 2 ;;
    --studio) STUDIO_VER="${2:?--studio needs a version}";  shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage 0 ;;
    *) die "unknown arg: $1 (see --help)" ;;
  esac
done
[[ -n "$SHARED_VER$SDK_VER$STUDIO_VER" ]] || die "nothing to release (pass --shared/--sdk/--studio)"

[[ -f "$ROOT/pom.xml" ]] && grep -q '<artifactId>BotMaker</artifactId>' "$ROOT/pom.xml" \
  || die "must be run from the botmaker umbrella root"

[[ $DRY_RUN -eq 1 ]] && info "DRY RUN — no changes will be made."

# ---- helpers ----

# Abort unless the submodule's working tree is clean and it's on a branch (not detached).
preflight() {
  local mod="$1" dir="$ROOT/$1"
  [[ -d "$dir/.git" || -f "$dir/.git" ]] || die "$mod: not a git submodule checkout"
  if [[ -n "$(git -C "$dir" status --porcelain)" ]]; then
    [[ $DRY_RUN -eq 1 ]] && info "$mod: working tree not clean (ok in dry-run)" \
      || die "$mod: working tree not clean — commit/stash first"
  fi
  local branch; branch="$(git -C "$dir" symbolic-ref --quiet --short HEAD || true)"
  if [[ -z "$branch" ]]; then
    [[ $DRY_RUN -eq 1 ]] && info "$mod: detached HEAD (ok in dry-run)" \
      || die "$mod: detached HEAD — 'git -C $mod checkout main' first"
  fi
}

# Rewrite <botmaker.shared.version>…</…> in a module's pom.
set_shared_property() {
  local dir="$ROOT/$1" ver="$2"
  run_sh "sed -i -E 's#(<botmaker\\.shared\\.version>)[^<]*(</botmaker\\.shared\\.version>)#\\1${ver}\\2#' '$dir/pom.xml'"
}

# Commit (if there is anything to commit) and tag+push a module.
commit_tag_push() {
  local mod="$1" dir="$ROOT/$1" ver="$2" msg="$3"
  if [[ -n "$msg" ]]; then
    run bash -c "git -C '$dir' diff --quiet || git -C '$dir' commit -am '$msg'"
  fi
  run git -C "$dir" tag "v$ver"
  run git -C "$dir" push origin HEAD
  run git -C "$dir" push origin "v$ver"
}

# Poll JitPack until it has built <repo>:<tag> (its pom is downloadable), or time out.
wait_for_jitpack() {
  local repo="$1" tag="$2"
  local url="https://jitpack.io/com/github/$OWNER/$repo/$tag/$repo-$tag.pom"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "    (dry-run) would poll $url until built"
    return 0
  fi
  info "waiting for JitPack to build $repo:$tag ..."
  run_sh "curl -sf 'https://jitpack.io/api/builds/com.github.$OWNER/$repo/$tag' >/dev/null || true"
  for _ in $(seq 1 60); do   # ~10 min at 10s
    if curl -sfI "$url" >/dev/null 2>&1; then
      info "JitPack build of $repo:$tag is ready."
      return 0
    fi
    sleep 10
  done
  die "$repo:$tag not built on JitPack after 10 min — check https://jitpack.io/#$OWNER/$repo"
}

# ---- preflight all targeted modules up front ----
[[ -n "$SHARED_VER" ]] && preflight botmaker-shared
[[ -n "$SDK_VER"    ]] && preflight botmaker-sdk
[[ -n "$STUDIO_VER" ]] && preflight botmaker-studio

# ---- 1) shared ----
if [[ -n "$SHARED_VER" ]]; then
  info "Releasing botmaker-shared v$SHARED_VER"
  commit_tag_push botmaker-shared "$SHARED_VER" ""     # no pom edit — its own version is cosmetic
  wait_for_jitpack botmaker-shared "v$SHARED_VER"
fi

# ---- 2) sdk ----
if [[ -n "$SDK_VER" ]]; then
  info "Releasing botmaker-sdk v$SDK_VER"
  [[ -n "$SHARED_VER" ]] && set_shared_property botmaker-sdk "v$SHARED_VER"
  commit_tag_push botmaker-sdk "$SDK_VER" \
    "$([[ -n "$SHARED_VER" ]] && echo "chore: bump botmaker.shared.version -> v$SHARED_VER")"
  wait_for_jitpack botmaker-sdk "v$SDK_VER"
fi

# ---- 3) studio ----
if [[ -n "$STUDIO_VER" ]]; then
  info "Releasing botmaker-studio v$STUDIO_VER"
  [[ -n "$SHARED_VER" ]] && set_shared_property botmaker-studio "v$SHARED_VER"
  # New bots should default to the just-released SDK.
  if [[ -n "$SDK_VER" ]]; then
    run_sh "sed -i -E 's#(SDK_FALLBACK_VERSION = \")[^\"]*(\")#\\1${SDK_VER}\\2#' \
      '$ROOT/botmaker-studio/src/main/java/com/botmaker/studio/services/MavenService.java'"
  fi
  commit_tag_push botmaker-studio "$STUDIO_VER" "release: studio v$STUDIO_VER"
fi

# ---- 4) record moved submodule pointers in the umbrella ----
info "Recording submodule pointers in the umbrella"
POINTERS=""
[[ -n "$SHARED_VER" ]] && { run git -C "$ROOT" add botmaker-shared; POINTERS+="shared v$SHARED_VER "; }
[[ -n "$SDK_VER"    ]] && { run git -C "$ROOT" add botmaker-sdk;    POINTERS+="sdk v$SDK_VER ";       }
[[ -n "$STUDIO_VER" ]] && { run git -C "$ROOT" add botmaker-studio; POINTERS+="studio v$STUDIO_VER "; }
run bash -c "git -C '$ROOT' diff --cached --quiet || git -C '$ROOT' commit -m 'release: ${POINTERS% }'"

info "Done. ${DRY_RUN:+(dry run) }Released: ${POINTERS% }"
