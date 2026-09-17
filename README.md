# Stagecoach

[![Latest release](https://img.shields.io/github/v/release/bentolanh/darkest-dungeon-save-sync)](https://github.com/bentolanh/darkest-dungeon-save-sync/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

Keeps one Darkest Dungeon campaign moving between Steam on a Mac and the iPad
version, through the Dropbox folder the iPad's Import and Export use.

The iPad can import and export saves through Dropbox, but doing it by hand is
fiddly: the folders have to be arranged a particular way, an export left in the
wrong place makes the next import hang forever, and a Mac save needs two small
edits before the iPad will open it at all. Stagecoach sits in the menu bar and
does that, both directions, without being asked.

---

## What you need

- **macOS 15 or later.**
- **Darkest Dungeon, played at least once on this Mac.** Launching it is what
  makes Steam create the save folder. You do not need to start a campaign — an
  iPad save will land in the first free slot.
- **Dropbox**, with an `Apps/DarkestDungeon` folder. The iPad creates it: tap
  the Dropbox icon on the game's main menu, choose Import, sign in, then close
  the dialogue. The folder appears and Stagecoach finds it on its own.
- **For Steam Cloud only**: Steam running, and any installed Steam game to
  borrow a Steamworks library from. Without these, syncing to the iPad still
  works; only the hop to your other Steam machines waits.

## Installing it

Download `Stagecoach.app.zip` from the
[latest release](https://github.com/bentolanh/darkest-dungeon-save-sync/releases/latest),
unzip it, and move **Stagecoach** to your Applications folder.

The first time you open it, macOS will refuse: the app is signed ad hoc rather
than by a paid Apple developer account, and anything downloaded is quarantined.
Either is enough to get past it:

- **Right-click the app and choose Open**, then Open again in the dialogue. You
  only do this once.
- Or, in a terminal: `xattr -d com.apple.quarantine /Applications/Stagecoach.app`

If you would rather not run an unsigned binary, build it yourself — it takes
about a minute and needs nothing but Apple's own tools.

## Building it

Needs the Xcode Command Line Tools (`xcode-select --install`) and nothing else.

```bash
./build.sh
```

That produces `build/Stagecoach.app` and `build/stagecoach-cli`. Move the app to
`/Applications` and turn on **Launch at login** in its settings.

Run the tests with `./run_tests.sh`.

## Setting it up

There is no setup. All three folders are found without being told: the Steam
save folder by looking through the accounts that have used this Mac, Dropbox by
reading Dropbox's own record of where it keeps itself, and the Steamworks
library by finding a copy inside an installed game that this Mac can run.
Settings lets you point at any of them if yours is somewhere unusual.

---

## Using it

**Playing on the Mac.** Quit the game. Within a few seconds the campaign is
copied to Dropbox. On the iPad: Dropbox icon → Import → pick the campaign →
Copy.

**Playing on the iPad.** Export to Dropbox when you stop. Stagecoach waits for
Dropbox to finish downloading, backs up the Mac save it is about to replace,
writes the new one, and pushes it to Steam Cloud. It then moves the export
folder aside, because the iPad's Import hangs if one is left there.

Two habits make this reliable: **export when you stop playing on the iPad**, and
**import before you start**. This Mac only ever hears from the iPad when an
export arrives, so the panel says when that last was and leaves the judgement to
you.

### The panel

Click the wheel in the menu bar.

| Campaign | Week | Mac saved | Ready to import | Steam Cloud |
|---|---|---|---|---|

**Week** is the same number the iPad's import list shows, so the two can be read
against each other. **Ready to import** says *yes* only once Dropbox has
finished uploading, not merely when the file was written.

### When it needs you

A card appears above the table. There are three kinds.

A campaign using add-ons the iPad has not got gets a grey note. It still goes
over; the iPad offers to take that content out of its own copy, and the Mac save
is untouched either way.

If both sides have moved on since they last agreed, an orange card names both
dates and offers **Keep the iPad save** or **Keep the Mac save**. Nothing is
overwritten until you choose, and whichever loses is in the backups folder.

If an export comes back with its add-on content stripped, it stops and asks
rather than carrying that loss onto the Mac.

### What it will not do

It never writes into the Steam folder while the game is running; an import waits
until you quit. It never touches an export Dropbox has not finished downloading.
And it never writes to your Steam saves except when importing, which is backed
up first.

---

## Two campaigns, and which is further on

Campaigns are matched by estate name, not by slot number, because the iPad puts
every imported campaign in a fresh slot and exports every slot it has. An export
holding three copies of one estate collapses to one.

Which copy is further on is decided by **weeks played**, read from the campaign
log, then by whether the party is **out on an expedition** rather than back in
the Hamlet, and only then by the clock. A timestamp says when a file was
written, which is not the same thing: opening a campaign and leaving again makes
it the newer save while holding less play.

## The two edits

A Mac campaign needs two changes before the iPad will open it. Both are made on
the published copy; the Steam save is never altered.

1. **A record in the campaign log.** Each chapter holds numbered entries, and the
   newer build writes an extra one the iPad's build has never written. The whole
   entry comes out — removing just the field leaves it behind holding its type
   marker, which the iPad refuses just the same.
2. **The Butcher's Circus** in the record of add-ons the game has shown you. It
   never came to iOS, and its presence makes the iPad ask about add-ons it cannot
   provide.

Nothing else is changed. Things that look like they should matter and do not:
the Circus building in the Hamlet, the add-on currencies and trinkets in the
estate, the per-hero fields the newer build adds, the upgrade trees the iPad does
not know, and the build number stamped into each file.

Every rewritten file is checked three ways before publishing: it must read back
as the same bytes, its object tree must agree with itself, and every value must
stand on the four-byte boundary it stood on before. Three separate faults were
caught only by the second and third of those, each a number written into the file
that nothing read back.

## The command line

`stagecoach-cli` does the same work without the menu bar.

```
scan                          what was found, and the state of each side
prepare profile_N [--as slot] [--rename name]
                              publish a copy of one campaign
rename <dir> <name>           rename an estate in place
add-ons <dir>                 which add-ons a campaign uses and has been shown
codec-check <dir>             read and verify every save file under a folder
steam-check                   open a Steam session and list the cloud files
steam-push profile_N          write a campaign to Steam Cloud
steam-forget profile_N        remove a campaign from Steam Cloud
sync                          one pass with the real folders
```

## Where things are

- Ledger and log: `~/Library/Application Support/Stagecoach/`
- Backups of replaced saves: `~/Library/Application Support/Stagecoach/Backups/`
- Consumed iPad exports: `Dropbox/Darkest Dungeon Save Sync/Imported exports/`

## Limits worth knowing

Steam Cloud needs the Steam client running; nothing can be written to it
otherwise. A save imported while Steam is closed waits, and is sent when Steam
next appears. There is a setting to open Steam for that errand and close it
again.

The app cannot see the iPad. It learns what is there only when an export
arrives, and it cannot tidy the duplicate slots the iPad's Import leaves behind.
Deleting the old slot after importing is yours to do.

Playing on the iPad without importing first, and without exporting afterwards,
leaves progress nothing else knows about. Exporting when you stop closes that.

## Licence

MIT. See [LICENSE](LICENSE).
