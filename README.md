# grimmory.koplugin

> [!WARNING]
> This is ALPHA software and WILL have bugs or other inadvertent behaviors.
> 
> Beware, that makes you an ALPHA tester.  This software may require you to
> erase data on your device, or on your Grimmory server.
>
> Please report any bugs or issues.

Read your books from Grimmory, sync your shelves, and track reading
progress automatically.

## Installation

Download the [latest release][latest-plugin] file and extract it to
your KOReader plugin folder.  Then, restart KOReader.

The Grimmory plugin is under "Tools" (🛠️) for configuration.

## Browsing the library

**Tools** -> **Grimmory** -> **Browse Library** (or the gesture action
"Grimmory: Browse Library") opens your Grimmory library:

- **Tabs**: Home, Books, Series, Shelves (including magic shelves) and
  Libraries, one tap apart in the top bar.  Home shows "Continue Reading",
  "Recently Added" and the shelves, libraries and series the sync downloads.
  "‹" goes back (on a tab it closes the library); "⋯" switches between cover
  grid and cover list, refreshes and closes.
- **Covers**: books are shown as a cover list or a cover grid (the choice is
  remembered).  Covers load in the background and are kept on the device.
- **Book page**: tap a book for its cover, details and description, and read
  it with one tap ("Download & read").  Books downloaded here stay on the
  device and are synced.
- **Hold** a book for its actions (read, download, details, series, delete),
  or a series, shelf or library for its download settings.
- **Search** books (or series, in the Series tab) with the magnifier.
- **Download with automatic sync**: tick it inside a shelf, library or series
  (or hold its entry) to let the sync download its books.
- **Smart download**: tick it inside a series to keep its next volumes on
  the device (see below).

The browser and the plugin's dialogs follow the look of
[SimpleUI](https://github.com/doctorhetfield-cmd/simpleui.koplugin) 3.  With
SimpleUI installed, the dialogs are SimpleUI's own action sheets; without it,
KOReader's dialogs with the same choices.

Each page is loaded with exactly the books it shows, and loaded pages are
kept for 10 minutes ("⋯" -> Refresh reloads).  A book downloaded here
opens where it was left on the server, also when it was read in Grimmory's
own reader.  The browser needs a
Grimmory version with the app API (`/api/v1/app`).

## Menu

- **What to Sync**: reading progress, sessions, annotations, book information,
  shelves
- **When to Sync**: opening / closing a book, wake, suspend, power off,
  periodically
- **Downloads**: download sources (everything, or chosen shelves, libraries,
  magic shelves and series), smart download for series, download folder,
  deleting removed books
- **Library Browser**: cover grid or list, clearing the browser's cache
- **Network**: turning WiFi on when needed

## Book information from Grimmory

Title, authors, series and number, language, tags (Grimmory's categories and
tags) and the description are taken from Grimmory and shown in KOReader
instead of what the file says, e.g. for comics without metadata or books with
wrong metadata.  They are written as the book's custom metadata, as when
editing them in KOReader's **Book information** (marked with a pencil there,
and each can be reset there).  Grimmory's values win: edit metadata in
Grimmory.

Every sync updates the books on the device; "Sync with Grimmory" and "Reload
from Grimmory" in a book's menu also update the description (Grimmory's book
lists do not include it) and say what changed.  Turn it off under **What to
Sync** -> **Book Information**.

## Smart download for series

**Downloads** -> **Smart Download for Series** keeps the volume being read
and the next unread volumes of a series on the device.  With volumes 1–5
finished and volume 6 being read, it downloads volume 6 and, by default,
volume 7 (one book ahead) or volumes 7–9 for comics and manga (CBZ, CBR, CB7;
three ahead).  Both counts can be changed in the menu.

- **Series Being Read**: every series with a volume marked as reading on the
  server.  Untick "Smart download" in a series to leave it out, or tick it in
  a series not started yet to start with its first volumes.
- **Only Chosen Series**: only series ticked in the library browser.

It runs with every sync and after closing a book of a series.  Volumes it
downloads stay on the device, also when they are not in a download source.

## Updating

Updating can either be done manually by replacing the plugin folder
in KOReader with the [latest release][latest-plugin] or by using the
built-in updater.

The updater may be found at:

**Tools** -> **Grimmory** -> **About Grimmory Sync**

From that menu you may **Check for Updates** and update the plugin
to the latest release.

> [!TIP]
> You must restart KOReader to see the updates apply.

## License

Distributed under the terms of the [AGPL-3.0 License](./LICENSE).

The cloud icons (`icons/cloud_*.svg`) are
[Material Symbols](https://github.com/google/material-design-icons) by Google,
under the [Apache License 2.0](./grimmory.koplugin/icons/LICENSE-material-symbols.txt).

[latest-plugin]: https://github.com/niklas389/grimmory.koplugin/releases/latest/download/grimmory.koplugin.zip
