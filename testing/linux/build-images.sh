#!/usr/bin/env bash
# Build the three BotMaker Studio Linux test images.
#   ./build-images.sh [distro ...]      (default: fedora ubuntu debian)
# Images are toolchain-only (no repo copied), so you build them once and reuse
# across code changes — run.sh bind-mounts the live repo at run time.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISTROS=("${@:-}")
[[ -z "${DISTROS[*]}" ]] && DISTROS=(fedora ubuntu debian)

for d in "${DISTROS[@]}"; do
  df="${HERE}/${d}.Dockerfile"
  [[ -f "${df}" ]] || { echo "no Dockerfile for '${d}' (${df})"; exit 1; }
  echo ">>> building botmaker-test:${d}"
  docker build -f "${df}" -t "botmaker-test:${d}" "${HERE}"
done

echo "done: ${DISTROS[*]}"
