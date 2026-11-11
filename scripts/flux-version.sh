#!/bin/bash
# What the server is running, as one JSON line, for the dashboard (over appexec) and for an admin:
#
#   {"branch":"public","build":"20876403","version":"42.21.0"}
#
# `build` is Steam's build id of the install, `version` the game's own number, read from the server's
# log (the game prints it once per start); either may be empty before the first start.
set -uo pipefail
# shellcheck source=scripts/flux-lib.sh
source /opt/flux/flux-lib.sh
build="$(flux_acf_buildid "${FLUX_SERVER_DIR}/steamapps/appmanifest_${FLUX_STEAM_APP}.acf")"
version="$(cat "${FLUX_STATE_DIR}/version" 2>/dev/null)"
# The branch is the one INSTALLED (recorded by the supervisor), else the one the spec or the image tag asks for.
branch="$(cat "${FLUX_STATE_DIR}/branch" 2>/dev/null)"
branch="${branch:-${STEAMAPPBRANCH:-${STEAM_BRANCH:-${FLUX_DEFAULT_BRANCH:-public}}}}"
printf '{"branch":"%s","build":"%s","version":"%s"}\n' "${branch}" "${build}" "${version}"
