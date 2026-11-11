#!/bin/bash
# Runs INSIDE the image (tests/test-image.sh). The repository's tests/ folder is mounted at /t.
# shellcheck disable=SC2016  # single quotes on purpose: the dollars in the test values must stay literal
set -uo pipefail
export LC_ALL=C

pass=0
fail=0
check() { # description, expected, actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3"
  fi
}
status() { "$@" >/dev/null 2>&1; echo $?; }

# --- What the scripts need is in the image -----------------------------------------------------
for tool in steamcmd python3 pgrep pkill curl find xargs timeout flock runuser; do
  check "${tool} is installed" "0" "$(status command -v "${tool}")"
done
check "flux-restart is on the PATH" "0" "$(status command -v flux-restart)"
check "flux-console is on the PATH" "0" "$(status command -v flux-console)"
check "flux-version is on the PATH" "0" "$(status command -v flux-version)"
check "the game's user is uid 1000" "1000" "$(id -u steam)"
check "its home is where the data lives" "/home/steam" "$(getent passwd steam | cut -d: -f6)"
check "the install and data folders exist and are the game's" "steam steam" "$(stat -c '%U %U' /home/steam/pz-dedicated /home/steam/Zomboid | sort -u | tr '\n' ' ' | sed 's/ $//')"
check "steamcmd is bootstrapped for the game's user" "0" "$(status test -d /home/steam/.local/share/Steam/steamcmd)"
check "the server's language exists" "0" "$(locale -a | grep -qi 'en_US.utf8'; echo $?)"
check "flux-config.py starts" "64" "$(status python3 /opt/flux/flux-config.py)"
for script in flux-entrypoint.sh flux-scheduler.sh flux-restart.sh flux-updatewatch.sh flux-console.sh flux-version.sh flux-lib.sh; do
  check "${script} parses" "0" "$(status bash -n "/opt/flux/${script}")"
done
check "the entrypoint refuses a branch that is not a name" "42" "$(STEAMAPPBRANCH='public +quit' FLUX_LOG='' timeout 20 /opt/flux/flux-entrypoint.sh >/dev/null 2>&1; echo $?)"

# --- The supervisor, around a stand-in Steam and a stand-in server -----------------------------
# steamcmd: "installs" a server into the dir it is given. The stand-in game keeps a console on its
# stdin like the real one: `quit` makes it write the line the real one writes after its save and
# then HANG, which the supervisor has to cut short; `servermsg` and `save` are recorded.
cat >/usr/local/bin/steamcmd <<'STUB'
#!/bin/bash
dir="" branch=public
while [ $# -gt 0 ]; do
  [ "$1" = "+force_install_dir" ] && dir="$2"
  [ "$1" = "-beta" ] && branch="$2"
  shift
done
[ -n "${dir}" ] || exit 0
[ -f /tmp/steam-fail ] && { echo "ERROR! Failed to install app '380870' (Missing configuration)"; exit 8; }
echo "steamcmd run: ${branch}" >>/tmp/steam-runs
mkdir -p "${dir}/steamapps" "${dir}/media/lua/shared/Sandbox"
cp /t/fixtures/Apocalypse.lua /t/fixtures/Outbreak.lua "${dir}/media/lua/shared/Sandbox/"
printf '"AppState"\n{\n\t"buildid"\t\t"%s"\n}\n' "$([ "${branch}" = legacy41 ] && echo 111 || echo 222)" >"${dir}/steamapps/appmanifest_380870.acf"
cat >"${dir}/start-server.sh" <<'LAUNCH'
#!/bin/bash
cd "$(dirname "$0")" && exec ./ProjectZomboid64 "$@"
LAUNCH
cat >"${dir}/ProjectZomboid64" <<'GAME'
#!/bin/bash
printf '%s\n' "$@" >/tmp/game-args
id -un >/tmp/game-user
echo "${HOME}" >/tmp/game-home
logs="${HOME}/Zomboid/Logs"
mkdir -p "${logs}"
log="${logs}/$(date +%Y-%m-%d_%H-%M-%S)_DebugLog-server.txt"
echo "LOG  : General      f:0 st:1> version=42.99.1 abcdef" >"${log}"
[ -f /tmp/game-crash ] && exit 0   # like start-server.sh: always 0, even for a crash
while IFS= read -r line; do
  case "${line}" in
    servermsg*) echo "${line}" >>/tmp/console-seen ;;
    save) echo "save" >>/tmp/console-seen ;;
    quit)
      echo "saved" >>/tmp/console-seen
      echo "LOG  : General      f:0 st:2> waiting for UdpEngine thread termination." >>"${log}"
      sleep 60   # the real one hangs here for a second or more
      exit 0 ;;
  esac
done
GAME
chmod +x "${dir}/start-server.sh" "${dir}/ProjectZomboid64"
STUB
chmod +x /usr/local/bin/steamcmd

export FLUX_LOG="" FLUX_RESTART_BACKOFF=0 FLUX_UPDATE_CHECK_SECONDS=3600
logfile=/tmp/supervisor.log
wait_for() { # pattern, seconds
  for _ in $(seq 1 $(($2 * 5))); do
    grep -q "$1" "${logfile}" 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}
start() { # extra env as VAR=value
  : >"${logfile}"
  rm -f /tmp/console-seen /tmp/game-args /tmp/game-user /tmp/steam-runs
  env SERVERNAME=pz DISPLAYNAME="Flux Test" SERVERPRESET=Outbreak ADMINUSERNAME=boss ADMINPASSWORD=adm1 RCONPASSWORD=rc1 \
    PUBLIC=true PORT=41261 UDPPORT=41262 MEMORY=3g SELF_MANAGED_MODS=true "$@" /opt/flux/flux-entrypoint.sh >"${logfile}" 2>&1 &
  sup=$!
}

start
check "the server starts" "0" "$(wait_for 'starting the server (generation 1)' 20; echo $?)"
wait_for 'game version' 10
check "it was installed from the public branch" "steamcmd run: public" "$(head -1 /tmp/steam-runs)"
check "the build id is read" "222" "$(flux-version | sed -n 's/.*"build":"\([0-9]*\)".*/\1/p')"
check "the game version is recorded" "42.99.1" "$(flux-version | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')"
check "flux-version names the branch" "public" "$(flux-version | sed -n 's/.*"branch":"\([^"]*\)".*/\1/p')"
check "the game runs as steam" "steam" "$(cat /tmp/game-user)"
check "with HOME where the data lives" "/home/steam" "$(cat /tmp/game-home)"
check "the Java heap comes first" "-Xms3g -Xmx3g --" "$(sed -n 1,3p /tmp/game-args | tr '\n' ' ' | sed 's/ $//')"
args="$(tr '\n' ' ' </tmp/game-args)"
check "the game's own arguments in order" "1" "$(grep -c -- '-adminusername boss -adminpassword adm1 -servername pz -port 41261' <<<"${args}")"
check "the ini was written before the start" "PublicName=Flux Test" "$(grep '^PublicName=' /home/steam/Zomboid/Server/pz.ini)"
check "and the sandbox file from the preset" "SandboxVars = {" "$(head -1 /home/steam/Zomboid/Server/pz_SandboxVars.lua)"
check "the server's own files belong to steam" "steam" "$(stat -c %U /home/steam/Zomboid/Server/pz.ini)"
flux-console 'servermsg "hello"'
sleep 0.5
check "a message reaches the console" "0" "$(status grep -q 'servermsg "hello"' /tmp/console-seen)"

# A planned restart: warned, saved, then the next generation, and not counted as a crash.
/opt/flux/flux-restart.sh "scheduled restart at 05:00" 0 "daily restart" >/dev/null 2>&1
check "a scheduled restart brings up generation 2" "0" "$(wait_for 'starting the server (generation 2)' 20; echo $?)"
check "the old server was asked to quit (saved)" "0" "$(status grep -q '^saved$' /tmp/console-seen)"
check "it was ended at its shutdown line, not after the grace" "0" "$(grep -c 'WARN the server was asked to stop' "${logfile}")"
check "and it was not counted as a crash" "0" "$(grep -c 'restarts within' "${logfile}")"

# An admin's own `quit` (RCON, or the console): a restart someone asked for, not a crash.
flux-console quit
check "an admin's quit brings up generation 3" "0" "$(wait_for 'starting the server (generation 3)' 20; echo $?)"
check "and is not counted as a crash" "0" "$(grep -c 'restarts within' "${logfile}")"
check "it says so" "1" "$(grep -c 'requested: the server quit' "${logfile}" | sed 's/^[1-9].*/1/')"

# A stop (what Docker sends): saved, cut short at the shutdown line, exit 0, inside Docker's 10 s.
wait_for 'game version' 10
sleep 1
t0=$(date +%s)
kill -TERM "${sup}"
wait "${sup}"
rc=$?
t1=$(date +%s)
check "a SIGTERM ends the supervisor with 0" "0" "${rc}"
check "inside five seconds, though the game hangs for sixty" "0" "$([ $((t1 - t0)) -le 5 ] && echo 0 || echo "took $((t1 - t0))s")"
check "and the world was told to save" "3" "$(grep -c '^saved$' /tmp/console-seen)"
check "no game process is left" "" "$(pgrep -f '/ProjectZomboid64( |$)' || true)"

# Characters a shell would mangle, in every value that reaches the server.
start 'ADMINPASSWORD=a b"c$d`e\x' 'DISPLAYNAME=Ünï & "q" $HOME' "PASSWORD=it's|a&b" SERVERNAME=odd
wait_for 'starting the server (generation 1)' 20
check "a password with spaces, quotes, dollar and backtick reaches the game as ONE argument" 'a b"c$d`e\x' "$(grep -A1 -x -- '-adminpassword' /tmp/game-args | tail -1)"
check "the display name is written literally" 'PublicName=Ünï & "q" $HOME' "$(grep '^PublicName=' /home/steam/Zomboid/Server/odd.ini)"
check "the join password is written literally" "Password=it's|a&b" "$(grep '^Password=' /home/steam/Zomboid/Server/odd.ini)"
kill -TERM "${sup}"; wait "${sup}"

# Mods from the environment (SELF_MANAGED_MODS off): the lists land in the ini.
start SELF_MANAGED_MODS=false SERVERNAME=modded 'MOD_IDS=\ModA;\ModB' 'WORKSHOP_IDS=111;222'
wait_for 'starting the server (generation 1)' 20
check "MOD_IDS lands in Mods" 'Mods=\ModA;\ModB' "$(grep '^Mods=' /home/steam/Zomboid/Server/modded.ini)"
check "WORKSHOP_IDS lands in WorkshopItems" 'WorkshopItems=111;222' "$(grep '^WorkshopItems=' /home/steam/Zomboid/Server/modded.ini)"
kill -TERM "${sup}"; wait "${sup}"

# A restart asked for while another is under way is dropped, not stacked.
start
wait_for 'game version' 20
( exec 9>/tmp/flux/restart.lock; flock 9; sleep 4 ) &
locker=$!
sleep 1
out="$(/opt/flux/flux-restart.sh "update: second" 0 "x" 2>&1)"
check "a second restart while one is under way is dropped" "1" "$(grep -c 'a restart is already under way' <<<"${out}")"
wait "${locker}"
kill -TERM "${sup}"; wait "${sup}"

# The Build 41 image (:b41) is the same image with another default branch.
start FLUX_DEFAULT_BRANCH=legacy41
wait_for 'starting the server (generation 1)' 20
check "the :b41 default installs legacy41" "steamcmd run: legacy41" "$(head -1 /tmp/steam-runs)"
kill -TERM "${sup}"; wait "${sup}"
start FLUX_DEFAULT_BRANCH=legacy41 STEAMAPPBRANCH=42.19
wait_for 'starting the server (generation 1)' 20
check "a branch in the spec wins over the image's default (a pinned version)" "steamcmd run: 42.19" "$(head -1 /tmp/steam-runs)"
kill -TERM "${sup}"; wait "${sup}"

# The Build 41 branch.
start STEAMAPPBRANCH=legacy41
wait_for 'starting the server (generation 1)' 20
check "STEAMAPPBRANCH=legacy41 installs that branch" "steamcmd run: legacy41" "$(head -1 /tmp/steam-runs)"
check "and reads its build" "111" "$(flux-version | sed -n 's/.*"build":"\([0-9]*\)".*/\1/p')"
kill -TERM "${sup}"; wait "${sup}"

# A server that cannot stay up ends the container (42) instead of looping for ever.
touch /tmp/game-crash
start FLUX_RESTART_MAX_ATTEMPTS=2
wait "${sup}"
check "a crash loop ends with 42" "42" "$?"
in_place="$(grep -c 'restarting the server in place' "${logfile}")"
[ "${in_place}" -ge 1 ] && restarted_first=0 || restarted_first=1
check "after restarting it in place first" "0" "${restarted_first}"
rm -f /tmp/game-crash

# Steam down and nothing installed: ends with 42, says why.
rm -rf /home/steam/pz-dedicated/* /home/steam/pz-dedicated/.[a-z]*
touch /tmp/steam-fail
start
wait "${sup}"
check "no install and no Steam ends with 42" "42" "$?"
check "and says it could not install" "1" "$(grep -c 'ERROR could not install the server from Steam' "${logfile}")"
rm -f /tmp/steam-fail

# Root-owned files in the data volume (a restore, an upload) are given back to the game's user.
mkdir -p /home/steam/Zomboid/db && : >/home/steam/Zomboid/db/pz.db && chown root:root /home/steam/Zomboid/db/pz.db
start
wait_for 'starting the server (generation 1)' 20
check "a root-owned database is fixed before the start" "steam" "$(stat -c %U /home/steam/Zomboid/db/pz.db)"
kill -TERM "${sup}"; wait "${sup}"

printf '%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
