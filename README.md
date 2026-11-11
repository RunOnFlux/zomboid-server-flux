# zomboid-server-flux

Project Zomboid dedicated server for [Flux](https://runonflux.com): `runonflux/zomboid-server-flux`.
One image for Build 42 and Build 41, with the game installed by SteamCMD on the install volume
instead of baked in. Tags: `:b42` (also `:latest`) installs the `public` branch, `:b41` the `legacy41`
branch; they are the same image apart from that default, and a `STEAMAPPBRANCH` in the spec wins
(a versioned branch such as `42.19` pins an older Build 42).

It replaces `danixu86/project-zomboid-dedicated-server` on Flux, whose scripts it is a rewrite of
(GPL-3, see `LICENSE`; thank you Danixu). The environment variables are the same on purpose, so a
server's spec and its data volume move over as they are. What changed, and why:

| | the image it replaces | this image |
|---|---|---|
| Game | baked in, one image per version | installed on start into the install volume |
| Build | the image tag (`42.20.4-release`) | the Steam branch: `public` (Build 42), `legacy41` (Build 41), or a versioned one (`42.19`) to pin; the image tag `:b42`/`:b41` sets the default |
| Build 41 | stopped at 41.78.19 when Build 42 went stable (Steam's is 41.78.21) | installed from `legacy41`, always current |
| Game update | a new image, rolled out by FluxOS as a redeploy | the server notices (Steam, every 10 minutes), warns in game, saves and restarts onto it |
| Scheduled restart | none | `FLUX_RESTART_TIME` + `TZ`, with a warning in game |
| Stop | `quit` on the console, then Docker's 10 s race | the same, but ended at the game's own "saved, waiting" line: 9 s measured, exit 0 |
| A preset the build lacks | `exit 1`, the container never boots | warns, starts on Apocalypse (an existing world's sandbox file is never touched) |
| A setting from the spec (name, password, visibility) | written to the ini on every start, so an edit in the ini was put back | written only when the spec changed (a hash per key in `Server/.flux-env-applied.json`, on the synced volume): the later of the two wins |
| Root-owned files in the data volume | the server fails ("database is corrupt") | fixed before every start |
| Java heap with no `MEMORY` | the JVM's own (a quarter of the NODE's RAM) | 75% of the container's memory |

## Files

- `scripts/flux-entrypoint.sh`: PID 1. Per generation: SteamCMD, `flux-config.py`, then the game as
  the `steam` user, a child of the supervisor.
- `scripts/flux-config.py`: writes the ini and the sandbox file from the environment, merges the
  maps Workshop mods ship into `Map=`, registers their spawn points.
- `scripts/flux-updatewatch.sh`, `flux-scheduler.sh`, `flux-restart.sh`: the update watch, the daily
  restart, and the warn-save-quit they share.
- `scripts/flux-steam.py`: the build id Steam lists for a branch.
- `scripts/flux-console.sh`, `flux-version.sh`: `flux-console servermsg "hi"` and `flux-version`
  (`{"branch","build","version"}`, what the dashboard reads over appexec).
- `tests/test-flux.sh` unit tests; `tests/test-image.sh` runs the scripts inside the built image.

## Environment

The game's own (unchanged from the image this replaces): `SERVERNAME` (default `servertest`; the
name of the ini and the world), `DISPLAYNAME` (browser name), `SERVERPRESET` (+ `SERVERPRESETREPLACE`),
`ADMINUSERNAME`, `ADMINPASSWORD`, `PASSWORD`, `RCONPASSWORD`, `PUBLIC`, `MEMORY` (or
`MIN_MEMORY`/`MAX_MEMORY`), `PORT` (game port, `-port`), `UDPPORT` (second port, ini `UDPPort`),
`STEAMVAC`, `STEAMPORT1/2`, `IP`, `COOP`, `NOSTEAM`, `DEBUG`, `SOFTRESET`, `CACHEDIR`, `MODFOLDERS`,
`SELF_MANAGED_MODS` (true: `Mods` and `WorkshopItems` stay as they are in the ini, which is what the
dashboard edits; false: written from `MOD_IDS` and `WORKSHOP_IDS`), `FORCESTEAMCLIENTSOUPDATE`.

Ours: `STEAMAPPBRANCH` (also `STEAM_BRANCH`; default from the image tag), `RCON_PORT` (ini `RCONPort`, default 27015),
`FLUX_RESTART_TIME` (`HH:MM`, empty = no daily restart), `TZ`, `FLUX_RESTART_WARN_MINUTES`,
`FLUX_AUTO_UPDATE` (on unless `false`), `FLUX_UPDATE_CHECK_MINUTES`, `FLUX_UPDATE_WARN_MINUTES`,
`SKIP_UPDATE` (start the installed build as it is), `FLUX_STOP_GRACE`,
`FLUX_RESTART_MAX_ATTEMPTS`/`FLUX_RESTART_WINDOW` (unplanned restarts before the container ends with 42).

## App spec

```
containerData: g:/home/steam/Zomboid|ml:server:/home/steam/pz-dedicated
```

- `g:` the world, the ini, the sandbox options, the database: synced. Same path as the old image.
- `ml:server` the install **and the Workshop downloads** (`steamapps/workshop` is inside it). Local,
  never synced, disposable: an empty one is filled from Steam on the next start. About 7 GB.

Ports: the game port, the second UDP port, RCON (TCP). Set `PORT` and `UDPPORT` to the numbers the
spec publishes: the server announces the port it is BOUND to to Steam and to clients, so a server
published on 41261 must bind 41261. RCON can stay on 27015 inside whatever it is published as.

## Notes

- Measured on build 26486687 (42.22.2): first install 7.2 GB (~4 min), a start on an installed
  build 15-35 s before the game, stop 9.0 s, A2S answers on the game port.
- The first `steamcmd` attempt on a new install often fails with `Missing configuration`; the
  supervisor retries (with `validate`) and the second one works.
- The game writes `backups/` (a zip of the whole world on every start) and `Logs/` on the data
  volume itself; they are not ours to prune here.

## Versions

- **1.0.0**: first version.
