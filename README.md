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

### The two edits that let the iPad open a Mac campaign

The iPad runs a build of the game from 2019; Steam's is thousands of builds
newer. Almost none of that matters. Two things do, and a copy is published with
both of them changed and nothing else.

The first is in the campaign log. Each chapter holds numbered entries, one per
thing worth recording about that week, and the newer build writes an extra entry
carrying a record the iPad's build has never written. Faced with it, the iPad
refuses the campaign. Removing the record on its own is not enough — the entry
stays behind holding only its type marker — so the entry goes whole and the
entries beside it are renumbered.

The second is smaller. The save keeps a record of which add-ons the game has
shown you, and on a Mac that list names The Butcher's Circus, which never came
to iOS. Taking that one entry out stops the iPad asking about add-ons it cannot
provide.

Nothing else is touched, and the Steam saves are never written to.

**How this was found**, since it took a long time and almost every theory along
the way was wrong. Two experiments settled it, neither of them clever. Playing a
single week on a campaign the iPad had written produced a save that broke from
one known action, which gave a before and an after differing by one week instead
of two unrelated campaigns to compare. Then playing that same week on the iPad
produced the chapter to hold the Mac's against. The two differed by three fields.

Things that were suspected at length and are **not** the problem: the Butcher's
Circus building in the Hamlet, the add-on currencies and trinkets in the estate,
the quests and narration mentioning add-on content, the per-hero fields the
newer build adds, the upgrade trees the iPad does not know, and the build number
stamped into each file. A campaign carrying every one of those opens on the iPad
once the two edits above are made.

A campaign is never held back, either. One asking for add-ons the iPad has not
got still opens there: the game offers to take that content out, and does. The
app says so once and publishes anyway.

What it cannot see:What it cannot see:What it cannot see:What it cannot see: whether you actually ran Import on the iPad before playing
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
