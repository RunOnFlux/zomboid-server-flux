#!/bin/bash
# Unit tests: the pure decisions in flux-lib.sh and the settings writer (flux-config.py). No Docker,
# no Steam, no game. Run from the repository root.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# shellcheck source=scripts/flux-lib.sh
FLUX_LOG="" source scripts/flux-lib.sh

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
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# --- Steam branch ------------------------------------------------------------------------------
check "empty is public" "public" "$(flux_steam_branch '')"
check "legacy41 is a branch" "legacy41" "$(flux_steam_branch legacy41)"
check "unstable is a branch" "unstable" "$(flux_steam_branch unstable)"
check "a branch with a space is refused" "1" "$(status flux_steam_branch 'public +quit')"
check "a branch with a quote is refused" "1" "$(status flux_steam_branch "a'b")"
check "a branch with a slash is refused" "1" "$(status flux_steam_branch '../x')"

# --- Build ids ---------------------------------------------------------------------------------
cat >"${tmp}/app.acf" <<'ACF'
"AppState"
{
	"appid"		"380870"
	"buildid"		"26486687"
	"TargetBuildID"		"26486687"
}
ACF
check "the installed build is read" "26486687" "$(flux_acf_buildid "${tmp}/app.acf")"
check "a missing manifest is empty" "" "$(flux_acf_buildid "${tmp}/none.acf")"
check "a new build is new" "0" "$(status flux_build_is_new 26486687 26500000)"
check "the same build is not" "1" "$(status flux_build_is_new 26486687 26486687)"
check "an older build on the branch counts (Steam rolled back)" "0" "$(status flux_build_is_new 26486687 26400000)"
check "a junk answer is not a build" "1" "$(status flux_build_is_new 26486687 'oops')"
check "an empty answer is not a build" "1" "$(status flux_build_is_new 26486687 '')"

# --- Game version from the log -----------------------------------------------------------------
printf '%s\n' 'LOG  : General      f:0 st:28,429,802> Waiting for response from Steam servers' \
  'LOG  : General      f:0 st:28,429,802> version=42.22.2 3d39148846' >"${tmp}/log.txt"
check "the game version is read from the log" "42.22.2" "$(flux_version_from_log "${tmp}/log.txt")"
check "a log without it is empty" "" "$(flux_version_from_log "${tmp}/app.acf")"

# --- Ports -------------------------------------------------------------------------------------
check "a port" "41261" "$(flux_valid_port 41261)"
check "port 0 is refused" "1" "$(status flux_valid_port 0)"
check "port 70000 is refused" "1" "$(status flux_valid_port 70000)"
check "a word is refused" "1" "$(status flux_valid_port abc)"

# --- Heap --------------------------------------------------------------------------------------
check "75% of 6000 MB" "4500m" "$(flux_default_heap 6000)"
check "75% of 16000 MB" "12000m" "$(flux_default_heap 16000)"
check "an unknown memory leaves the heap to the game" "" "$(flux_default_heap '')"
check "a tiny memory leaves it too" "" "$(flux_default_heap 512)"

# --- Restart time ------------------------------------------------------------------------------
check "05:00 is minute 300" "300" "$(flux_restart_minute_of_day 05:00)"
check "5:07 is minute 307" "307" "$(flux_restart_minute_of_day 5:07)"
check "00:08 is not octal" "8" "$(flux_restart_minute_of_day 00:08)"
check "24:00 is refused" "1" "$(status flux_restart_minute_of_day 24:00)"
check "empty means no restart" "1" "$(status flux_restart_minute_of_day '')"
check "a cron line is refused" "1" "$(status flux_restart_minute_of_day '0 5 * * *')"
check "an hour ahead" "3600" "$(flux_seconds_until 300 240 0)"
check "the seconds already past count" "3570" "$(flux_seconds_until 300 240 30)"
check "earlier today means tomorrow" "82800" "$(flux_seconds_until 300 360 0)"
check "due this very minute means tomorrow" "86370" "$(flux_seconds_until 300 300 30)"
check "warning defaults to 5" "5" "$(flux_warn_minutes '')"
check "warning is capped at 30" "30" "$(flux_warn_minutes 90)"
check "warning 08 is not octal" "8" "$(flux_warn_minutes 08)"
check "a non-number warning is 5" "5" "$(flux_warn_minutes soon)"
check "check interval default" "10" "$(flux_check_minutes '')"
check "check interval floor" "2" "$(flux_check_minutes 0)"
check "check interval cap" "1440" "$(flux_check_minutes 99999)"

# --- Restart budget ----------------------------------------------------------------------------
check "old restarts age out" "900 950" "$(flux_restarts_in_window 1000 200 100 700 900 950)"
check "a scheduled restart is not counted" "1" "$(status flux_restart_counts 'scheduled restart at 05:00')"
check "an update is not counted" "1" "$(status flux_restart_counts 'update: build 1 is out')"
check "a quit is not counted" "1" "$(status flux_restart_counts 'requested: the server quit (exit 0)')"
check "a crash is counted" "0" "$(status flux_restart_counts 'the server ended on its own (exit 139)')"

# --- The console message -----------------------------------------------------------------------
check "servermsg" 'servermsg "Back in five"' "$(flux_servermsg 'Back in five')"
check "a quote cannot end the message" "servermsg \"say 'hi' now\"" "$(flux_servermsg 'say "hi" now')"
check "a newline cannot end the command" 'servermsg "a b"' "$(flux_servermsg $'a\nb')"

# --- The shutdown line in this generation's log ------------------------------------------------
logs="${tmp}/Logs"
mkdir -p "${logs}"
printf 'waiting for UdpEngine thread termination.\n' >"${logs}/old_DebugLog-server.txt"
sleep 1
touch "${tmp}/started"
sleep 1
check "an older generation's log does not count" "1" "$(status flux_shutdown_reached "${logs}" "${tmp}/started")"
printf 'LOG started\n' >"${logs}/new_DebugLog-server.txt"
check "a log without the line does not count" "1" "$(status flux_shutdown_reached "${logs}" "${tmp}/started")"
printf 'LOG  : General> waiting for UdpEngine thread termination.\n' >>"${logs}/new_DebugLog-server.txt"
check "this generation's log with the line counts" "0" "$(status flux_shutdown_reached "${logs}" "${tmp}/started")"
check "the version comes from this generation's log" "" "$(flux_logged_version "${logs}" "${tmp}/started")"
printf 'LOG  : General      f:0 st:1> version=41.78.21 abc\n' >>"${logs}/new_DebugLog-server.txt"
check "the version of this generation" "41.78.21" "$(flux_logged_version "${logs}" "${tmp}/started")"

# --- flux-config.py ----------------------------------------------------------------------------
# $1 = a case directory. Lays out an install (presets, no Workshop) and an empty data folder.
layout() {
  local c="$1"
  mkdir -p "${c}/server/media/lua/shared/Sandbox" "${c}/server/media/maps" "${c}/data"
  cp tests/fixtures/Apocalypse.lua tests/fixtures/Outbreak.lua "${c}/server/media/lua/shared/Sandbox/"
}
prep() { # case dir, then VAR=value pairs
  local c="$1"
  shift
  env -i PATH="${PATH}" FLUX_SERVER_DIR="${c}/server" FLUX_DATA_DIR="${c}/data" "$@" python3 scripts/flux-config.py prepare 2>&1
}
ini() { echo "$1/data/Server/${2:-servertest}.ini"; }

# A new server: the ini is created and every setting lands in it on the FIRST run.
c="${tmp}/c1"; layout "${c}"
out="$(prep "${c}" SERVERNAME=pz1 SERVERPRESET=Outbreak PASSWORD=join1 RCONPASSWORD=rc1 RCON_PORT=47015 PUBLIC=true DISPLAYNAME='My Server' UDPPORT=41262 SELF_MANAGED_MODS=true)"
f="$(ini "${c}" pz1)"
check "a new ini exists" "0" "$(status test -f "${f}")"
check "Password" "Password=join1" "$(grep '^Password=' "${f}")"
check "RCONPassword" "RCONPassword=rc1" "$(grep '^RCONPassword=' "${f}")"
check "RCONPort" "RCONPort=47015" "$(grep '^RCONPort=' "${f}")"
check "Public" "Public=true" "$(grep '^Public=' "${f}")"
check "PublicName" "PublicName=My Server" "$(grep '^PublicName=' "${f}")"
check "UDPPort" "UDPPort=41262" "$(grep '^UDPPort=' "${f}")"
sandbox="${c}/data/Server/pz1_SandboxVars.lua"
check "the preset is copied" "0" "$(status test -f "${sandbox}")"
check "its first line is the table the game reads" "SandboxVars = {" "$(head -1 "${sandbox}")"
check "its carriage returns are gone" "0" "$(grep -c $'\r' "${sandbox}")"
check "it is the chosen preset" "    Zombies = 2," "$(sed -n 3p "${sandbox}")"
check "mods are left alone when self-managed" "0" "$(grep -c '^Mods=' "${f}")"
check "the preset is reported" "1" "$(grep -c 'sandbox preset Outbreak copied' <<<"${out}")"

# An existing world keeps its sandbox file; a preset the build lacks is NOT fatal and changes nothing.
printf 'SandboxVars = {\n    Zombies = 9,\n}\n' >"${sandbox}"
out="$(prep "${c}" SERVERNAME=pz1 SERVERPRESET=FirstWeek SELF_MANAGED_MODS=true)"
check "an existing sandbox file is not overwritten" "    Zombies = 9," "$(sed -n 2p "${sandbox}")"
check "a missing preset is a warning, with the ones it has" "1" "$(grep -c "WARN preset 'FirstWeek' does not exist on this build (it has: Apocalypse, Outbreak)" <<<"${out}")"
out="$(prep "${c}" SERVERNAME=pz1 SERVERPRESET=Outbreak SELF_MANAGED_MODS=true)"
check "a preset that exists does not replace an existing world's" "    Zombies = 9," "$(sed -n 2p "${sandbox}")"
prep "${c}" SERVERNAME=pz1 SERVERPRESET=Outbreak SERVERPRESETREPLACE=true SELF_MANAGED_MODS=true >/dev/null
check "SERVERPRESETREPLACE overwrites" "    Zombies = 2," "$(sed -n 3p "${sandbox}")"

# A new world with a preset the build lacks starts on Apocalypse instead of not starting.
c="${tmp}/c2"; layout "${c}"
out="$(prep "${c}" SERVERNAME=pz2 SERVERPRESET=Survivor SELF_MANAGED_MODS=true)"
check "a Build 41 preset on a new Build 42 world falls back" "    Zombies = 4," "$(sed -n 3p "${c}/data/Server/pz2_SandboxVars.lua")"
check "and says so" "1" "$(grep -c "using Apocalypse instead" <<<"${out}")"
check "a traversal in the preset name is refused, not followed" "1" "$(prep "${tmp}/c2" SERVERNAME=pz2b SERVERPRESET='../../x' SELF_MANAGED_MODS=true | grep -c 'using Apocalypse instead')"

# Settings replace an existing line and append a missing one; mods follow MOD_IDS.
c="${tmp}/c3"; layout "${c}"; mkdir -p "${c}/data/Server"
printf 'Mods=old\nPassword=\nPublic=true\nMOTD=hello\n' >"$(ini "${c}" a)"
prep "${c}" SERVERNAME=a PASSWORD='p&a|s\x' MOD_IDS='ModA;ModB' WORKSHOP_IDS='111;222' PUBLIC=false >/dev/null
f="$(ini "${c}" a)"
check "a password with sed characters is written literally" 'Password=p&a|s\x' "$(grep '^Password=' "${f}")"
check "Mods replaced" "Mods=ModA;ModB" "$(grep '^Mods=' "${f}")"
check "WorkshopItems appended" "WorkshopItems=111;222" "$(grep '^WorkshopItems=' "${f}")"
check "Public turned off" "Public=false" "$(grep '^Public=' "${f}")"
check "other lines survive" "MOTD=hello" "$(grep '^MOTD=' "${f}")"
check "no duplicate keys" "1" "$(grep -c '^Password=' "${f}")"
prep "${c}" SERVERNAME=a >/dev/null
check "with no MOD_IDS the list is cleared (image behaviour)" "Mods=" "$(grep '^Mods=' "${f}")"
prep "${c}" SERVERNAME=a SELF_MANAGED_MODS=true MOD_IDS=zzz >/dev/null
check "SELF_MANAGED_MODS leaves the list as it is" "Mods=" "$(grep '^Mods=' "${f}")"

# The spec writes a setting only when the SPEC changed: an edit in the ini sticks (the dashboard's
# Server Settings tab, or an admin), and a changed spec lands on the next start.
c="${tmp}/c6"; layout "${c}"
prep "${c}" SERVERNAME=e DISPLAYNAME=First PASSWORD=one PUBLIC=true SELF_MANAGED_MODS=true >/dev/null
f="$(ini "${c}" e)"
check "first start applies the spec" "PublicName=First" "$(grep '^PublicName=' "${f}")"
sed -i 's/^PublicName=.*/PublicName=Edited in the panel/;s/^Password=.*/Password=edited/' "${f}"
out="$(prep "${c}" SERVERNAME=e DISPLAYNAME=First PASSWORD=one PUBLIC=true SELF_MANAGED_MODS=true)"
check "an edit in the ini survives a restart with the same spec" "PublicName=Edited in the panel" "$(grep '^PublicName=' "${f}")"
check "and so does an edited password" "Password=edited" "$(grep '^Password=' "${f}")"
check "nothing is reported as applied" "0" "$(grep -c 'from the spec' <<<"${out}")"
prep "${c}" SERVERNAME=e DISPLAYNAME=Second PASSWORD=one PUBLIC=true SELF_MANAGED_MODS=true >/dev/null
check "a changed spec lands on the next start" "PublicName=Second" "$(grep '^PublicName=' "${f}")"
check "and only that key" "Password=edited" "$(grep '^Password=' "${f}")"
out="$(prep "${c}" SERVERNAME=e DISPLAYNAME=Second SELF_MANAGED_MODS=true)"
check "a join password the spec dropped opens the server" "Password=" "$(grep '^Password=' "${f}")"
check "a password is never echoed into the log" "0" "$(grep -c 'one\|edited' <<<"${out}")"
check "the record holds hashes, not secrets" "0" "$(grep -c 'one\|edited\|Second' "${c}/data/Server/.flux-env-applied.json")"

# Workshop maps: merged into Map= keeping the owner's order, base map last, no duplicates.
c="${tmp}/c4"; layout "${c}"
w="${c}/server/steamapps/workshop/content/108600"
mkdir -p "${w}/1001/mods/MapMod/media/maps/Aztown" "${w}/1001/mods/MapMod/media/maps/AztownPatch" \
  "${w}/1002/mods/B42Mod/42/media/maps/Ravenhill" "${w}/1002/mods/B42Mod/media/maps/OldOnly" \
  "${w}/1003/mods/NoMaps/media/lua"
printf 'x' >"${w}/1001/mods/MapMod/media/maps/Aztown/spawnpoints.lua"
printf 'x' >"${w}/1002/mods/B42Mod/42/media/maps/Ravenhill/spawnpoints.lua"
mkdir -p "${c}/data/Server"
printf 'Map=Ravenhill;Muldraugh, KY\n' >"$(ini "${c}" m)"
cp tests/fixtures/spawnregions.lua "${c}/data/Server/m_spawnregions.lua"
prep "${c}" SERVERNAME=m SELF_MANAGED_MODS=true FLUX_BUILD=42 >/dev/null
check "the owner's order is kept, the new ones follow, the base map is last" \
  "Map=Ravenhill;Aztown;AztownPatch;Muldraugh, KY" "$(grep '^Map=' "$(ini "${c}" m)")"
check "an unversioned folder beside a 42 one is not read on Build 42" "1" "$(status grep -q OldOnly "$(ini "${c}" m)")"
check "the map is copied into the install" "0" "$(status test -d "${c}/server/media/maps/Aztown")"
check "its spawn point is registered" "1" "$(grep -c 'media/maps/Aztown/spawnpoints.lua' "${c}/data/Server/m_spawnregions.lua")"
prep "${c}" SERVERNAME=m SELF_MANAGED_MODS=true FLUX_BUILD=42 >/dev/null
check "a second start changes nothing" "Map=Ravenhill;Aztown;AztownPatch;Muldraugh, KY" "$(grep '^Map=' "$(ini "${c}" m)")"
check "and registers the spawn point once" "1" "$(grep -c 'media/maps/Aztown/spawnpoints.lua' "${c}/data/Server/m_spawnregions.lua")"
c="${tmp}/c5"; layout "${c}"
w="${c}/server/steamapps/workshop/content/108600"
mkdir -p "${w}/1002/mods/B42Mod/42/media/maps/Ravenhill" "${w}/1002/mods/B42Mod/media/maps/OldOnly" "${w}/1002/mods/B42Mod/41/media/maps/Both"
prep "${c}" SERVERNAME=m SELF_MANAGED_MODS=true FLUX_BUILD=41 >/dev/null
check "Build 41 reads the mod's own media folder only" "Map=OldOnly;Muldraugh, KY" "$(grep '^Map=' "$(ini "${c}" m)")"
check "a name that is not plain is refused" "1" "$(prep "${tmp}/c5" SERVERNAME='a/b' | grep -c 'not a plain name')"
check "the entry point takes no argument" "64" "$(status python3 scripts/flux-config.py)"

printf '%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
