# Stagecoach

A menu-bar app that keeps one Darkest Dungeon campaign moving between Steam on
this Mac and the iPad version, by way of the Dropbox folder the iPad's
Import/Export uses. Nothing to copy by hand.

## What it does

The iPad game reads and writes `Dropbox/Apps/DarkestDungeon`:

- **Export** on the iPad drops a folder named `<date>_<time>_upload/profile_N/`.
- **Import** on the iPad lists the `profile_N/` folders sitting directly in
  `Apps/DarkestDungeon` — and hangs forever if an `_upload` folder is left
  there (Red Hook's own support article says so).

Steam keeps the Mac's saves in
`~/Library/Application Support/Steam/userdata/<id>/262060/remote/profile_N/`
and mirrors that folder to Steam Cloud.

Stagecoach watches both places:

- **iPad → Mac.** A new export appears → once Dropbox has finished downloading
  it, the profile goes into the Steam folder. If Steam is running, it is
  written *through the Steam client* (Steamworks remote storage), so Steam
  Cloud is updated immediately — no game launch needed. If Steam isn't
  running, the files are copied in place and Steam Cloud picks them up at the
  next launch. The Mac save that gets replaced is backed up first. The export
  folder is then moved to `Dropbox/Darkest Dungeon Save Sync/Imported
  exports/`, so the iPad's Import keeps working.
- **Mac → iPad.** The Mac game saves → once the burst of writes is over, the
  profile is copied to `Apps/DarkestDungeon/profile_N/`. On the iPad, tap the
  Dropbox icon → Import → pick the campaign → Copy.

Both campaign slots (`profile_0`, `profile_1`, …) are handled; the game's own
`backup/` subfolder is left alone.

### When both sides have new progress

The app remembers, per slot, the state both sides last agreed on. If an export
arrives and the Mac save has changed since then — or the export is older than
the save the Mac already had — it doesn't guess. The menu-bar icon turns into a
warning sign and the panel offers **Keep the iPad save** / **Keep the Mac
save**. Whichever loses is still in the backups folder.

On the very first run there is no history yet, so the newer of the two wins
and the log says which.

What it cannot see: whether you actually ran Import on the iPad before playing
there. If you export from the iPad without having imported the latest Mac
save, the Mac's progress is replaced (and backed up), the same as it would be
by hand. Also, merely opening a campaign on the Mac rewrites a few save files,
which counts as "the Mac changed" — expect a prompt in that case and pick the
iPad.

## Build

Command Line Tools only:

```bash
./build.sh
```

That produces `build/Stagecoach.app` and `build/stagecoach-cli`. Move the app
to `/Applications` if you like and turn on **Launch at login** in its settings.
The engine tests run with `./run_tests.sh`.

## The command-line helper

```
stagecoach-cli scan                          detected folders, each side's state, the ledger
stagecoach-cli steam-check                   open a Steam session as Darkest Dungeon, list cloud files
stagecoach-cli steam-write-test              read steam_init.json from the cloud, write it back unchanged
stagecoach-cli steam-push profile_N [dir]    write a profile folder to Steam Cloud through the client
stagecoach-cli sync                          one sync pass with the real folders
```

## How the Steam Cloud push works

Steam has no public way to upload a file into a game's cloud storage, but the
Steamworks runtime (`libsteam_api.dylib`) lets any process that owns the game
initialise as that game and call the remote-storage API. Stagecoach borrows
that dylib from an installed Steam game (any arm64 copy under
`steamapps/common`; it looks for one and checks it can be loaded), sets
`SteamAppId=262060`, writes the files, and shuts the session down. For the few
seconds the session is open, Steam shows the account as playing Darkest
Dungeon. You can point Settings at a specific dylib, or drop one at
`~/Library/Application Support/Stagecoach/libsteam_api.dylib`.

The app never opens a Steam session while the game itself is running, and it
never writes into the Steam folder while the game runs: an import waits until
the game quits.

## Where things are

- Ledger and log: `~/Library/Application Support/Stagecoach/`
- Backups of replaced Mac saves: `~/Library/Application Support/Stagecoach/Backups/<timestamp>/profile_N/` (thirty newest kept)
- Consumed iPad exports: `Dropbox/Darkest Dungeon Save Sync/Imported exports/`
