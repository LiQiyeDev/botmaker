#!/usr/bin/env bash
# Runs INSIDE the test container (launched by run.sh via x11docker).
#
#   entrypoint.sh <mode> <backend>
#     mode    : source | installer | appimage   (default: source)
#     backend : x11 | wayland                    (informational; set by run.sh)
#
# The umbrella repo is bind-shared by x11docker at its host path (run.sh --share),
# so we derive REPO from this script's own location rather than a fixed mount point.
# Maven resolves the local repo from $MAVEN_REPO (a bind-shared host ~/.m2) so
# downloads are cached across runs.
set -euo pipefail

MODE="${1:-source}"
BACKEND="${2:-x11}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   # testing/linux -> repo root
STUDIO="${REPO}/botmaker-studio"

# --- Maven local-repo cache (host ~/.m2 bind-mounted by run.sh) ---------------
MVN_ARGS=()
if [[ -n "${MAVEN_REPO:-}" ]]; then
  MVN_ARGS+=("-Dmaven.repo.local=${MAVEN_REPO}")
fi

# --- Display-server / rendering knobs ----------------------------------------
# Default to the X11 GTK backend even under a Wayland session, so Studio runs as
# an XWayland client and botmaker-shared's X11 window code path stays live.
# Set GDK_BACKEND=wayland on the host (run.sh forwards -e) to observe the native
# Wayland enumeration/capture gap instead.
export GDK_BACKEND="${GDK_BACKEND:-x11}"
# JavaFX/Prism pipeline (run.sh defaults PRISM_ORDER=sw for the nested X server). The
# javafx-maven-plugin and the app-image launcher both fork a JVM; _JAVA_OPTIONS is
# inherited by that fork, so the prism pipeline selection reaches the actual GUI JVM.
if [[ -n "${PRISM_ORDER:-}" ]]; then
  export _JAVA_OPTIONS="${_JAVA_OPTIONS:-} -Dprism.order=${PRISM_ORDER}"
fi

echo "==============================================================="
echo " BotMaker Studio test container"
echo "   mode        : ${MODE}"
echo "   backend     : ${BACKEND}   (GDK_BACKEND=${GDK_BACKEND})"
echo "   DISPLAY     : ${DISPLAY:-<unset>}"
echo "   WAYLAND_DISP: ${WAYLAND_DISPLAY:-<unset>}"
echo "   java        : $(java -version 2>&1 | head -1)"
echo "   uinput      : $( [[ -w /dev/uinput ]] && echo 'writable (UinputBackend testable)' || echo 'absent/read-only' )"
echo "==============================================================="

cd "${REPO}"

# Locate the jpackage app-image launcher ("BotMaker Studio" has a space).
find_launcher() {
  find "${STUDIO}/target/dist" -maxdepth 3 -type f -name 'BotMaker Studio' 2>/dev/null | head -1
}

case "${MODE}" in
  source)
    # Fast path: build shared (-am) + run Studio via the JavaFX plugin.
    exec mvn -q -pl botmaker-studio -am "${MVN_ARGS[@]}" javafx:run
    ;;

  appimage)
    mvn -pl botmaker-studio -am -Pdist package "${MVN_ARGS[@]}"
    LAUNCHER="$(find_launcher)"
    [[ -n "${LAUNCHER}" ]] || { echo "app-image launcher not found under ${STUDIO}/target/dist"; exit 1; }
    echo "Launching app-image: ${LAUNCHER}"
    exec "${LAUNCHER}"
    ;;

  installer)
    # Build the native installer for THIS distro (the -Plinux profile flips the
    # deb/rpm skip flags; jpackage can only emit the host OS's package type).
    mvn -pl botmaker-studio -am -Pdist package "${MVN_ARGS[@]}"
    DIST="${STUDIO}/target/dist"
    DEB="$(find "${DIST}" -maxdepth 1 -name '*.deb' | head -1 || true)"
    RPM="$(find "${DIST}" -maxdepth 1 -name '*.rpm' | head -1 || true)"
    if [[ -n "${DEB}" ]]; then
      echo "Installing ${DEB}"
      sudo apt-get update -qq || true
      sudo apt-get install -y "${DEB}" || sudo dpkg -i "${DEB}"
    elif [[ -n "${RPM}" ]]; then
      echo "Installing ${RPM}"
      sudo dnf install -y "${RPM}"
    else
      echo "No .deb/.rpm produced under ${DIST}"; ls -la "${DIST}" || true; exit 1
    fi
    # jpackage installs to /opt/<name>; launcher keeps the app name with its space.
    INSTALLED="$(find /opt -maxdepth 3 -type f -name 'BotMaker Studio' 2>/dev/null | head -1)"
    [[ -n "${INSTALLED}" ]] || { echo "installed launcher not found under /opt"; exit 1; }
    echo "Launching installed app: ${INSTALLED}"
    exec "${INSTALLED}"
    ;;

  *)
    echo "unknown mode: ${MODE} (want: source | installer | appimage)"; exit 2
    ;;
esac
