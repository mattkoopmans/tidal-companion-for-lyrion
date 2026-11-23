# Tidal Companion for Lyrion

A plugin for [Lyrion Music Server](https://lyrion.org) that works alongside the
TIDAL plugin and Lyrion's online music library integration.

## What it does

1. **Plays lossy albums in lossless.** When an album in your library is lossy
   (MP3, AAC, Musepack and so on) and the same album is also in the library
   from your Tidal favorites, the lossless Tidal tracks play instead. This
   happens however the tracks are played: the album, a single track, an
   artist, a playlist or a mix. The album's menu says "Plays in lossless from
   Tidal".
2. **Finds lossy albums on Tidal.** A lossy album with no Tidal copy in the
   library gets "Find the lossless version on Tidal" in its menu. Pick the
   right result and add it to your Tidal favorites.
3. **Adds an artist's missing albums.** "Add missing albums from Tidal" in an
   artist's menu lists the albums Tidal has that your library doesn't, with
   "Add all" at the top.
4. **Adds new releases during library scans.** Each library scan (and each
   automatic online library update) checks every album artist in your library
   on Tidal and adds albums that have come out since the last check to your
   Tidal favorites, so they appear in the library in the same scan. The first
   scan only notes what each artist already has. Each artist is checked at
   most once every 20 hours.

Albums added to Tidal favorites appear in the library after Lyrion's online
library update, which Tidal Companion starts for you.

### Same album, different version

Versions of an album count as the same album. Version information in titles
is ignored, such as "(2011 Remaster)", "[Deluxe Edition]", "- Remastered 2009",
"(Expanded)" or "(1999)". Live albums are different albums. When Tidal has
several versions of a missing album, the version with the most tracks is
added. Only albums Tidal offers in lossless quality are considered, and only
albums (not EPs, singles or compilations).

Artist names are compared ignoring case, accents, spacing and a leading "The".
An artist found on Tidal by name is only used if Tidal lists at least one of
the albums already in your library, so a namesake isn't mistaken for them.

## Requirements

- Lyrion Music Server 9.0 or later
- The TIDAL plugin, signed in to an account
- Lyrion's Online Music Library Integration plugin turned on, with TIDAL
  ticked in its settings

## Settings

Settings > Advanced > Tidal Companion:

- **Play lossless from Tidal** (on by default)
- **Add new releases during library scans** (on by default)

What the scan has noted for each artist is kept in `tidalcompanion.json` in
Lyrion's cache folder. Deleting it makes the next scan start afresh (noting,
not adding).

## Installing

In Lyrion, go to Settings > Manage Plugins, add this repository URL at the
bottom of the page, then install Tidal Companion:

    https://raw.githubusercontent.com/mattkoopmans/tidal-companion-for-lyrion/main/repo.xml

## Development

Tests: `prove t/`

Releases: bump `<version>` in `TidalCompanion/install.xml`, commit, push, then
tag `vX.Y.Z` and push the tag. The release workflow runs the tests, publishes
the zip and updates `repo.xml`. Tags on the `Testing` branch update
`repo-testing.xml` instead.

## License

GPL-3.0, see LICENSE.
