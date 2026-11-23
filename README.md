# TIDAL Companion for Lyrion

A plugin for [Lyrion Music Server](https://lyrion.org) that works alongside the
TIDAL plugin and Lyrion's online music library integration.

## What it does

1. **Plays lossy albums in lossless.** When an album in your library is lossy
   (MP3, AAC, Musepack and so on) and the same album is also in the library
   from your TIDAL favorites, the lossless TIDAL tracks play instead. This
   happens however the tracks are played: the album, a single track, an
   artist, a playlist or a mix. The album's menu says "Plays in lossless from
   TIDAL".
   **Hiding the lossy copy:** choose the library view "Without lossy
   duplicates" as a player's library (in Material Skin, through the library
   choice when browsing). It is your whole
   library minus each lossy album that has a lossless TIDAL copy, so you only
   see the TIDAL album. Its menu says "Your lossy copy (MP3) plays as this
   album and is hidden". The view is rebuilt after every library scan.
2. **Finds lossy albums on TIDAL.** A lossy album with no TIDAL copy in the
   library gets "Find the lossless version on TIDAL" in its menu. Pick the
   right result and add it to your TIDAL favorites.
3. **Adds an artist's missing albums.** "Add missing albums from TIDAL" in an
   artist's menu lists the albums TIDAL has that your library doesn't, with
   "Add all" at the top. Albums already in your TIDAL favorites aren't listed.
4. **Adds new releases during library scans.** Each library scan (and each
   automatic online library update) checks every album artist in your library
   on TIDAL and adds albums that have come out since the last check to your
   TIDAL favorites, so they appear in the library in the same scan. The first
   scan only notes what each artist already has. Each artist is checked at
   most once every 20 hours. An album isn't added if any version of it is
   already in the library or in your TIDAL favorites (favorites that haven't
   been imported yet count too). If your favorites can't be read, the scan
   step is skipped that time rather than risk adding duplicates.

Albums added to TIDAL favorites appear in the library after Lyrion's online
library update, which TIDAL Companion starts for you.

### Same album, different version

Versions of an album count as the same album. Version information in titles
is ignored, such as "(2011 Remaster)", "[Deluxe Edition]", "- Remastered 2009",
"(Expanded)" or "(1999)". Live albums are different albums. When TIDAL has
several versions of a missing album, the version with the most tracks is
added. Only albums TIDAL offers in lossless quality are considered, and only
albums (not EPs, singles or compilations).

Artist names are compared ignoring case, accents, spacing and a leading "The".
An artist found on TIDAL by name is only used if TIDAL lists at least one of
the albums already in your library, so a namesake isn't mistaken for them.

## Requirements

- Lyrion Music Server 9.0 or later
- The TIDAL plugin, signed in to an account
- Lyrion's Online Music Library Integration plugin turned on, with TIDAL
  ticked in its settings

## Settings

Settings > Advanced > TIDAL Companion:

- **Play lossless from TIDAL** (on by default)
- **Add new releases during library scans** (on by default)

What the scan has noted for each artist is kept in `tidalcompanion.json` in
Lyrion's cache folder. Deleting it makes the next scan start afresh (noting,
not adding).

## Installing

In Lyrion, go to Settings > Manage Plugins, add this repository URL at the
bottom of the page, then install TIDAL Companion:

    https://raw.githubusercontent.com/mattkoopmans/tidal-companion-for-lyrion/main/repo.xml

## Development

Tests: `prove t/`

Releases: bump `<version>` in `TidalCompanion/install.xml`, commit, push, then
tag `vX.Y.Z` and push the tag. The release workflow runs the tests, publishes
the zip and updates `repo.xml`. Tags on the `Testing` branch update
`repo-testing.xml` instead.

## License

GPL-3.0, see LICENSE.
