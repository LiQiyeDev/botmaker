# BotMaker Studio test image — Debian stable (conservative library baseline: older
# GTK/glibc than Fedora/Ubuntu, a useful "does it still run on old libs" datapoint).
# Toolchain only: the repo is bind-mounted at runtime (see run.sh).
FROM debian:stable

ENV DEBIAN_FRONTEND=noninteractive

# openjdk-21-jdk is present in Debian 13 (trixie). Same package set as Ubuntu.
RUN apt-get update && apt-get install -y --no-install-recommends \
        openjdk-21-jdk \
        maven \
        libgtk-3-0 \
        libxtst6 libxext6 libxrender1 libxi6 libxxf86vm1 \
        libgl1 libgl1-mesa-dri \
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
