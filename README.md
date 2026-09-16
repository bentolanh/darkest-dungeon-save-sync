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

### Saves the iPad cannot open, and the tool that tries to fix them

The two games are far apart. Every save carries the build that wrote it, and
Steam's is **27850** while the iPad's is **24774** — the iPad edition was last
given new content in 2019 and last released in 2022. Red Hook's import article
warns that a save carrying content the iPad lacks "may result in errors"; this
is that, several times over.

Two kinds of difference matter:

- **The Butcher's Circus.** The free player-versus-player add-on never came to
  iOS. With it active the game records a `circus` building in the Hamlet, which
  the iPad has no code for.
- **Structures the newer build added.** A save-tampering record in the estate,
  a trinket-feedback log, and five fields on every hero — `added_buffs`,
  `did_transform`, `hero_name`, `previous_trinket_id`, `trinkets_gained_count`
  — in the estate, the quest and the town.

So a Mac save is checked before it is published, held back if it carries the
Circus, and the panel offers **Prepare a copy for the iPad**. That publishes a
copy stamped with the iPad's build, with those structures taken out. The Steam
save is never touched.

Every removal in that list was checked against two saves the iPad wrote itself:
the field appears in the Steam save and nowhere in either iPad save, **in that
file**. The file is the whole point. `hero_name` is new inside the estate but
the iPad has always written it in the campaign log, a hundred times over, and
`heroes` is the iPad's own word in three files. Taking either out everywhere
would have thrown away the campaign's history. Both are left alone where the
iPad uses them.

What is carried through untouched: every hero blob in the roster, byte for
byte, and every name the iPad writes.

A value in these files usually sits on a four-byte boundary, reached by zero
bytes written after the field's name. Those bytes belong to the position rather
than to the value: take a field out, everything after it slides, and padding
that used to align a number aligns nothing. Each field therefore remembers where
its value stood against that boundary, and writing puts it back on the same
footing. Getting this wrong is what made the iPad crash while it was still
reading the folder — the import screen parses every save to build its list, and
one estate file had two hundred values a byte or two off.

Every rewritten file is checked three times before anything is published: it must
read back as the same bytes, and its object tree must agree with itself —
every object's count of what is inside it recomputed from the fields and
compared with what it claims; and every value must stand against a four-byte
boundary where it stood before. The later checks exist because the first is not
enough. A number read wrongly and written back unchanged round-trips perfectly
while describing a tree that no longer exists, and that is what once put a
corrupted copy in front of the iPad.

### A hero is a save file of its own

The roster does not hold heroes as rows. Each one is a whole save file in its
own right, carried inside a field as padding, a four-byte length, and then the
file. Everything the game has ever learned to record about a hero lives in
there — which means it is out of reach of every edit made to the file that
holds it, and a pass over the roster can come away reporting success having
changed nothing that matters.

That is where the last of it was hiding. Every one of the twenty-six heroes on
this Mac carries a `trinketId`; no hero the iPad has written has ever had one.
Eight of them also carry the same five fields the newer build added elsewhere.
Preparing a copy now opens each hero, takes those out, and puts it back with its
length corrected, leaving the hero's name, class and everything else as it was.

### Two lists, not one

A campaign keeps two records of add-ons and they do different jobs. The one at
the save's root says which add-ons the campaign *uses*. A second, `presented_dlc`,
says which the game has already *shown* the player. The second is what tells the
game this save has been reconciled with them, and emptying it makes the game ask
again and then refuse to open the campaign at all — "Required DLC is missing".

The first rule this tool ever had emptied that list, to be rid of a reference to
the Butcher's Circus sitting in it. That was the wrong shape of fix and it
outlived several rounds of looking elsewhere. Only the Butcher's Circus entry
comes out now; everything else the game has shown you stays where it is.

### The add-ons a campaign asks for

This is the one that matters most. A campaign records which add-ons it uses in a
`dlc` object at the save's root, and the iPad shows its activation window for
anything listed there that it does not have. A campaign asking for an add-on the
iPad cannot provide is one it cannot open.

The two sides differ because they were bought separately. On this Mac the
campaign asks for Musketeer, Crimson Court, districts, flagellant, Shieldbreaker
and Colour of Madness. The same campaign on the iPad asks only for Musketeer and
Shieldbreaker. So preparing a copy trims that list to what a save written by the
iPad itself asks for, and renumbers what remains so the entries still run from
zero. The heroes stay: the iPad's own campaign holds three Flagellants while
asking for no Crimson Court, because a hero lives in the roster rather than
behind the list.

**Known remaining difference.** The Mac's sanitarium records a `trinketId` on
each quirk. Neither iPad save has ever written a quirk entry at all, so there
is no evidence about whether its build knows that field. It is left in rather
than guessed at.

**Better still, don't enable it.** In Steam, right-click Darkest Dungeon →
Properties → DLC and uncheck The Butcher's Circus. That removes the first kind
of difference at the source. It does not touch the second.

One thing preparing cannot change: the iPad writes its own `persist.game.json`
when it imports, so nothing in that file survives the trip — which is why
clearing the campaign's add-on list has no effect. And which add-ons a campaign
uses is fixed when the campaign is created, on any platform, which is why an
imported campaign shows them locked.

What it cannot see:What it cannot see:What it cannot see: whether you actually ran Import on the iPad before playing
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
