# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **Docker image repo**, not an application: the Project Zomboid dedicated server for Flux,
`runonflux/zomboid-server-flux`, Build 42 and Build 41 in one image. steamcmd/steamcmd:ubuntu-24 and
a supervisor in bash. Same family as `~/work/rust-server-flux` and `~/work/7dtd-server-flux`; read
them for the patterns this one follows. It replaces `danixu86/project-zomboid-dedicated-server`
(GPL-3, game baked into the image), which existing servers still run until they take the hub's
migration. The environment variables are that image's on purpose.

The rule that shapes everything: **the game is not in the image, and the build is the Steam branch,
not a tag.** SteamCMD installs and updates it on every start; `legacy41` is Build 41. A new image
is a redeploy of every server (FluxOS's image update service), so it is for changes to the scripts
only.

## Commands

```bash
./tests/test-flux.sh
docker build -t zomboid-server-flux:local .
./tests/test-image.sh                    # the scripts INSIDE the built image; CI gates the publish on it
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x scripts/*.sh tests/*.sh tests/image/*.sh
```

A change to what the image does bumps `VERSION` and gets a line under "Versions" in the README.

## Things that will bite you

- **The server's stop is a race with Docker's 10 seconds.** `quit` on the console saves the world
  in 0.3 s, then the game spends 8.3 s on something else before `id_manager_data.bin`, then another
  1.4 s exiting (measured, 42.22.2). The supervisor ends the game at the log line
  `waiting for UdpEngine thread termination` (everything is on disk by then). Anything added to the
  stop path has to fit.
- **The console is a FIFO** (`/tmp/flux/console`) the supervisor holds open read-write. Nothing may
  open it for reading, and a write from another process never blocks only because we hold it.
- **The process is `ProjectZomboid6`** (15-character kernel name): match with `pgrep -f`.
- **steamcmd and the game run as `steam` (uid 1000)**; the supervisor, watchers and tests run as
  root. HOME is `/home/steam` for all of them, so `flux-steam.py` must go through `flux_as_steam`.
- **A preset the build lacks is not fatal here.** The old image did `exit 1`, and the owner saw a
  frozen server. Never bring that back.
- **Workshop downloads live in `<install>/steamapps/workshop`**, inside the `ml:` mount, by design.
- **Sourcing `flux-lib.sh` must stay side-effect free**: the tests source it directly.
- **The unit tests run with the machine's Python, not the image's.** Anything a script newly needs
  gets a check in `tests/image/in-container.sh`.
