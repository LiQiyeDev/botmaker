#!/usr/bin/env bash
# Launch BotMaker Studio in a nested X11 or Wayland session via x11docker.
#
#   ./run.sh <distro> <x11|wayland> [mode]
#     distro : fedora | ubuntu | debian
#     x11    -> x11docker --xephyr   (nested X server = clean X11 session)
#     wayland-> x11docker --wayland  (nested weston compositor + XWayland)
#     mode   : source | installer | appimage   (default: source)
#
# Optional env:
#   GDK_BACKEND=wayland  under a wayland run, make Studio a NATIVE Wayland client
#                        (default x11 = XWayland, keeps shared's X11 path live)
#   PRISM_ORDER=sw       force JavaFX software rendering (GPU-less / headless hosts)
#   NO_GPU=1             don't pass --gpu to x11docker
#
# x11docker API notes (v7.x): host paths are exposed with --share (mounted at the SAME
# path in the container, /dev devices included), env with --env, internet with --network,
# and the container user is created to match the host user (so shared repo + ~/.m2 stay
# writable). `installer` mode adds --sudouser=nopasswd so the package can be installed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"   # umbrella repo root

DISTRO="${1:?usage: run.sh <fedora|ubuntu|debian> <x11|wayland> [mode]}"
BACKEND="${2:?usage: run.sh <distro> <x11|wayland> [mode]}"
MODE="${3:-source}"
IMAGE="botmaker-test:${DISTRO}"

command -v x11docker >/dev/null || { echo "x11docker not found on PATH"; exit 1; }
docker image inspect "${IMAGE}" >/dev/null 2>&1 || "${HERE}/build-images.sh" "${DISTRO}"

# The nested server runs on the HOST (x11docker provisions it): Xephyr for a nested X11
# screen, weston for a nested Wayland compositor. Preflight so the failure is legible.
case "${BACKEND}" in
  x11)
    XSERVER=(--xephyr)
    command -v Xephyr >/dev/null || {
      echo "Xephyr not installed on host (needed for the x11 backend)."
      echo "  Fedora: sudo dnf install xorg-x11-server-Xephyr"
      echo "  Debian/Ubuntu: sudo apt install xserver-xephyr"
      exit 1; }
    ;;
  wayland)
    XSERVER=(--wayland)
    command -v weston >/dev/null || command -v sway >/dev/null || {
      echo "weston (or sway) not installed on host (needed for the wayland backend)."
      echo "  Fedora: sudo dnf install weston"
      echo "  Debian/Ubuntu: sudo apt install weston"
      exit 1; }
    ;;
  *) echo "backend must be 'x11' or 'wayland' (got: ${BACKEND})"; exit 2 ;;
esac

M2="${HOME}/.m2"; mkdir -p "${M2}/repository"

# x11docker options (before the first '--').
X11DOCKER_ARGS=(
  "${XSERVER[@]}"
  --network                              # Maven / JitPack resolution
  --size=1280x800
)
# GPU is OFF by default: the --xephyr/--wayland nested servers have no hardware GL, and
# passing --gpu makes x11docker silently fall back to the insecure --hostdisplay (which
# then can't open the display). Opt in with USE_GPU=1 only if you know your backend has GL.
[[ "${USE_GPU:-0}" == "1" ]] && X11DOCKER_ARGS+=(--gpu)
# installer mode installs the built .deb/.rpm -> passwordless sudo for the container user.
[[ "${MODE}" == "installer" ]] && X11DOCKER_ARGS+=(--sudouser=nopasswd)

# Raw `docker run` options, passed between the two '--' separators. We bind-mount at
# FIXED paths (/repo, /m2) rather than x11docker --share, which mounts under the
# container user's HOME and gets shadowed. Container user == host user (uid match), so
# both mounts stay writable.
RUN_OPTS=(
  -v "${REPO}:/repo"
  -v "${M2}:/m2"
  -w /repo
  -e "MAVEN_REPO=/m2/repository"
)
# Kernel-level input injection (UinputBackend) — the input path that can survive Wayland.
if [[ -e /dev/uinput ]]; then
  RUN_OPTS+=(--device=/dev/uinput)
else
  echo "note: /dev/uinput absent on host — UinputBackend won't be testable (sudo modprobe uinput)"
fi
# JavaFX/Prism defaults to the software pipeline (nested X servers lack hardware GL).
# Override with PRISM_ORDER=es2 (needs USE_GPU=1 + a GL-capable backend).
RUN_OPTS+=(-e "PRISM_ORDER=${PRISM_ORDER:-sw}")
[[ -n "${GDK_BACKEND:-}" ]] && RUN_OPTS+=(-e "GDK_BACKEND=${GDK_BACKEND}")

echo ">>> ${DISTRO} / ${BACKEND} / ${MODE}"
set -x
exec x11docker \
  "${X11DOCKER_ARGS[@]}" \
  -- \
  "${RUN_OPTS[@]}" \
  -- \
  "${IMAGE}" \
  /repo/testing/linux/entrypoint.sh "${MODE}" "${BACKEND}"
