# Project Zomboid dedicated server image for Flux.
#
# The game is NOT in the image. SteamCMD installs it (app 380870, about 5 GB) into the install
# volume on the first start and updates it on every start after; a watcher restarts the server,
# with a warning in game, as soon as Steam ships a build. So a game update never needs a new
# image, and a new image is never rolled out to servers that are already up to date. The BUILD is
# the Steam branch (STEAMAPPBRANCH: public = Build 42, legacy41 = Build 41), not an image tag.
# See README.md.
#
# The scripts are a rewrite for Flux of the ones in danixu86/project-zomboid-dedicated-server
# (GPL-3, see LICENSE and README.md); the environment variables are the same on purpose.
#
# The base. CI builds it pinned to the digest it resolved and records that digest in the
# org.opencontainers.image.base.digest label, which the scheduled check compares against
# (.github/ci/needs-rebuild.sh).
ARG BASE_IMAGE=steamcmd/steamcmd:ubuntu-24
FROM ${BASE_IMAGE}

ARG DEBIAN_FRONTEND=noninteractive
ARG FLUX_IMAGE_VERSION=dev

# util-linux: flock, runuser. locales: the server's language (LANG). python3, NOT
# python3-minimal (no shutil/zipfile). dos2unix is not needed: the config script strips the
# preset's carriage returns itself.
RUN apt-get update -y && \
    apt-get upgrade -y --no-install-recommends && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl procps tzdata python3 util-linux locales && \
    sed -i 's/^# *\(en_US.UTF-8\)/\1/;s/^# *\(es_ES.UTF-8\)/\1/' /etc/locale.gen && locale-gen && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# The game's user. Uid 1000 is the one the image this replaces used, so a data volume that already
# has a world is owned by it. The base image ships `ubuntu` on 1000.
RUN (userdel -r ubuntu 2>/dev/null || true) && \
    useradd -m -u 1000 -s /bin/bash steam && \
    mkdir -p /home/steam/pz-dedicated /home/steam/Zomboid && \
    chown -R steam:steam /home/steam

COPY scripts/flux-lib.sh scripts/flux-entrypoint.sh scripts/flux-restart.sh scripts/flux-updatewatch.sh \
     scripts/flux-scheduler.sh scripts/flux-config.py scripts/flux-steam.py scripts/flux-console.sh scripts/flux-version.sh /opt/flux/
RUN chmod 0755 /opt/flux/*.sh /opt/flux/*.py && \
    ln -s /opt/flux/flux-restart.sh /usr/local/bin/flux-restart && \
    ln -s /opt/flux/flux-console.sh /usr/local/bin/flux-console && \
    ln -s /opt/flux/flux-version.sh /usr/local/bin/flux-version

# SteamCMD's self-update, done once here (as the game's user, which runs it) instead of on every
# container start; the weekly rebuild keeps it current.
ENV HOME=/home/steam
RUN runuser -u steam -- env HOME=/home/steam steamcmd +quit >/dev/null 2>&1; test -d /home/steam/.local/share/Steam

ENV FLUX_IMAGE_VERSION=${FLUX_IMAGE_VERSION} \
    LANG=en_US.UTF-8

WORKDIR /home/steam

# Game 16261/udp and 16262/udp, RCON 27015/tcp (the ports are set by PORT, UDPPORT and RCON_PORT).
EXPOSE 16261/udp 16262/udp 27015/tcp

# A first start downloads the game and builds the world: a long start period, and the check is the
# process, because the server answers no query before it has loaded.
HEALTHCHECK --interval=60s --timeout=10s --start-period=45m --retries=3 \
    CMD pgrep -f '/ProjectZomboid64( |$)' >/dev/null || exit 1

ENTRYPOINT ["/opt/flux/flux-entrypoint.sh"]
