# Local custom test chambers and Community Test Chambers

## What is implemented

Compiled Portal 2 chambers you already have (`.bsp`, VBSP version 21) can be installed locally and
started with `+map custom/<name>`. Nothing goes through Steam. Status: the import, validation and
launch-file handling are host-tested. The parser accepts all 106 owned retail maps. Loading a map
from `maps/custom/` in the running engine has not been observed on this runtime yet.

- Location: `<game>/portal2/maps/custom/<name>.bsp`, where `<game>` is the folder given to the
  engine with `--game-dir` (`Documents/game` on iOS and visionOS). The original gameinfo mounts
  `portal2/` (`Game |gameinfo_path|.`), so the engine finds the map there. No search path, VPK,
  save or campaign file is changed.
- Self-contained maps work as they are: content packed into the BSP pakfile is used, and that
  includes chambers made with the in-game editor, which use only stock assets. A map that needs
  loose files must ship them in a package (see below).
- Names: `a-z`, `0-9`, `_`, `-`, at most 64 characters. Custom maps live in their own folder, so a
  custom map never replaces a campaign map, even one with the same name.

## Tools

Host (Mac), for a content root that is later copied to a device or simulator container:

```sh
python3 tools/custom_levels.py check chamber.bsp
python3 tools/custom_levels.py import --game-dir <root>/game chamber.bsp [--name NAME] [--replace]
python3 tools/custom_levels.py import --game-dir <root>/game chamber-pack.zip   # or a folder
python3 tools/custom_levels.py list   --game-dir <root>/game
python3 tools/custom_levels.py remove --game-dir <root>/game NAME
python3 tools/custom_levels.py launch --documents <root> --game-dir <root>/game NAME
python3 tools/custom_levels.py clear  --documents <root>
```

A package (folder or zip, with an optional single wrapper folder or `portal2/` prefix) holds
`maps/*.bsp` plus optional companion files under `materials/ models/ sound/ scripts/ particles/
resource/`, limited to asset extensions. Every other file is listed as ignored (cfg files, for
example). A companion file is refused if it would replace or shadow any original file: an entry
in any `game/*/pak01_dir.vpk`, or a loose file already on disk with different content. Each import
records `maps/custom/<name>.files.json`. `remove` deletes only files that import created, and
keeps any file that was edited since or is shared with another package. Archive paths with `..`,
absolute paths, backslashes, symlinks (in zips or folders), duplicates, encrypted entries and
members larger than declared are refused. When an import fails, it rolls back the files it wrote.

Runtime (C, linked into the iOS and visionOS apps through `runtime/*.c`): `runtime/custom_levels.h`
provides `p2cl_inspect_bsp`, `p2cl_install`, `p2cl_list`, `p2cl_remove`, `p2cl_request_launch` and
`p2cl_clear_launch`. All of them use the same rules and refuse symlinks at every path component.

## Starting a custom map

Both mobile launchers already append `Documents/launch.args`, one argument per line, to the engine
command line. `launch` and `p2cl_request_launch` add a delimited block at the end of that file:

```
# p2-custom-level begin: one-shot, removed by the launcher after start
+map
custom/<name>
# p2-custom-level end
```

All other lines are kept. `clear` and `p2cl_clear_launch` remove only this block. The block is
meant to be one-shot. Until a launcher calls `p2cl_clear_launch` right after reading `launch.args`,
the map loads at every launch until you clear the block. Arguments are read only when the engine
starts, so changing maps from the launcher requires an engine start.

On iOS, Documents is visible in the Files app (`UIFileSharingEnabled`), so a `.bsp` can be placed
into `game/portal2/maps/custom/` by hand. visionOS has no Files sharing. Use a device or simulator
copy of a content root prepared with the tool, or a future launcher import button.

## Community Test Chambers menu (Steam Workshop)

The Workshop is not available offline. The crash when that menu was selected came from
`client.so`: `CBaseModPanel` enumerates Workshop chambers through
`ISteamRemoteStorage016::EnumeratePublishedWorkshopFiles` (vtable slot 53, call site
`0x1613f515`, tags `Singleplayer`/`Cooperative`, 7 days, up to 50 results). The Steam bridge had
no marshalling for `SteamParamStringArray_t`, so that slot hit `rt_trap`, which aborts.
`runtime/steam_workshop.c` now marshals the three RemoteStorage016 string-array methods
(`EnumeratePublishedWorkshopFiles`, `EnumerateUserSharedWorkshopFiles`,
`UpdatePublishedFileTags`).

- Mac (real Steam client): the call reaches Steam unchanged. What Steam returns for this
  deprecated API was not measured.
- iOS and visionOS (offline stub): the stub returns `k_uAPICallInvalid` (or `false`) and logs
  `[steam-stub] Workshop indisponible hors ligne` once. The guest code tests the handle, sets its
  failure flag and returns without registering a call result. No subscription, download, vote or
  cloud state is simulated.

The fix removes the known abort. How the menu looks after the guest's own failure path (empty
list, message or spinner), and whether later Workshop calls in the same menu reach other
unbridged code, has not been observed on a device or simulator.

## In-game chamber editor (Puzzle Maker)

The editor is not supported, and local custom-map play does not show that it works. To build a
chamber, the game runs the Linux map compilers (`bin/linux32/vbsp_linux`, `vvis_linux`,
`vrad_linux`) as child processes. On iOS and visionOS, child processes are unavailable (`system`
returns `ENOSYS`, `fork` is denied by the sandbox). On the Mac, `execvp` of a Linux ELF fails with
`ENOEXEC`. These tools are not translated. Publishing would also need the Workshop. Whether the
editor even opens on this runtime has not been tested.
