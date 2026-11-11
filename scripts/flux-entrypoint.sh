#!/bin/bash
# PID 1, and the supervisor of the Project Zomboid server.
#
# The game is NOT in the image. SteamCMD installs it into the install volume on the first start
# and updates it on every start after, so a new Project Zomboid build reaches a server by
# restarting it, never by rebuilding this image. And the BUILD is the Steam branch, not an image
# tag: STEAMAPPBRANCH=public is Build 42, legacy41 is Build 41, unstable is the next Build 42.
# One image serves all of them.
#
# The game runs as a CHILD, never exec, so a stop reaches us first, and a server that ends on its
# own is followed by the next one in place:
#
#   - every start: SteamCMD update, the ini and sandbox file from the environment
#     (flux-config.py), then the server as the `steam` user
#   - SIGTERM/SIGINT from Docker: `quit` on the server's console, which saves the world and exits
#   - a planned restart (flux-updatewatch.sh on a new build, flux-scheduler.sh at
#     FLUX_RESTART_TIME): players warned in game, the world saved, a new generation, updated first
#   - the server ending on its own: a new generation in the same container, updated first
#   - FLUX_RESTART_MAX_ATTEMPTS unplanned restarts inside FLUX_RESTART_WINDOW seconds: the
#     container ends with 42, a server that cannot stay up is the platform's to rebuild or move
#
# The environment is the one runonflux's marketplace app already passes the image this replaces
# (SERVERNAME, DISPLAYNAME, SERVERPRESET, ADMINUSERNAME, ADMINPASSWORD, PASSWORD, RCONPASSWORD,
# PUBLIC, MEMORY, PORT, UDPPORT, STEAMVAC, SELF_MANAGED_MODS, ...), so a server changes image with
# its spec otherwise as it is. Same family as runonflux/rust-server-flux.

set -uo pipefail
# shellcheck source=scripts/flux-lib.sh
source /opt/flux/flux-lib.sh

FLUX_RESTART_MAX_ATTEMPTS="${FLUX_RESTART_MAX_ATTEMPTS:-5}"
FLUX_RESTART_WINDOW="${FLUX_RESTART_WINDOW:-3600}"
FLUX_RESTART_BACKOFF="${FLUX_RESTART_BACKOFF:-10}"
# How long a planned restart waits for the game to save and quit before it is killed. A docker
# stop is not bound by this: Docker kills on its own clock.
FLUX_STOP_GRACE="${FLUX_STOP_GRACE:-180}"

s="${FLUX_SERVER_DIR}"
d="${FLUX_DATA_DIR}"
export HOME="${FLUX_HOME}"

mkdir -p "${s}" "${d}" "${FLUX_RUN_DIR}"
rm -f "${FLUX_RESTART_MARKER}" "${FLUX_STARTED_AT}"

# A mount comes up root-owned, and a restore or an upload leaves root-owned files in the data
# (see ark-world-restore: a root-owned database is "corrupt" to the game). Fixed before anything
# reads them, and only when something is wrong: the walk is cheap, the chown of a big world is not.
fix_owner() {
  [ -e "$1" ] || return 0
  if [ -n "$(find "$1" -not -user "${FLUX_STEAM_USER}" -print -quit 2>/dev/null)" ]; then
    flux_log "fixing the owner of $1"
    chown -R "${FLUX_STEAM_USER}:${FLUX_STEAM_USER}" "$1"
  fi
}
fix_owner "${s}"
fix_owner "${d}"
chmod 755 "${d}"
mkdir -p "${FLUX_STATE_DIR}" "${FLUX_LOG_DIR}"
chown "${FLUX_STEAM_USER}:${FLUX_STEAM_USER}" "${FLUX_STATE_DIR}" "${FLUX_LOG_DIR}"
flux_banner

# SteamCMD's depotcache onto the install volume. It holds the manifests of the installed build,
# which the NEXT update needs and which Steam refuses to an anonymous login once a build is old.
# In the container's own layer they would be lost on every redeploy, and the update after it
# would have to download the whole game again (see update_server).
steam_home="${FLUX_HOME}/.local/share/Steam"
flux_as_steam mkdir -p "${FLUX_STATE_DIR}/depotcache" "${steam_home}"
if [ ! -L "${steam_home}/depotcache" ]; then
  flux_as_steam rm -rf "${steam_home}/depotcache"
  flux_as_steam ln -s "${FLUX_STATE_DIR}/depotcache" "${steam_home}/depotcache"
fi

# STEAMAPPBRANCH is the name the image this replaces used (and a spec may still carry);
# STEAM_BRANCH is the name the rest of our images use. With neither, the image's own default: the
# :b42 tag installs `public`, the :b41 tag `legacy41`.
wanted_branch="${STEAMAPPBRANCH:-${STEAM_BRANCH:-${FLUX_DEFAULT_BRANCH:-}}}"
if ! branch="$(flux_steam_branch "${wanted_branch}")"; then
  flux_log "ERROR the Steam branch '${wanted_branch}' is not a branch name; refusing to start"
  exit 42
fi
export FLUX_BRANCH="${branch}"
# Which build's mod folders the map scan reads: the legacy41 branch is Build 41, anything else 42.
case "${branch}" in
  legacy41* | 41* | b41*) export FLUX_BUILD=41 ;;
  *) export FLUX_BUILD=42 ;;
esac
flux_log "flux-entrypoint starting (image ${FLUX_IMAGE_VERSION:-dev}, Steam branch ${branch}, Build ${FLUX_BUILD})"

# The console: a FIFO the supervisor keeps open for the life of the container. The server reads
# its stdin from it (and would read end-of-file the moment nobody held it open), and everything
# that talks to the server (the stop, the restart warnings) writes a line to it.
rm -f "${FLUX_CONSOLE}"
mkfifo "${FLUX_CONSOLE}"
chown "${FLUX_STEAM_USER}" "${FLUX_CONSOLE}"
exec {console_fd}<>"${FLUX_CONSOLE}"

game_pid=""
terminating=0
generation=0
restart_history=()

# `quit` saves the world and exits; it is the only thing that does. A SIGTERM to the launcher
# ends the process with the world as it was at the last chunk unload.
# shellcheck disable=SC2329  # invoked by the trap below
term_handler() {
  terminating=1
  flux_log "stop requested ($1): saving the world and quitting; no restart will follow"
  [ -n "${game_pid}" ] || return 0
  printf 'quit\n' >&"${console_fd}"
}
trap 'term_handler TERM' TERM
trap 'term_handler INT' INT

disk_note() {
  local line
  line="$(df -Pm "${s}" 2>/dev/null | awk 'NR==2 {printf "%s MB free of %s MB", $4, $2}')"
  [ -n "${line}" ] && flux_log "install volume: ${line}"
}

update_server() {
  local attempt installed before beta=()
  installed=0
  [ -x "${s}/${FLUX_GAME_BINARY}" ] && installed=1
  if flux_truthy "${SKIP_UPDATE:-}" && [ "${installed}" = "1" ]; then
    flux_log "SKIP_UPDATE is set: not updating the server files"
    return 0
  fi
  [ "${FLUX_BRANCH}" != "public" ] && beta=(-beta "${FLUX_BRANCH}")
  before="$(flux_acf_buildid "${s}/steamapps/appmanifest_${FLUX_STEAM_APP}.acf")"
  if [ "${installed}" = "1" ]; then
    flux_log "updating the server from Steam (app ${FLUX_STEAM_APP}, branch ${FLUX_BRANCH}, installed build ${before:-unknown})"
  else
    flux_log "installing the server from Steam (app ${FLUX_STEAM_APP}, branch ${FLUX_BRANCH}, about 5 GB the first time)"
  fi
  disk_note
  # 1: a plain update. No `validate`: it re-hashes the whole install.
  # 2: with validate, for an install that is damaged.
  # 3: only when Steam answered "state is 0x6": over the top, as a new install. An update from
  #    build A to B needs A's depot manifests; SteamCMD keeps them in its depotcache (kept on this
  #    volume, see the top), and when they are gone Steam will NOT hand an old manifest to an
  #    anonymous login ("Failed to get manifest request code, 'Access Denied'"), so nothing short
  #    of a fresh install gets past it. Never for a network failure, which a re-download cannot fix.
  # Then the build already installed is started anyway: a server on the old build is still better
  # than none, and the update watch tries again later.
  local ok=0 validate out="${FLUX_RUN_DIR}/steamcmd.out"
  for attempt in 1 2 3; do
    validate=""
    case "${attempt}" in
      2) validate="validate" ;;
      3)
        grep -q "state is 0x6" "${out}" 2>/dev/null || break
        flux_log "updating as a new install: Steam no longer serves the installed build's manifests"
        rm -rf "${s}/steamapps/appmanifest_${FLUX_STEAM_APP}.acf" "${s}/steamapps/downloading" "${s}/steamapps/temp"
        ;;
    esac
    # shellcheck disable=SC2086  # validate is "" or "validate"
    flux_as_steam steamcmd +force_install_dir "${s}" +login anonymous +app_update "${FLUX_STEAM_APP}" "${beta[@]}" ${validate} +quit \
      2>&1 | tee "${out}"
    if [ "${PIPESTATUS[0]}" = "0" ] && [ -x "${s}/${FLUX_GAME_BINARY}" ]; then
      ok=1
      break
    fi
    [ "${terminating}" = "1" ] && return 1
    flux_log "WARN steamcmd failed (attempt ${attempt})"
    disk_note
    sleep 5
  done
  # A pinned branch Steam has since removed ("Failed to set beta"), on a node with nothing installed
  # (a new node after a failover): install the build's default branch instead of looping on the
  # refusal. The pin is still in the spec, so an installed server keeps starting its own build.
  if [ ! -x "${s}/${FLUX_GAME_BINARY}" ] && [ "${FLUX_BRANCH}" != "${FLUX_DEFAULT_BRANCH:-public}" ] \
    && grep -q "Failed to set beta" "${out}" 2>/dev/null; then
    flux_log "WARN Steam has no branch '${FLUX_BRANCH}' any more; installing '${FLUX_DEFAULT_BRANCH:-public}' instead"
    FLUX_BRANCH="${FLUX_DEFAULT_BRANCH:-public}"
    beta=()
    [ "${FLUX_BRANCH}" != "public" ] && beta=(-beta "${FLUX_BRANCH}")
    for attempt in 1 2; do
      validate=""
      [ "${attempt}" = "2" ] && validate="validate"
      # shellcheck disable=SC2086  # validate is "" or "validate"
      flux_as_steam steamcmd +force_install_dir "${s}" +login anonymous +app_update "${FLUX_STEAM_APP}" "${beta[@]}" ${validate} +quit \
        2>&1 | tee "${out}"
      [ "${PIPESTATUS[0]}" = "0" ] && [ -x "${s}/${FLUX_GAME_BINARY}" ] && { ok=1; break; }
      sleep 5
    done
  fi
  if [ ! -x "${s}/${FLUX_GAME_BINARY}" ]; then
    flux_log "ERROR could not install the server from Steam"
    return 1
  fi
  local after
  after="$(flux_acf_buildid "${s}/steamapps/appmanifest_${FLUX_STEAM_APP}.acf")"
  if [ "${ok}" = "0" ]; then
    flux_log "WARN could not update from Steam; starting the build already installed (${after:-unknown})"
  else
    flux_log "Project Zomboid build ${after:-unknown} (${FLUX_BRANCH}) installed"
  fi
  return 0
}

# The ini and the sandbox file from the environment, and the maps the Workshop mods ship.
prepare_config() {
  local line
  while IFS= read -r line; do
    flux_log "config: ${line}"
  done < <(flux_as_steam env FLUX_SERVER_DIR="${s}" FLUX_DATA_DIR="${d}" FLUX_BUILD="${FLUX_BUILD}" \
    python3 /opt/flux/flux-config.py prepare 2>&1)
  # The Steam client library the game's own Workshop downloads use, refreshed on request.
  if flux_truthy "${FORCESTEAMCLIENTSOUPDATE:-}"; then
    flux_log "FORCESTEAMCLIENTSOUPDATE is set: updating steamclient.so in the server"
    flux_as_steam cp "${steam_home}/steamcmd/linux64/steamclient.so" "${s}/linux64/steamclient.so" 2>/dev/null
    flux_as_steam cp "${steam_home}/steamcmd/linux32/steamclient.so" "${s}/steamclient.so" 2>/dev/null
  fi
  return 0
}

# Sets GAME_ARGS: the JVM arguments, `--`, then the game's, in the image's own order.
build_args() {
  local heap
  GAME_ARGS=()
  if [ -n "${MIN_MEMORY:-}" ] && [ -n "${MAX_MEMORY:-}" ]; then
    GAME_ARGS+=("-Xms${MIN_MEMORY}" "-Xmx${MAX_MEMORY}")
  elif [ -n "${MEMORY:-}" ]; then
    GAME_ARGS+=("-Xms${MEMORY}" "-Xmx${MEMORY}")
  else
    heap="$(flux_default_heap "$(flux_memory_limit_mb)")"
    if [ -n "${heap}" ]; then
      flux_log "no MEMORY set: the Java heap is ${heap}, 75% of the container's memory"
      GAME_ARGS+=("-Xms${heap}" "-Xmx${heap}")
    fi
  fi
  flux_truthy "${SOFTRESET:-}" && GAME_ARGS+=("-Dsoftreset")
  GAME_ARGS+=("--")
  flux_truthy "${COOP:-}" && GAME_ARGS+=("-coop")
  flux_truthy "${NOSTEAM:-}" && GAME_ARGS+=("-nosteam")
  [ -n "${CACHEDIR:-}" ] && GAME_ARGS+=("-cachedir=${CACHEDIR}")
  [ -n "${MODFOLDERS:-}" ] && GAME_ARGS+=("-modfolders" "${MODFOLDERS}")
  flux_truthy "${DEBUG:-}" && GAME_ARGS+=("-debug")
  [ -n "${ADMINUSERNAME:-}" ] && GAME_ARGS+=("-adminusername" "${ADMINUSERNAME}")
  [ -n "${ADMINPASSWORD:-}" ] && GAME_ARGS+=("-adminpassword" "${ADMINPASSWORD}")
  GAME_ARGS+=("-servername" "${SERVERNAME:-servertest}")
  [ -n "${IP:-}" ] && GAME_ARGS+=("${IP}" "-ip" "${IP}")
  [ -n "${PORT:-}" ] && GAME_ARGS+=("-port" "${PORT}")
  case "${STEAMVAC:-}" in
    [Tt][Rr][Uu][Ee]) GAME_ARGS+=("-steamvac" "true") ;;
    [Ff][Aa][Ll][Ss][Ee]) GAME_ARGS+=("-steamvac" "false") ;;
  esac
  [ -n "${STEAMPORT1:-}" ] && GAME_ARGS+=("-steamport1" "${STEAMPORT1}")
  [ -n "${STEAMPORT2:-}" ] && GAME_ARGS+=("-steamport2" "${STEAMPORT2}")
  return 0
}

start_generation() {
  generation=$((generation + 1))
  rm -f "${FLUX_RESTART_MARKER}" "${FLUX_STARTED_AT}"
  update_server || return 1
  [ "${terminating}" = "1" ] && return 2
  prepare_config
  build_args
  disk_note
  flux_log "starting the server (generation ${generation})"
  date -u +%s >"${FLUX_STARTED_AT}"
  (
    cd "${s}" || exit 1
    # libjsig is in the game's own jre64; without its folder on the path the launcher logs an
    # error for the preload and goes on without it.
    export LD_LIBRARY_PATH="${s}/jre64/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
    export LANG="${LANG:-en_US.UTF-8}"
    # Opened here, as root, so the server inherits an open descriptor and the FIFO's owner is
    # irrelevant. `runuser -u` execs the command itself: every argument arrives as one argument.
    exec runuser -u "${FLUX_STEAM_USER}" -- env "HOME=${FLUX_HOME}" ./start-server.sh "${GAME_ARGS[@]}" <"${FLUX_CONSOLE}"
  ) &
  game_pid=$!
  # The game's own version, for the dashboard (flux-version): it is in the server log, once the
  # game has started far enough to print it.
  (
    for _ in $(seq 1 90); do
      v="$(flux_logged_version "${d}/Logs" "${FLUX_STARTED_AT}")"
      if [ -n "${v}" ]; then
        printf '%s' "${v}" >"${FLUX_STATE_DIR}/version"
        flux_log "game version ${v}"
        exit 0
      fi
      sleep 2
    done
  ) &
  return 0
}

# Waits for the game to end. A planned restart that is not honoured within FLUX_STOP_GRACE ends it
# by force; the grace runs from when the request was first seen. Sets game_rc.
wait_for_generation() {
  local asked_at=0 now pid step
  clean_stop=0
  while kill -0 "${game_pid}" 2>/dev/null; do
    # Fast while a stop is under way, because the end of it is a race with Docker's ten seconds.
    step=1
    { [ "${terminating}" = "1" ] || [ -f "${FLUX_RESTART_MARKER}" ]; } && step=0.2
    sleep "${step}" &
    wait $!
    # Everything is on disk and the server is only waiting for its network thread (see
    # flux_shutdown_reached): end it here, so a stop fits inside Docker's ten seconds.
    if flux_shutdown_reached "${d}/Logs" "${FLUX_STARTED_AT}"; then
      pid="$(flux_game_pid)"
      [ -n "${pid}" ] && kill -KILL "${pid}" 2>/dev/null
      kill -KILL "${game_pid}" 2>/dev/null
      clean_stop=1
      break
    fi
    if [ "${terminating}" != "1" ] && [ -f "${FLUX_RESTART_MARKER}" ]; then
      now="$(date -u +%s)"
      [ "${asked_at}" = "0" ] && asked_at="${now}"
      if [ $((now - asked_at)) -ge "${FLUX_STOP_GRACE}" ]; then
        flux_log "WARN the server was asked to stop ${FLUX_STOP_GRACE}s ago and has not; ending it"
        pid="$(flux_game_pid)"
        [ -n "${pid}" ] && kill -KILL "${pid}" 2>/dev/null
        kill -KILL "${game_pid}" 2>/dev/null
        break
      fi
    fi
  done
  # `wait` returns early when a trap fires, so ask again until the child is gone.
  while true; do
    wait "${game_pid}" 2>/dev/null
    game_rc=$?
    kill -0 "${game_pid}" 2>/dev/null || break
  done
  game_pid=""
  local left
  left="$(flux_kill_leftover_games)"
  [ -n "${left}" ] && flux_log "WARN ${left} game process(es) outlived the server; ended them"
}

/opt/flux/flux-updatewatch.sh &
/opt/flux/flux-scheduler.sh &

while true; do
  if [ "${terminating}" = "1" ]; then
    flux_log "stopped on request before the server started"
    exit 0
  fi
  start_generation
  started=$?
  if [ "${started}" = "2" ]; then
    flux_log "stopped on request before the server started"
    exit 0
  elif [ "${started}" != "0" ]; then
    flux_log "ERROR the server could not be prepared; ending the container (42)"
    exit 42
  fi
  wait_for_generation
  rc="${game_rc}"
  # start-server.sh ends with `exit 0` whatever the game did (a SIGKILL, a JVM crash), so the exit
  # status alone cannot tell a quit from a crash. The game's log can: a server that was told to
  # quit says so (flux_shutdown_reached), a crashed one does not.
  graceful=0
  if [ "${clean_stop}" = "1" ] || { [ "${rc}" = "0" ] && flux_shutdown_reached "${d}/Logs" "${FLUX_STARTED_AT}"; }; then
    graceful=1
  fi
  rm -f "${FLUX_STARTED_AT}"

  reason=""
  [ -f "${FLUX_RESTART_MARKER}" ] && reason="$(cat "${FLUX_RESTART_MARKER}" 2>/dev/null)"
  rm -f "${FLUX_RESTART_MARKER}"

  if [ "${terminating}" = "1" ]; then
    flux_log "stopped on request (server exited ${rc}$([ "${clean_stop}" = "1" ] && echo ", ended after saving"))"
    exit 0
  fi

  # The server ends with 0 when it was told to quit (an admin's `quit` over RCON, or the
  # console's): that is a restart someone asked for.
  if [ -z "${reason}" ] && [ "${graceful}" = "1" ]; then
    reason="requested: the server quit (exit ${rc})"
  fi
  [ -z "${reason}" ] && reason="the server ended on its own (exit ${rc})"

  if flux_restart_counts "${reason}"; then
    now="$(date -u +%s)"
    read -r -a restart_history <<<"$(flux_restarts_in_window "${now}" "${FLUX_RESTART_WINDOW}" "${restart_history[@]}")"
    restart_history+=("${now}")
    if [ "${#restart_history[@]}" -gt "${FLUX_RESTART_MAX_ATTEMPTS}" ]; then
      flux_log "${reason}: ${#restart_history[@]} restarts within ${FLUX_RESTART_WINDOW}s, so restarting it here is not working. Ending the container so the platform can rebuild or move it (42)."
      exit 42
    fi
  fi

  flux_log "${reason}: restarting the server in place in ${FLUX_RESTART_BACKOFF}s"
  sleep "${FLUX_RESTART_BACKOFF}" &
  wait $!
done
