# BotMaker Studio test image — Fedora (rpm/dnf family, recent GTK/Wayland stack).
# Toolchain only: the repo is bind-mounted at runtime (see run.sh), so this image is
# reusable across code changes and never needs rebuilding when Studio source changes.
#
# Pinned to fedora:43 (not :latest): Fedora 44 dropped the java-21-openjdk packages
# (defaults to 25/26), and Studio targets Java 21. F43 is the prior stable and still
# ships java-21-openjdk-devel. Bump when Studio moves to a newer JDK.
FROM fedora:43

# - java-21-openjdk-devel: full JDK 21 (javac + jpackage + jdk.jdi) — jpackage bundles
#   THIS runtime into the app-image, and Studio spawns javac/JDI to compile/run/debug bots.
# - GTK3 + X libs: JavaFX GTK backend and shared's XTest input path (libXtst).
# - mesa GL/DRI: Prism hardware pipeline (falls back to software via -Dprism.order=sw).
# - rpm-build: lets jpackage emit a native .rpm on this host.
RUN dnf -y install \
        java-21-openjdk-devel \
        maven \
        gtk3 \
        libXtst libXext libXrender libXi libXxf86vm \
        mesa-libGL mesa-dri-drivers \
        dejavu-sans-fonts dejavu-serif-fonts fontconfig \
        rpm-build \
        sudo \
        which tar gzip xz wget findutils procps-ng \
    && dnf clean all

ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk
ENV PATH="${JAVA_HOME}/bin:${PATH}"

# No USER / ENTRYPOINT here: x11docker creates the container user (matching the host
# user, so bind-shared repo + ~/.m2 stay writable), grants sudo via --sudouser=nopasswd
# for `installer` mode, and run.sh sets --workdir and the command. The image only
# provides the toolchain (JDK, Maven, GTK/X libs, rpm-build, sudo).
