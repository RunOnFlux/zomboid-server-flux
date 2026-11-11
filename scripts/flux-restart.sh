#!/bin/bash
# A planned restart of the running server, with a warning in game.
#
#   flux-restart.sh <reason> [warn minutes] [what players are told]
#
# Players are told on the server's console (servermsg) when the warning starts and again one minute before. Then the world
# is saved, the reason is left for the supervisor (so the restart does not count as a crash) and
# the console's `quit` saves it and exits; the supervisor starts the next generation, which updates first.
# Used by flux-updatewatch.sh and flux-scheduler.sh, and on the PATH as `flux-restart` for an
# admin in the container. One at a time: a second request while one is under way is dropped.

set -uo pipefail
# shellcheck source=scripts/flux-lib.sh
source /opt/flux/flux-lib.sh

reason="${1:?reason}"
warn="$(flux_warn_minutes "${2:-5}")"
why="${3:-}"

mkdir -p "${FLUX_RUN_DIR}"
exec 9>"${FLUX_RUN_DIR}/restart.lock"
if ! flock -n 9; then
  flux_log "a restart is already under way; not starting another (${reason})"
  exit 0
fi

say() {
  local minutes="$1" unit="minutes" text
  [ "${minutes}" = "1" ] && unit="minute"
  text="Server restart in ${minutes} ${unit}"
  [ -n "${why}" ] && text="${text}: ${why}"
  if flux_console "$(flux_servermsg "${text}")"; then
    flux_log "players warned: restart in ${minutes} ${unit}"
  else
    flux_log "WARN could not warn players on the console"
  fi
}

running() { [ -n "$(flux_game_pid)" ]; }

if ! running; then
  flux_log "restart wanted (${reason}), but the server is not running"
  exit 0
fi

due=$(($(date -u +%s) + warn * 60))
if [ "${warn}" -gt 0 ]; then
  say "${warn}"
  if [ "${warn}" -gt 1 ]; then
    sleep $((due - 60 - $(date -u +%s)))
    running || exit 0
    say 1
  fi
  left=$((due - $(date -u +%s)))
  [ "${left}" -gt 0 ] && sleep "${left}"
fi

pid="$(flux_game_pid)"
if [ -z "${pid}" ]; then
  flux_log "restart due (${reason}), but the server has stopped already"
  exit 0
fi
printf '%s' "${reason}" >"${FLUX_RESTART_MARKER}"
flux_log "${reason}: saving the world and restarting"
# `quit` saves the world and exits; the signal is the fallback for a console that is not there.
flux_console "quit" || kill -TERM "${pid}" 2>/dev/null
exit 0
