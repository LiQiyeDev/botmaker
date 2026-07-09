#!/usr/bin/env bash
#
# release.sh — cut a coordinated, dependency-ordered release of the BotMaker submodules.
#
# The library submodules form the chain  shared -> sdk -> studio.  JitPack owns each module's OWN
# version (it serves every git tag as com.github.LiQiyeDev:<repo>:<tag>, ignoring the pom version), so
# this script does NOT touch any module's <version>.  What JitPack does NOT rewrite is a build's
# dependencies, so the one cross-module thing that must be managed is the `botmaker.shared.version`
# property in the sdk/studio poms — this script bumps it to the released shared tag and tags each
# module in order.
#
# botmaker-pilot is the odd one out: it's a CLIENT APP, not a JitPack library and not in the reactor.
# It has no pom pinning and no dependency ordering — tagging it simply triggers its own GitHub Actions
# workflow (release-apk.yml) which builds the Android APK and attaches it to the GitHub Release as
# `botpilot.apk`. Studio's Remote Pilot dialog links the stable `releases/latest/download/botpilot.apk`
# permalink, so cutting a pilot release is how a new APK reaches phones. Released independently below.
#
# Each module flag takes an OPTIONAL argument:
#   * an explicit version   — `--sdk 1.0.7`                (tag exactly that)
#   * a bump level          — `--sdk minor`               (patch|minor|major from its latest tag)
#   * nothing at all        — `--sdk`                      (defaults to a `patch` bump)
# Auto-increment reads the module's own git tags (fetched from origin), strips a leading `v`, takes the
# highest semver, and bumps it. With no existing tag, it bumps from 0.0.0 (so patch->0.0.1 etc.).
#
# Usage:
#   ./release.sh --all                          # patch-bump + release all modules that changed
#   ./release.sh --all minor                    # minor-bump them all
#   ./release.sh --shared --sdk --studio        # the library chain (each patch-bumps)
#   ./release.sh --shared 1.1.0 --sdk 1.0.7 --studio 1.0.7   # explicit versions, any subset
#   ./release.sh --sdk                          # SDK-only patch bump
#   ./release.sh --sdk minor                    # SDK-only minor bump
#   ./release.sh --pilot                         # pilot-only patch bump (tags -> builds + publishes the APK)
#   ./release.sh --pilot 0.2.0                   # pilot at an explicit version
#   ./release.sh --all --dry-run                # print everything (incl. computed versions), change nothing
#
# Notes:
#   * `--all [level]` is shorthand for setting every module (shared/sdk/studio/pilot) to that level
#     (default `patch`); an explicit `--shared/--sdk/--studio/--pilot` still overrides the corresponding
#     one. Unchanged modules are skipped, so `--all` won't cut empty tags.
#   * Change detection: a module whose HEAD is identical to its latest tag is SKIPPED (nothing new to
#     release) — so `--all` won't cut empty tags for modules that haven't changed. A module is still
#     released when it has real changes, when an explicit version is given, or when an upstream module
#     in the same run edits its pom (a shared release re-pins sdk/studio; an sdk release bumps studio's
#     fallback). Tagging is idempotent, so an interrupted release can be re-run safely.
#   * Tags are `v<version>` (matching the existing studio tags; the sdk's bare `1.0.x` tags still work
#     for JitPack, but we standardise on `v` here — JitPack resolves either).
#   * When --shared is part of the release, the script waits for shared's JitPack build to go green
#     before tagging sdk/studio, so their JitPack builds can resolve the new shared.
#   * When both --sdk and --studio are given, studio's MavenService.SDK_FALLBACK_VERSION is bumped to
#     the new sdk version so freshly-generated bots default to it.

set -euo pipefail

OWNER="LiQiyeDev"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# *_SPEC hold the raw request per module ("" = not releasing): an explicit version, or a bump level
# (patch|minor|major). They are resolved to concrete *_VER numbers after tags are fetched.
SHARED_SPEC="" ; SDK_SPEC="" ; STUDIO_SPEC="" ; PILOT_SPEC=""
SHARED_VER="" ; SDK_VER="" ; STUDIO_VER="" ; PILOT_VER=""
DRY_RUN=0

die()  { echo "error: $*" >&2; exit 1; }
info() { echo -e "\033[1;34m==>\033[0m $*"; }

# take_optional <next-arg> — decide whether a module flag consumed a value. Sets globals:
#   OPT_VAL     the value (the next arg, or "patch" when none/another flag follows)
#   OPT_SHIFT   how many positions to shift (2 if a value was consumed, else 1)
take_optional() {
  if [[ -n "${1:-}" && "$1" != -* ]]; then OPT_VAL="$1"; OPT_SHIFT=2
  else OPT_VAL="patch"; OPT_SHIFT=1; fi
}

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
ALL_SPEC=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)    take_optional "${2:-}"; ALL_SPEC="$OPT_VAL";    shift "$OPT_SHIFT" ;;
    --shared) take_optional "${2:-}"; SHARED_SPEC="$OPT_VAL"; shift "$OPT_SHIFT" ;;
    --sdk)    take_optional "${2:-}"; SDK_SPEC="$OPT_VAL";    shift "$OPT_SHIFT" ;;
    --studio) take_optional "${2:-}"; STUDIO_SPEC="$OPT_VAL"; shift "$OPT_SHIFT" ;;
    --pilot)  take_optional "${2:-}"; PILOT_SPEC="$OPT_VAL";  shift "$OPT_SHIFT" ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage 0 ;;
    *) die "unknown arg: $1 (see --help)" ;;
  esac
done

# --all seeds every module that wasn't set explicitly (an explicit flag wins).
if [[ -n "$ALL_SPEC" ]]; then
  [[ -z "$SHARED_SPEC" ]] && SHARED_SPEC="$ALL_SPEC"
  [[ -z "$SDK_SPEC"    ]] && SDK_SPEC="$ALL_SPEC"
  [[ -z "$STUDIO_SPEC" ]] && STUDIO_SPEC="$ALL_SPEC"
  [[ -z "$PILOT_SPEC"  ]] && PILOT_SPEC="$ALL_SPEC"
fi
[[ -n "$SHARED_SPEC$SDK_SPEC$STUDIO_SPEC$PILOT_SPEC" ]] \
  || die "nothing to release (pass --all or --shared/--sdk/--studio/--pilot)"

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

# latest_version <mod> — highest semver among the module's git tags (leading `v` stripped), or "".
# Fetches tags from origin first so auto-increment sees released tags, not just local ones.
latest_version() {
  local dir="$ROOT/$1"
  git -C "$dir" fetch --tags --quiet origin 2>/dev/null || true
  git -C "$dir" tag --list \
    | sed -E 's/^v//' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -V | tail -1
}

# bump <version> <patch|minor|major> — echo the incremented version.
bump() {
  local IFS=. ; read -r ma mi pa <<<"$1"
  case "$2" in
    major) echo "$((ma+1)).0.0" ;;
    minor) echo "$ma.$((mi+1)).0" ;;
    patch) echo "$ma.$mi.$((pa+1))" ;;
    *) die "unknown bump level '$2'" ;;
  esac
}

# resolve_version <mod> <spec> — a literal x.y.z passes through; a bump level is applied to the
# module's latest tag (0.0.0 when it has none).
resolve_version() {
  local mod="$1" spec="$2"
  if [[ "$spec" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "$spec"; return; fi
  case "$spec" in patch|minor|major) ;; *) die "$mod: bad version/level '$spec' (want x.y.z or patch|minor|major)" ;; esac
  local cur; cur="$(latest_version "$mod")"; [[ -z "$cur" ]] && cur="0.0.0"
  bump "$cur" "$spec"
}

# has_changes <mod> — true (0) if the module has something new to release: no prior tag, or its HEAD
# tree differs from its latest release tag. Returns false (1) only when HEAD is byte-identical to the
# latest tag (nothing to release).
has_changes() {
  local dir="$ROOT/$1" last; last="$(latest_version "$1")"
  [[ -z "$last" ]] && return 0                     # never released -> release it
  local t
  for t in "v$last" "$last"; do                    # tags may be v-prefixed or bare
    if git -C "$dir" rev-parse -q --verify "refs/tags/$t^{commit}" >/dev/null 2>&1; then
      git -C "$dir" diff --quiet "$t" HEAD -- && return 1 || return 0
    fi
  done
  return 0
}

# should_release <mod> <spec> <forced> — decide whether to cut a tag. An explicit version or a forced
# release (an upstream module in this run edits this pom) always releases; a bump-level spec releases
# only when has_changes says there is something new.
should_release() {
  local mod="$1" spec="$2" forced="$3"
  [[ "$forced" == "1" ]] && return 0
  [[ "$spec" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && return 0
  has_changes "$mod"
}

# Commit (if there is anything to commit) and tag+push a module.
commit_tag_push() {
  local mod="$1" dir="$ROOT/$1" ver="$2" msg="$3"
  if [[ -n "$msg" ]]; then
    run bash -c "git -C '$dir' diff --quiet || git -C '$dir' commit -am '$msg'"
  fi
  # idempotent: don't fail if the tag already exists (e.g. resuming an interrupted release).
  run bash -c "git -C '$dir' rev-parse -q --verify 'refs/tags/v$ver' >/dev/null || git -C '$dir' tag 'v$ver'"
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
[[ -n "$SHARED_SPEC" ]] && preflight botmaker-shared
[[ -n "$SDK_SPEC"    ]] && preflight botmaker-sdk
[[ -n "$STUDIO_SPEC" ]] && preflight botmaker-studio
[[ -n "$PILOT_SPEC"  ]] && preflight botmaker-pilot

# ---- resolve specs (explicit or bump level) into concrete versions, then show the plan ----
[[ -n "$SHARED_SPEC" ]] && SHARED_VER="$(resolve_version botmaker-shared "$SHARED_SPEC")"
[[ -n "$SDK_SPEC"    ]] && SDK_VER="$(resolve_version botmaker-sdk    "$SDK_SPEC")"
[[ -n "$STUDIO_SPEC" ]] && STUDIO_VER="$(resolve_version botmaker-studio "$STUDIO_SPEC")"
[[ -n "$PILOT_SPEC"  ]] && PILOT_VER="$(resolve_version botmaker-pilot  "$PILOT_SPEC")"
info "Release plan:"
[[ -n "$SHARED_VER" ]] && echo "    shared : $SHARED_SPEC -> v$SHARED_VER"
[[ -n "$SDK_VER"    ]] && echo "    sdk    : $SDK_SPEC -> v$SDK_VER"
[[ -n "$STUDIO_VER" ]] && echo "    studio : $STUDIO_SPEC -> v$STUDIO_VER"
[[ -n "$PILOT_VER"  ]] && echo "    pilot  : $PILOT_SPEC -> v$PILOT_VER  (tags -> APK GitHub Release)"

# A skipped module has its *_VER cleared, so downstream pom-pins and the pointer commit ignore it.

# ---- 1) shared ----
if [[ -n "$SHARED_VER" ]]; then
  if should_release botmaker-shared "$SHARED_SPEC" 0; then
    info "Releasing botmaker-shared v$SHARED_VER"
    commit_tag_push botmaker-shared "$SHARED_VER" ""   # no pom edit — its own version is cosmetic
    wait_for_jitpack botmaker-shared "v$SHARED_VER"
  else
    info "botmaker-shared: no changes since its latest tag — skipping"; SHARED_VER=""
  fi
fi

# ---- 2) sdk ----  (forced when shared released this run: its pom's shared.version must change)
if [[ -n "$SDK_VER" ]]; then
  if should_release botmaker-sdk "$SDK_SPEC" "$([[ -n "$SHARED_VER" ]] && echo 1 || echo 0)"; then
    info "Releasing botmaker-sdk v$SDK_VER"
    # No pom edit: the committed botmaker.shared.version stays 0.0.0-SNAPSHOT; jitpack.yml injects the
    # newest shared tag at build time via -D. A fresh SDK tag is still cut when shared changed so JitPack
    # rebuilds the SDK against the new shared (its build cache is per-tag).
    commit_tag_push botmaker-sdk "$SDK_VER" ""
    wait_for_jitpack botmaker-sdk "v$SDK_VER"
  else
    info "botmaker-sdk: no changes since its latest tag — skipping"; SDK_VER=""
  fi
fi

# ---- 3) studio ----  (forced when shared or sdk released this run: its pom/fallback must change)
if [[ -n "$STUDIO_VER" ]]; then
 if should_release botmaker-studio "$STUDIO_SPEC" "$([[ -n "$SHARED_VER$SDK_VER" ]] && echo 1 || echo 0)"; then
  info "Releasing botmaker-studio v$STUDIO_VER"
  # No shared.version pom edit: studio's pom stays 0.0.0-SNAPSHOT; its release.yml injects the newest shared
  # tag at build time via -D. New bots should still default to the just-released SDK (a .java constant).
  if [[ -n "$SDK_VER" ]]; then
    run_sh "sed -i -E 's#(SDK_FALLBACK_VERSION = \")[^\"]*(\")#\\1${SDK_VER}\\2#' \
      '$ROOT/botmaker-studio/src/main/java/com/botmaker/studio/services/MavenService.java'"
  fi
  commit_tag_push botmaker-studio "$STUDIO_VER" "release: studio v$STUDIO_VER"
 else
  info "botmaker-studio: no changes since its latest tag — skipping"; STUDIO_VER=""
 fi
fi

# ---- 4) pilot ----  (independent: no pom pin, no JitPack; the tag triggers release-apk.yml → APK)
if [[ -n "$PILOT_VER" ]]; then
  if should_release botmaker-pilot "$PILOT_SPEC" 0; then
    info "Releasing botmaker-pilot v$PILOT_VER"
    # No pom/version edit — pilot isn't a Maven artifact. Pushing the tag fires the GitHub Actions
    # release-apk.yml, which builds and attaches botpilot.apk to the v$PILOT_VER GitHub Release.
    commit_tag_push botmaker-pilot "$PILOT_VER" ""
    info "botmaker-pilot v$PILOT_VER tagged — its CI builds + publishes botpilot.apk to the release."
  else
    info "botmaker-pilot: no changes since its latest tag — skipping"; PILOT_VER=""
  fi
fi

# ---- 5) record moved submodule pointers in the umbrella ----
info "Recording submodule pointers in the umbrella"
POINTERS=""
[[ -n "$SHARED_VER" ]] && { run git -C "$ROOT" add botmaker-shared; POINTERS+="shared v$SHARED_VER "; }
[[ -n "$SDK_VER"    ]] && { run git -C "$ROOT" add botmaker-sdk;    POINTERS+="sdk v$SDK_VER ";       }
[[ -n "$STUDIO_VER" ]] && { run git -C "$ROOT" add botmaker-studio; POINTERS+="studio v$STUDIO_VER "; }
[[ -n "$PILOT_VER"  ]] && { run git -C "$ROOT" add botmaker-pilot;  POINTERS+="pilot v$PILOT_VER ";   }
run bash -c "git -C '$ROOT' diff --cached --quiet || git -C '$ROOT' commit -m 'release: ${POINTERS% }'"

info "Done. ${DRY_RUN:+(dry run) }Released: ${POINTERS% }"
