# grimmory.koplugin

A [KOReader](https://koreader.rocks) plugin for [Grimmory](https://grimmory.org): browse
and download your Grimmory library on the e-reader, and keep reading progress, reading
sessions, highlights and shelves in sync.

- **Library browser**: Grimmory's books, series, shelves and libraries with covers, search
  and one-tap "Download & read"; also as a tab of SimpleUI's bottom bar.
- **Sync**: reading progress, reading sessions, highlights, book information and the
  "Finished" status; shelves as KOReader collections.
- **Downloads**: the books of chosen shelves, libraries, magic shelves and series, and with
  smart download the next volumes of the series you are reading.
- **Works offline**: what could not be sent is kept on the device and sent later.

## Requirements

- KOReader on an e-reader or desktop.
- A Grimmory server with the app API (`/api/v1/app`).  The plugin turns on Grimmory's
  KOReader sync for your user when needed (reading progress uses it).
- Optional: [SimpleUI](https://github.com/doctorhetfield-cmd/simpleui.koplugin) 3, for its
  look, icons and bottom bar (see [SimpleUI](#simpleui)).

## Installation

1. Download the [latest release][latest-plugin] and extract it into KOReader's `plugins`
   folder (it contains the folder `grimmory.koplugin`).
2. Restart KOReader.
3. Open **Tools** (🛠️) -> **Grimmory** -> **Server Connection**, enter the server address
   (e.g. `https://grimmory.example.com`), your user name and password, tap **Test**, then
   **Apply**.

Then open the library with **Browse Library**, or choose what the sync downloads under
**Downloads** -> **Download Sources**.

## Library browser

**Tools** -> **Grimmory** -> **Browse Library**, the gesture action "Grimmory: Browse
Library" or the Grimmory tab of SimpleUI's bottom bar.

- **Tabs**: Home, Books, Series, Shelves (with magic shelves) and Libraries.  Home shows
  "Continue Reading", "Recently Added" and the shelves, libraries and series the sync
  downloads.  "‹" goes back (on a tab it closes the library); "⋯" switches between cover
  grid and list, selects books to download, refreshes and closes.
- **Book page**: tap a book for its cover, details and description; "Download & read"
  downloads it and opens it where it was left, also when it was read in Grimmory's own
  reader.  Books downloaded here stay on the device and are synced.
- **Hold** a book for its actions (read, download, details, series, delete from device), or
  a series, shelf or library for "Show books", "Download with automatic sync" and, for a
  series, "Smart download: keep the next volumes".
- **Several books at once**: "⋯" -> "Select books to download" (or hold a book), tick books
  on any page of the list and tap "Download".
- **Search** books, or series in the Series tab, with the magnifier.
- **Covers** are loaded in the background, three at a time, and kept on the device.
  Server answers are kept for 10 minutes ("⋯" -> "Refresh" loads them again).

Loading never blocks KOReader: while the server answers, a cloud shows in the top bar and
Back and the tabs keep working.  When the server does not answer, see
[Unreachable server](#unreachable-server).

### SimpleUI

With [SimpleUI](https://github.com/doctorhetfield-cmd/simpleui.koplugin) 3 installed:

- The library can be a **tab of SimpleUI's bottom bar**: choose "Grimmory" in SimpleUI's
  settings for the bottom bar's tabs (it is also a Quick Action).  The library then opens
  between SimpleUI's top and bottom bars.
- The plugin's dialogs are SimpleUI's action sheets, and the browser's buttons use
  SimpleUI's icons (also the ones chosen in its settings).

Without SimpleUI, KOReader's own dialogs and icons are used.

## Syncing

### What is synced

| Data | Direction | Notes |
|---|---|---|
| Reading progress | both ways | Newer progress wins.  On opening a book (and on wake, if turned on), a newer position from the server is offered ("Go to latest location"). |
| Reading sessions | to Grimmory | Time and pages read, for Grimmory's statistics.  Short sessions are left out (see Reading Session Thresholds). |
| Highlights and notes | both ways | New, changed and deleted ones, sent when their book is closed and with every full sync. |
| Book information | from Grimmory | Title, authors, series and number, language, tags and description, shown as the book's custom metadata (see [Book information](#book-information-from-grimmory)). |
| "Finished" status | from Grimmory | A book marked "Finished" in Grimmory is marked finished in KOReader (books downloaded by the sync, the library browser or smart download).  A book finished on the device is never set back. |
| Shelves | from Grimmory | As KOReader collections. |

Only files in Grimmory's formats (EPUB, PDF, CBZ / CBR / CB7 / CBT, FB2, MOBI, AZW3) are
synced.  Other files opened in KOReader (e.g. a `.txt` or an image) are never sent or
searched for, and a book Grimmory does not have is skipped without counting as a failure.

### When it syncs

- **Sync Everything Now** (in the menu, or the gesture action "Grimmory: Sync Now"): the full
  sync.  A popup shows each step (uploading reading progress, checking the library,
  downloading books, …), where it is ("Downloading books · 3 of 6 · Title") and a Stop
  button; a summary follows.
- **Sync This Book Now** (in a book's menu) or **Sync with Grimmory** (holding a file in the
  file browser): one book, including its description and highlights.  **Reload from
  Grimmory** also downloads the book's file again if it changed in Grimmory.
- **Automatically**, as set under [When to Sync](#when-to-sync): when opening or closing a
  book, on wake, suspend or power off, and periodically.

Gesture actions (KOReader's gesture manager): "Grimmory: Browse Library", "Grimmory: Sync
Now", "Grimmory: Sync in Background", "Grimmory: Sync Open Book Now" and "Grimmory: Sync
Open Book in Background".

### Offline and failed syncs

Reading progress, sessions and highlights stay on the device until Grimmory has accepted
them.  When a sync does not get through (no network, server not reachable, another sync
running), they are sent later:

- as soon as WiFi is connected again (by you, KOReader or another plugin), after waking up
  and when KOReader starts, if WiFi is connected (WiFi is never turned on just for this);
- with the next sync that gets through.

A small cloud icon in the corner shows such a retry running.  Reading sessions of a book
Grimmory no longer has (deleted there) are dropped once; when the book was replaced by a
new upload and downloaded again, they go to the new book.

### Book information from Grimmory

Title, authors, series and number, language, tags (Grimmory's categories and tags) and the
description are taken from Grimmory and shown in KOReader instead of what the file says,
e.g. for comics without metadata.  They are written as the book's custom metadata, as when
editing them in KOReader's **Book information** (marked with a pencil there, each can be
reset there).  Grimmory's values win: edit metadata in Grimmory.  Every full sync updates
them; "Sync with Grimmory" and "Reload from Grimmory" also update the description.

## Downloads

The full sync downloads the books of the **download sources**: everything, or chosen
shelves, libraries, magic shelves and series.  Choose them under **Downloads** -> **Download
Sources**, or in the library browser with "Download with automatic sync" in a shelf,
library or series.

Books downloaded from the library browser and by smart download are **kept**: the sync
does not remove them, also when they are in no download source.  When you delete one from
the device, it is not downloaded again (only smart download fetches a volume again while it
is one of the volumes to keep).

### Smart download for series

**Downloads** -> **Smart Download for Series** keeps the volume being read and the next
unread volumes of a series on the device.  With volumes 1–5 finished and volume 6 being
read, it downloads volume 6 and, by default, volume 7 (one book ahead), or volumes 7–9 for
comics and manga (three ahead).

- **Series Being Read**: every series with a volume being read.  In the library browser,
  untick "Smart download" in a series to leave it out, or tick it in a series not started
  yet to begin with its first volumes.
- **Only Chosen Series**: only the series ticked in the library browser.

It runs with every full sync and after closing a book of a series.  Volumes are ordered by
their series number in Grimmory (without one, by a number the file name starts with, e.g.
`03 Title (2020).cbz`).  A volume marked as being read counts only from 1 % progress on, so
volumes opened for a moment do not move the series ahead.  KOReader's log lists, for each
series, the volumes as smart download sees them and the ones it keeps ("Smart download: …").

## Menu and settings

All under **Tools** -> **Grimmory**.  Defaults in brackets.

### Actions

| Entry | What it does |
|---|---|
| Browse Library | Opens the [library browser](#library-browser). |
| Sync This Book Now | Syncs the open book (only shown in the reader). |
| Sync Everything Now | The full sync, with the progress popup.  While a sync runs: **Interrupt Current Sync**. |

### What to Sync

| Setting | Default | What it does |
|---|---|---|
| Reading Progress | on | Send and receive the reading position. |
| Reading Sessions | on | Send reading sessions for Grimmory's statistics. |
| Reading Session Thresholds | 30 s, 0 pages | Sessions shorter than these (minimum seconds, minimum pages) are not sent. |
| Annotations | on | Send and receive highlights and notes. |
| Book Information | on | Show Grimmory's title, authors, series, language, tags and description in KOReader. |
| Shelves as Collections | on | Put downloaded books into KOReader collections named after their Grimmory shelves. |
| Keep Empty Shelves | off | Keep collections of shelves that no longer contain books on the device. |

### When to Sync

| Setting | Default | What it does |
|---|---|---|
| Check Progress When Opening a Book | on | Offer a newer reading position from the server when a book is opened. |
| Check Progress on Wake | off | The same when the device wakes up. |
| Sync Book When Closing It | off | Send the closed book's reading progress, sessions and highlights. |
| Sync on Suspend | off | Full sync when the device goes to sleep, over an existing connection only (WiFi is not turned on). |
| Sync on Power Off | off | The same when powering off. |
| Sync Everything Periodically | off | Full sync in the background … |
| Every … minutes | 120 | … this often. |

### Downloads

| Setting | Default | What it does |
|---|---|---|
| Download Books with Sync | on | The full sync downloads the books of the download sources. |
| Download Sources | Everything | **Everything**, or choose **Shelves**, **Libraries**, **Magic Shelves** and **Series** (series are added in the library browser). |
| Smart Download for Series | off | **Off**, **Series Being Read** or **Only Chosen Series**; **Books Ahead** (1) and **Comics / Manga Ahead** (3) set how many unread volumes are kept after the one being read. |
| Download Folder | `grimmory` in KOReader's folder | Where downloaded books are saved. |
| Delete Books No Longer in Sources | off | Delete downloaded books that are no longer in a download source.  When off, they only leave their Grimmory collections. |

### Library Browser

| Setting | Default | What it does |
|---|---|---|
| Show Books as Cover Grid | off (list) | Cover grid instead of a list (also switchable with "⋯" in the browser). |
| Clear Cache | | Remove the cached covers and server answers; they are loaded again when needed. |

### Network

| Setting | Default | What it does |
|---|---|---|
| Turn On WiFi When Needed | off | Turn WiFi on for syncs, downloads and the library browser, and off again afterwards.  When off, KOReader asks before going online.  If WiFi does not connect (e.g. in flight mode), the plugin does not turn it on by itself again (opening or closing a book, waking up, periodic sync) until WiFi works again or you sync or browse by hand. |
| Check HTTPS Certificates | on | See [HTTPS](#https). |
| Connect WiFi in Background (experimental, PocketBook only) | off | Turn WiFi on with PocketBook's system network tool, so reading is not interrupted while connecting; falls back to the regular connection after 30 seconds. |

### Server Connection, Custom HTTP Headers, About

- **Server Connection**: server address, user name and password; **Test** checks them.
- **Custom HTTP Headers**: headers sent with every request, see
  [Custom HTTP headers](#custom-http-headers).
- **About Grimmory Sync**: the repository and version, and **Check for Updates**, see
  [Updating](#updating).

## Connection and security

### HTTPS

With an `https://` server address, the plugin checks the server's certificate: it must be
valid (signed by a known authority, e.g. Let's Encrypt, from KOReader's list) and belong to
the server's host name.  Otherwise the connection ends before anything is sent, so nobody
in between can read the login, the headers or the books.  If the check fails although the
certificate is fine, check the device's date and time.

For a self-signed certificate, turn off **Network** -> **Check HTTPS Certificates**; the
connection is then still encrypted, but can be intercepted.  Plugin updates from GitHub
are always checked.

### Custom HTTP headers

**Custom HTTP Headers** adds headers to every request to the Grimmory server, e.g. a secret
header that lets the plugin past an authentication proxy (Traefik with Authentik forward
auth, Cloudflare Access service tokens).  Values are shown masked.

Headers the plugin sets itself cannot be replaced: `Authorization` (Grimmory's login),
`Host`, `Content-Type`, `Content-Length`, `Connection`, `Transfer-Encoding`, `X-Auth-User`
and `X-Auth-Key` (KOReader sync).

### Unreachable server

When the server does not answer (e.g. a firewall or CrowdSec blocks the device's address),
the plugin gives up after 10 seconds of connecting or 30 seconds without data (60 for syncs
and downloads), shows "The Grimmory server is not reachable." and does not try again for
30 seconds (Retry, or WiFi connecting again, tries at once).

Connections to the server are kept open between requests, which matters most over the
Internet: no new connection and TLS handshake for every cover or page.

## Updating

**Tools** -> **Grimmory** -> **About Grimmory Sync** -> **Check for Updates** shows whether a
new release is available and installs it ("Update to …").  The update applies after
restarting KOReader.  Alternatively, replace the plugin folder with the
[latest release][latest-plugin].

## License

Distributed under the terms of the [AGPL-3.0 License](./LICENSE).

The cloud and library icons (`icons/cloud_*.svg`, `icons/local_library.svg`) are
[Material Symbols](https://github.com/google/material-design-icons) by Google, under the
[Apache License 2.0](./grimmory.koplugin/icons/LICENSE-material-symbols.txt).

[latest-plugin]: https://github.com/niklas389/grimmory.koplugin/releases/latest/download/grimmory.koplugin.zip
