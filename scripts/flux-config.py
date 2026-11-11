#!/usr/bin/env python3
"""flux-config: what the environment says about the server, written where the server reads it.

    flux-config.py prepare        run before every start of the server

Writes, from the environment, into <Zomboid>/Server/<SERVERNAME>.ini and
<SERVERNAME>_SandboxVars.lua, the same way the image this one replaces
(danixu86/project-zomboid-dedicated-server, GPL-3, scripts/entry.sh) did, so a server moves over
with its volume as it is. One thing is deliberately different: a preset the build does not have
(a Build 41 preset on Build 42) is reported and replaced, never fatal. The old image exited
at once, and the owner saw "frozen" with nothing to act on.

Environment, all optional:
    SERVERNAME            the ini and sandbox file names (default servertest)
    SERVERPRESET          sandbox preset for a NEW world (SERVERPRESETREPLACE=true overwrites an old one)
    PASSWORD              join password             -> Password
    RCONPASSWORD          RCON password             -> RCONPassword
    RCON_PORT             RCON port                 -> RCONPort
    PUBLIC                true/false                -> Public
    DISPLAYNAME           browser name              -> PublicName
    UDPPORT               second UDP port           -> UDPPort
    SELF_MANAGED_MODS     true: Mods/WorkshopItems stay as they are in the ini (the dashboard edits them)
    MOD_IDS, WORKSHOP_IDS else: written to Mods and WorkshopItems
    FLUX_BUILD            41 or 42: which build's mod folders to read maps from (default 42)

Prints one line per thing it did. Never raises: a file it cannot write is a warning, and the
server starts with what is there.
"""
import hashlib
import json
import os
import re
import shutil
import sys

BASE_MAP = "Muldraugh, KY"
PRESET_FALLBACK = "Apocalypse"
NAME_RE = re.compile(r"^[A-Za-z0-9_.-]+$")


def truthy(value):
    return str(value or "").strip().lower() in ("1", "true", "yes", "on")


def read_lines(path):
    try:
        with open(path, encoding="utf-8", errors="surrogateescape", newline="") as f:
            return f.read().split("\n")
    except OSError:
        return []


def write_text(path, text):
    tmp = path + ".flux-tmp"
    with open(tmp, "w", encoding="utf-8", errors="surrogateescape", newline="") as f:
        f.write(text)
    shutil.copymode(path, tmp) if os.path.exists(path) else None
    os.replace(tmp, path)


def set_ini_option(path, key, value):
    """Replace `key=` when present (every occurrence), append it when not. The value is literal."""
    lines = read_lines(path)
    found = False
    out = []
    prefix = key + "="
    for line in lines:
        if line.startswith(prefix):
            out.append(prefix + value)
            found = True
        else:
            out.append(line)
    if not found:
        # Keep one trailing newline: `a\n` splits into ['a', ''].
        if out and out[-1] == "":
            out.pop()
        out.append(prefix + value)
        out.append("")
    write_text(path, "\n".join(out))


def get_ini_option(path, key):
    prefix = key + "="
    for line in read_lines(path):
        if line.startswith(prefix):
            return line[len(prefix):].rstrip("\r")
    return None


def apply_preset(install, server_dir, name, preset, replace, say):
    """Copy the preset in as the world's sandbox file when there is none (or `replace`)."""
    sandbox = os.path.join(server_dir, name + "_SandboxVars.lua")
    exists = os.path.isfile(sandbox)
    if not preset:
        return
    wanted = preset
    presets = os.path.join(install, "media", "lua", "shared", "Sandbox")
    path = os.path.join(presets, preset + ".lua")
    if not NAME_RE.match(preset) or not os.path.isfile(path):
        have = sorted(
            f[:-4] for f in os.listdir(presets)
            if f.endswith(".lua") and f != "SandboxVars.lua"
        ) if os.path.isdir(presets) else []
        if exists and not replace:
            say("WARN preset '%s' does not exist on this build (it has: %s); the world already has its sandbox file, so nothing changes"
                % (preset, ", ".join(have) or "none"))
            return
        fallback = os.path.join(presets, PRESET_FALLBACK + ".lua")
        if not os.path.isfile(fallback):
            say("WARN preset '%s' does not exist on this build and neither does %s; the game will use its defaults"
                % (preset, PRESET_FALLBACK))
            return
        say("WARN preset '%s' does not exist on this build (it has: %s); using %s instead"
            % (preset, ", ".join(have) or "none", PRESET_FALLBACK))
        wanted, path = PRESET_FALLBACK, fallback
    if exists and not replace:
        return
    os.makedirs(server_dir, exist_ok=True)
    with open(path, encoding="utf-8", errors="surrogateescape", newline="") as f:
        text = f.read().replace("\r\n", "\n").replace("\r", "\n")
    lines = text.split("\n")
    if lines:
        lines[0] = re.sub(r"^return.*", "SandboxVars = {", lines[0])
    write_text(sandbox, "\n".join(lines))
    os.chmod(sandbox, 0o644)
    say("new world: sandbox preset %s copied to %s" % (wanted, os.path.basename(sandbox)))


def map_roots(mod_dir, build):
    """The media/maps folders of one mod that the game reads on this build.

    Build 41 reads the mod's own media folder and nothing else. Build 42 reads `common/` and the
    folder for its version (`42`, or `42.<minor>`); a mod with no such folder is a Build 41 layout,
    which Build 42 still reads from the mod root."""
    def maps(*parts):
        r = os.path.join(mod_dir, *parts, "media", "maps")
        return r if os.path.isdir(r) else None

    if str(build) == "41":
        return [r for r in (maps(),) if r]
    roots = [maps("common")]
    versioned = sorted(
        d for d in (os.listdir(mod_dir) if os.path.isdir(mod_dir) else [])
        if re.fullmatch(r"%s(\.\d+)*" % re.escape(str(build)), d) and maps(d)
    )
    roots.append(maps(versioned[-1]) if versioned else maps())
    return [r for r in roots if r]


def find_workshop_maps(install, build, say):
    """Map folders shipped by the downloaded Workshop mods, copied into the install's media/maps
    when it does not have them. Returns the names in the order found."""
    content = os.path.join(install, "steamapps", "workshop", "content", "108600")
    maps_dir = os.path.join(install, "media", "maps")
    found = []
    if not os.path.isdir(content):
        return found
    for item in sorted(os.listdir(content)):
        mods = os.path.join(content, item, "mods")
        if not os.path.isdir(mods):
            continue
        for mod in sorted(os.listdir(mods)):
            for root in map_roots(os.path.join(mods, mod), build):
                for name in sorted(os.listdir(root)):
                    src = os.path.join(root, name)
                    if not os.path.isdir(src):
                        continue
                    if name not in found:
                        found.append(name)
                    dst = os.path.join(maps_dir, name)
                    if not os.path.isdir(dst):
                        try:
                            shutil.copytree(src, dst)
                            say("copied map %s from Workshop item %s" % (name, item))
                        except OSError as e:
                            say("WARN could not copy map %s: %s" % (name, e))
    return found


def merge_map_line(current, found):
    """What the ini lists keeps its place, what is new goes after it, and the base map stays
    last. A duplicate is dropped. (Rebuilding the line from the scan lost the owner's order and
    wrote a map twice.)"""
    merged = []

    def add(entry):
        entry = entry.strip()
        if entry and entry != BASE_MAP and entry not in merged:
            merged.append(entry)

    for entry in (current or "").split(";"):
        add(entry)
    for entry in found:
        add(entry)
    return ";".join(merged + [BASE_MAP])


def add_spawn_regions(install, spawn_file, found, say):
    """A map with a spawnpoints.lua gets a line in <name>_spawnregions.lua, once."""
    if not found:
        return
    if not os.path.isfile(spawn_file):
        say("the spawn regions file does not exist yet; the new maps' spawn points are added on the next start")
        return
    lines = read_lines(spawn_file)
    text = "\n".join(lines)
    changed = False
    for name in found:
        if name in text:
            continue
        if not os.path.isfile(os.path.join(install, "media", "maps", name, "spawnpoints.lua")):
            continue
        entry = '\t\t{ name = "%s", file = "media/maps/%s/spawnpoints.lua" },' % (name, name)
        in_fn = False
        for i, line in enumerate(lines):
            if "function SpawnRegions()" in line:
                in_fn = True
            elif in_fn and re.search(r"return\s*{", line):
                lines.insert(i + 1, entry)
                text = "\n".join(lines)
                changed = True
                break
    if changed:
        write_text(spawn_file, "\n".join(lines))
        say("spawn regions added for the new maps")


STATE_FILE = ".flux-env-applied.json"


def digest(value):
    return hashlib.sha256(value.encode("utf-8", errors="surrogateescape")).hexdigest()[:16]


def load_state(server_dir):
    try:
        with open(os.path.join(server_dir, STATE_FILE), encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_state(server_dir, state):
    path = os.path.join(server_dir, STATE_FILE)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, sort_keys=True)
    os.replace(tmp, path)


def apply_env_settings(ini, server_dir, pairs, say):
    """Write a setting from the environment into the ini ONLY WHEN THE ENVIRONMENT CHANGED since it
    was last written, and leave the ini alone otherwise.

    The image this replaces wrote every one of these on every start, so a name, a password or the
    visibility changed in the ini (the dashboard's Server Settings tab, or an admin) was put back
    to the spec's value at the next restart, with no error anywhere. Now the later of the two wins:
    an edit in the ini sticks until the spec changes, and a change of the spec lands the next start.
    The record is a hash per key, in the SYNCED data volume next to the ini, so a standby that takes
    over knows what was already applied. A server with no record applies everything, as before.
    """
    state = load_state(server_dir)
    changed = False
    for key, value in pairs:
        marker = digest(value)
        if state.get(key) == marker:
            continue
        set_ini_option(ini, key, value)
        state[key] = marker
        changed = True
        if key != "Password" and key != "RCONPassword":
            say("%s=%s (from the spec)" % (key, value))
        else:
            say("%s set (from the spec)" % key)
    if changed:
        save_state(server_dir, state)


def prepare(env, say):
    install = env.get("FLUX_SERVER_DIR") or "/home/steam/pz-dedicated"
    data = env.get("FLUX_DATA_DIR") or "/home/steam/Zomboid"
    name = env.get("SERVERNAME") or "servertest"
    if not NAME_RE.match(name):
        say("WARN SERVERNAME '%s' is not a plain name; nothing was written" % name)
        return 1
    server_dir = os.path.join(data, "Server")
    ini = os.path.join(server_dir, name + ".ini")
    build = env.get("FLUX_BUILD") or "42"
    if not re.fullmatch(r"\d{2}", build):
        build = "42"

    os.makedirs(server_dir, exist_ok=True)
    # The game only creates the ini on its first boot, and keeps the options already in it, so an
    # empty one makes the settings below apply to a new server's FIRST start, not the second.
    if not os.path.isfile(ini):
        open(ini, "a").close()

    apply_preset(install, server_dir, name, env.get("SERVERPRESET", ""), truthy(env.get("SERVERPRESETREPLACE")), say)

    pairs = []
    if env.get("PASSWORD"):
        pairs.append(("Password", env["PASSWORD"]))
    elif "Password" in load_state(server_dir):
        # The spec had a join password and no longer does: the server is open again. (The panel
        # drops an emptied variable, so "absent" is how "cleared" arrives.)
        pairs.append(("Password", ""))
    if env.get("RCONPASSWORD"):
        pairs.append(("RCONPassword", env["RCONPASSWORD"]))
    if env.get("RCON_PORT"):
        pairs.append(("RCONPort", env["RCON_PORT"]))
    public = str(env.get("PUBLIC", "")).strip().lower()
    if public in ("1", "true"):
        pairs.append(("Public", "true"))
    elif public in ("0", "false"):
        pairs.append(("Public", "false"))
    if env.get("DISPLAYNAME"):
        pairs.append(("PublicName", env["DISPLAYNAME"]))
    if env.get("UDPPORT"):
        pairs.append(("UDPPort", env["UDPPORT"]))
    apply_env_settings(ini, server_dir, pairs, say)

    if truthy(env.get("SELF_MANAGED_MODS")):
        say("SELF_MANAGED_MODS is set: Mods and WorkshopItems stay as they are in the ini")
    else:
        set_ini_option(ini, "Mods", env.get("MOD_IDS", ""))
        set_ini_option(ini, "WorkshopItems", env.get("WORKSHOP_IDS", ""))

    found = find_workshop_maps(install, build, say)
    if found:
        merged = merge_map_line(get_ini_option(ini, "Map"), found)
        set_ini_option(ini, "Map", merged)
        say("Map= now %s" % merged)
        add_spawn_regions(install, os.path.join(server_dir, name + "_spawnregions.lua"), found, say)
    return 0


def main(argv):
    if argv[:1] != ["prepare"]:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 64
    try:
        return prepare(os.environ, lambda m: print(m, flush=True))
    except OSError as e:
        print("WARN could not write the server's settings: %s" % e, flush=True)
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
