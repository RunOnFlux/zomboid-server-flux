#!/bin/bash
# Shared helpers for the Project Zomboid image.
#
# SOURCING THIS FILE MUST STAY SIDE-EFFECT FREE: tests/test-flux.sh sources it directly and
# calls the functions with made-up inputs. Everything that decides something takes its inputs
# as arguments, so the decision can be tested without a server, Steam or Docker.

# ---------------------------------------------------------------------------------------------
# Paths. Two volumes. The install (SteamCMD's, a local `ml:` volume that is never synced) holds
# the game AND the Steam Workshop downloads (steamapps/workshop), and is disposable: an empty one
# is filled from Steam on the next start. The data (`g:`, synced) is the server's `Zomboid` folder:
# the world, the ini, the sandbox options, the db. Same layout as the image this replaces
# (danixu86/project-zomboid-dedicated-server), so a server moves over with its volume as it is.
# ---------------------------------------------------------------------------------------------
FLUX_HOME="${FLUX_HOME:-/home/steam}"
FLUX_SERVER_DIR="${FLUX_SERVER_DIR:-${FLUX_HOME}/pz-dedicated}"
FLUX_DATA_DIR="${FLUX_DATA_DIR:-${FLUX_HOME}/Zomboid}"
# Our own state on the install volume: the depotcache, the last update attempt.
FLUX_STATE_DIR="${FLUX_STATE_DIR:-${FLUX_SERVER_DIR}/.flux}"
# flux.log is on the INSTALL volume (local, never synced): it is written on every line, and on the
# synced data volume that would be constant Syncthing traffic. One rotated copy (flux.log.1).
FLUX_LOG_DIR="${FLUX_LOG_DIR:-${FLUX_SERVER_DIR}/flux-logs}"
FLUX_LOG="${FLUX_LOG-${FLUX_LOG_DIR}/flux.log}"
FLUX_LOG_MAX_BYTES="${FLUX_LOG_MAX_BYTES:-5242880}"

FLUX_STEAM_APP="${FLUX_STEAM_APP:-380870}"
FLUX_GAME_BINARY="${FLUX_GAME_BINARY:-ProjectZomboid64}"
FLUX_STEAM_USER="${FLUX_STEAM_USER:-steam}"

# Where the running generation leaves what the helpers (the console, the watchers) need.
FLUX_RUN_DIR="${FLUX_RUN_DIR:-/tmp/flux}"
FLUX_RESTART_MARKER="${FLUX_RESTART_MARKER:-${FLUX_RUN_DIR}/restart-requested}"
# The server's stdin. The supervisor holds it open, so a write never blocks and the server never
# reads end-of-file; `quit` on it saves the world and exits (the console's own command).
FLUX_CONSOLE="${FLUX_CONSOLE:-${FLUX_RUN_DIR}/console}"
# When the running server started (epoch seconds); the update watcher leaves a booting one alone.
FLUX_STARTED_AT="${FLUX_STARTED_AT:-${FLUX_RUN_DIR}/started-at}"

# One line, to the container's output and (when FLUX_LOG is set) to flux.log, rotated at
# FLUX_LOG_MAX_BYTES (the old file becomes flux.log.1).
flux_log_raw() {
  printf '%s\n' "$1"
  if [ -n "${FLUX_LOG}" ] && mkdir -p "$(dirname "${FLUX_LOG}")" 2>/dev/null; then
    printf '%s\n' "$1" >>"${FLUX_LOG}" 2>/dev/null || return 0
    flux_rotate_log "${FLUX_LOG}" "${FLUX_LOG_MAX_BYTES}"
  fi
  return 0
}

flux_log() {
  flux_log_raw "$(date -u '+%Y-%m-%dT%H:%M:%SZ') [flux] $*"
}

# Moves $1 to $1.1 (replacing the previous one) once it is larger than $2 bytes.
flux_rotate_log() {
  local size
  size="$(stat -c %s "$1" 2>/dev/null || echo 0)"
  if [ "${size}" -gt "$2" ] 2>/dev/null; then
    mv -f "$1" "$1.1" 2>/dev/null
  fi
  return 0
}

# The start-up banner, through the normal log path (docker logs, the panel's log). ASCII only.
flux_banner() {
  local rule='====================================================================='
  flux_log_raw "${rule}"
  flux_log_raw " Project Zomboid server image by FluxCloud - https://runonflux.com"
  flux_log_raw " Host this and 30+ other games in one click: https://runonflux.com/games"
  flux_log_raw "${rule}"
}

flux_truthy() {
  case "${1,,}" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

# Runs a command as the game's user, with HOME where the game and SteamCMD keep their files.
flux_as_steam() {
  runuser -u "${FLUX_STEAM_USER}" -- env "HOME=${FLUX_HOME}" "$@"
}

# ---------------------------------------------------------------------------------------------
# The Steam branch. `public` is Build 42, `legacy41` is Build 41, `unstable` is the next B42.
# The game build is chosen HERE, by the branch, never by an image tag: one image serves both
# builds, and every start installs the newest version of the branch.
# ---------------------------------------------------------------------------------------------

# $1 = the branch as given. Prints it (`public` for an empty one), or returns 1 for a name
# SteamCMD should never be handed.
flux_steam_branch() {
  local value="${1:-public}"
  [[ "${value}" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || return 1
  printf '%s' "${value}"
}

# $1 = an appmanifest_<app>.acf. Prints the installed build id, or nothing.
flux_acf_buildid() {
  sed -n 's/^[[:space:]]*"buildid"[[:space:]]*"\([0-9]*\)".*/\1/p' "$1" 2>/dev/null | head -1
}

# $1 = the installed build, $2 = the newest build Steam lists. True when $2 is a real build id
# that is not the one installed. Not "greater than": Steam can roll a branch BACK, and a server
# on the pulled build would then refuse the players on the restored one.
flux_build_is_new() {
  [[ "$2" =~ ^[0-9]+$ ]] || return 1
  [ "$1" != "$2" ]
}

# $1 = a server log. Prints the game version it printed at start ("version=42.22.2 3d39148846"),
# or nothing.
flux_version_from_log() {
  sed -n 's/.*> version=\([0-9][0-9.]*\) .*/\1/p' "$1" 2>/dev/null | tail -1
}

# $1 = the game's Logs folder, $2 = the start stamp. Prints the version this generation's server
# log reports, or nothing yet.
flux_logged_version() {
  local f
  f="$(find "$1" -maxdepth 1 -name '*DebugLog-server.txt' -newer "$2" 2>/dev/null | sort | tail -1)"
  [ -n "${f}" ] && flux_version_from_log "${f}"
}

# $1 = a port value. Prints it, or returns 1 for a value that is not a usable port.
flux_valid_port() {
  local value="$1"
  [[ "${value}" =~ ^[0-9]{1,5}$ ]] || return 1
  value=$((10#${value}))
  [ "${value}" -ge 1 ] && [ "${value}" -le 65535 ] || return 1
  printf '%s' "${value}"
}

# ---------------------------------------------------------------------------------------------
# The heap. The spec's MEMORY (or MIN_MEMORY/MAX_MEMORY) is the Java heap. With none, the JVM
# picks a quarter of the host's RAM, which on a node is far more than the plan.
# ---------------------------------------------------------------------------------------------

# The container's memory limit in MB, or nothing when there is none (cgroup v2, then v1).
flux_memory_limit_mb() {
  local raw=""
  if [ -r /sys/fs/cgroup/memory.max ]; then raw="$(cat /sys/fs/cgroup/memory.max)"
  elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then raw="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)"; fi
  [[ "${raw}" =~ ^[0-9]+$ ]] || return 0
  # An unlimited container reports a number near 2^63.
  [ "${#raw}" -le 13 ] || return 0
  printf '%s' $((raw / 1048576))
}

# $1 = the container's memory in MB. Prints the default heap, in the unit the JVM takes: 75% of
# it, because the JVM also needs memory outside the heap (the engine, Workshop, the page cache the
# world streams through). Nothing for an unknown memory, which leaves the heap to the game.
flux_default_heap() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1024 ] || return 0
  printf '%sm' $(($1 * 75 / 100))
}

# ---------------------------------------------------------------------------------------------
# Scheduled restarts.
# ---------------------------------------------------------------------------------------------

# $1 = FLUX_RESTART_TIME ("HH:MM"). Prints the minute of the day, or returns 1.
flux_restart_minute_of_day() {
  local value="$1" h m
  [[ "${value}" =~ ^([0-9]{1,2}):([0-9]{2})$ ]] || return 1
  h=$((10#${BASH_REMATCH[1]}))
  m=$((10#${BASH_REMATCH[2]}))
  [ "${h}" -le 23 ] && [ "${m}" -le 59 ] || return 1
  printf '%s' $((h * 60 + m))
}

# $1 = minute of the day the restart is set for, $2 = the current minute of the day, $3 = the
# current second of that minute. Prints how many seconds until the next restart. A restart due
# this very minute is tomorrow's: otherwise a server that restarts at 05:00 and is back up at
# 05:00:40 restarts again.
flux_seconds_until() {
  local target="$1" now_min="$2" now_sec="${3:-0}" delta
  delta=$(((target - now_min) * 60 - now_sec))
  [ "${delta}" -le 0 ] && delta=$((delta + 86400))
  printf '%s' "${delta}"
}

# $1 = a warning in minutes. Prints it clamped to 0..30 (5 for anything unreadable).
flux_warn_minutes() {
  local value="${1:-5}"
  [[ "${value}" =~ ^[0-9]+$ ]] || value=5
  value=$((10#${value}))
  [ "${value}" -gt 30 ] && value=30
  printf '%s' "${value}"
}

# $1 = a check interval in minutes. Prints it clamped to 2..1440 (10 for anything unreadable).
flux_check_minutes() {
  local value="${1:-10}"
  [[ "${value}" =~ ^[0-9]+$ ]] || value=10
  value=$((10#${value}))
  [ "${value}" -lt 2 ] && value=2
  [ "${value}" -gt 1440 ] && value=1440
  printf '%s' "${value}"
}

# ---------------------------------------------------------------------------------------------
# The supervisor's restart budget: a server that keeps dying is not fixed by restarting it in
# the same container forever.
# ---------------------------------------------------------------------------------------------

# $1 = now (epoch seconds), $2 = window in seconds, $3.. = the times of earlier restarts.
# Prints the restarts that are still inside the window, space separated.
flux_restarts_in_window() {
  local now="$1" window="$2" t kept=()
  shift 2
  for t in "$@"; do
    [ "${t}" -gt $((now - window)) ] && kept+=("${t}")
  done
  printf '%s' "${kept[*]}"
}

# $1 = why the last generation ended. One that was asked for (an update, the daily restart, an
# admin's `quit`) is the plan working, not a crash.
flux_restart_counts() {
  case "$1" in
    planned* | requested* | scheduled* | update*) return 1 ;;
    *) return 0 ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# The running server.
# ---------------------------------------------------------------------------------------------

# The game is a native launcher that loads the JVM itself, so its process name is
# `ProjectZomboid6` (the kernel keeps 15 characters) and `-x` on the full name never matches.
flux_game_pid() {
  pgrep -f "${FLUX_SERVER_DIR}/${FLUX_GAME_BINARY}|/${FLUX_GAME_BINARY}( |\$)" 2>/dev/null | head -1
}

# $1 = the epoch the server started, $2 = now, $3 = the grace in seconds. True while it is still
# inside its boot grace (a world that is loading cannot be told anything).
flux_booting() {
  [ -n "$1" ] || return 0
  [ $(($2 - $1)) -lt "$3" ]
}

# One command on the server's console. $1 = the command. Quiet, and never blocks: the supervisor
# holds the other end open.
flux_console() {
  [ -p "${FLUX_CONSOLE}" ] || return 1
  # shellcheck disable=SC2016  # the single quotes are the inner shell's script, on purpose
  timeout 5 bash -c 'printf "%s\n" "$1" >"$2"' _ "$1" "${FLUX_CONSOLE}" 2>/dev/null
}

# $1 = text. Prints it as a console `servermsg`, with the characters that would end the command
# line removed.
flux_servermsg() {
  local text="${1//\"/\'}"
  text="${text//$'\n'/ }"
  printf 'servermsg "%s"' "${text}"
}

# $1 = the game's Logs folder, $2 = the file the supervisor stamped when this generation started.
# True once this generation's server log says it has saved everything and is only waiting for its
# network thread. Measured on 42.22.2: the world is saved within 0.3 s of `quit`, the rest of the
# data (id_manager_data.bin) at +8.3 s, and this line right after it; the process then needs
# another 1.4 s to exit. Docker's own deadline on Flux is 10 s, so the supervisor ends the game at
# this line instead of racing it.
flux_shutdown_reached() {
  local f
  [ -f "$2" ] || return 1
  # The newest log of this generation, and only its tail: a modded server's log is megabytes, and
  # this runs every second (every fifth of one while a stop is under way).
  f="$(find "$1" -maxdepth 1 -name '*DebugLog-server.txt' -newer "$2" 2>/dev/null | sort | tail -1)"
  [ -n "${f}" ] || return 1
  tail -c 65536 "${f}" 2>/dev/null | grep -q 'waiting for UdpEngine thread termination'
}

# Kills every game process still alive between two generations, and prints how many it found. A
# child the game forked outlives a kill of the game itself.
flux_kill_leftover_games() {
  local pids
  pids="$(pgrep -f "/${FLUX_GAME_BINARY}( |\$)" 2>/dev/null)"
  [ -n "${pids}" ] || return 0
  # shellcheck disable=SC2086  # one pid per word
  kill -KILL ${pids} 2>/dev/null
  wc -w <<<"${pids}"
}
