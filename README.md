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

### Saves the iPad cannot open, and the tool that fixes them

The Mac build has The Butcher's Circus, the free player-versus-player add-on
that never came to iOS. When it is active the game records a `circus` building
in the estate's Hamlet, and the iPad — which has no such building — crashes
opening the campaign. Red Hook's import article warns that saves carrying
content the iPad lacks "may result in errors"; this is that.

Nothing is wrong with the copying. The bytes reach Dropbox intact. It is the
content the iPad cannot read.

So a Mac save is checked before it is published, and held back if it carries
that content, with the campaign named and the reason given. The panel then
offers **Prepare a copy for the iPad**. Press it and Stagecoach publishes a
copy with two things taken out:

- the Circus building in the Hamlet, and
- the note that the game once advertised the Butcher's Circus to you.

Everything else is carried through byte for byte, the campaign's own add-ons
included — Crimson Court, Shieldbreaker, Colour of Madness are all sold for the
iPad and stay switched on. The Steam save is never touched; it keeps its
Circus. Nothing is published unless the finished copy reads back as the same
save and no longer carries anything known to crash the iPad.

The button is yours to press. It never runs on its own, because it produces a
save that is deliberately not what the Mac holds.

**Better still, don't enable it.** In Steam, right-click Darkest Dungeon →
Properties → DLC and uncheck The Butcher's Circus. Campaigns you play after
that stop recording the Circus, and travel to the iPad with no preparation at
all. You lose only the player-versus-player mode, which the iPad never had.

One thing preparing cannot change: which add-ons a campaign uses is fixed when
the campaign is created and cannot be switched off afterwards, on any platform.
That is the game's own rule, not the Butcher's Circus, and it is why an
imported campaign shows its add-ons locked on the iPad.

What it cannot see:What it cannot see: whether you actually ran Import on the iPad before playing
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
stagecoach-cli codec-check [dir]             read and rewrite every save under a folder, byte for byte
stagecoach-cli prepare profile_N             publish a copy of a Mac campaign the iPad can open
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
