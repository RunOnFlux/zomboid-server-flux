#!/bin/bash
# One command on the running server's console, from inside the container.
#
#   flux-console servermsg "Back in five"
#   flux-console save
#
# The same stdin the supervisor holds open for the server. Prints nothing; exit 1 when there is no
# console (no server running). For an admin who is in the container; the dashboard uses RCON.
set -uo pipefail
# shellcheck source=scripts/flux-lib.sh
source /opt/flux/flux-lib.sh
[ $# -gt 0 ] || { echo "usage: flux-console <command...>" >&2; exit 64; }
flux_console "$*"
