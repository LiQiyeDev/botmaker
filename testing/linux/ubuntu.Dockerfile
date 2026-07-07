# BotMaker Studio test image — Ubuntu 24.04 LTS (deb/apt family).
# Toolchain only: the repo is bind-mounted at runtime (see run.sh).
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# - openjdk-21-jdk: full JDK 21 (javac + jpackage) bundled into the app-image by jpackage.
# - libgtk-3-0 + X libs: JavaFX GTK backend and shared's XTest input (libxtst6).
# - libgl1 + mesa DRI: Prism hardware pipeline (software fallback via -Dprism.order=sw).
# - dpkg-dev + fakeroot + binutils: let jpackage emit a native .deb on this host.
RUN apt-get update && apt-get install -y --no-install-recommends \
        openjdk-21-jdk \
        maven \
        libgtk-3-0 \
        libxtst6 libxext6 libxrender1 libxi6 libxxf86vm1 \
        libgl1 libglx-mesa0 libgl1-mesa-dri \
        fonts-dejavu fontconfig \
        dpkg-dev fakeroot binutils \
        sudo \
        ca-certificates wget xz-utils procps \
    && rm -rf /var/lib/apt/lists/*

ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
ENV PATH="${JAVA_HOME}/bin:${PATH}"

# No USER / ENTRYPOINT here: x11docker creates the container user (matching the host
# user, so bind-shared repo + ~/.m2 stay writable), grants sudo via --sudouser=nopasswd
# for `installer` mode, and run.sh sets --workdir and the command. The image only
# provides the toolchain (JDK, Maven, GTK/X libs, dpkg-dev, sudo).
