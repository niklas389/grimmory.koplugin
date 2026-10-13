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

**Tools** -> **Grimmory** -> **Browse Library** lists all books, libraries,
shelves, magic shelves and series of your Grimmory server, with search.
Tap a book to see its details, its cover and description, or to download
and open it.  Books downloaded this way stay on the device and are synced.

Hold a library, shelf or series (or use "Download with automatic sync" inside
it) to let the automatic sync download its books.  The browser needs a
Grimmory version with the app API (`/api/v1/app`).

The browser can also be assigned to a gesture ("Grimmory: Browse Library").

## Menu

- **What to Sync**: reading progress, sessions, annotations, shelves
- **When to Sync**: opening / closing a book, wake, suspend, power off,
  periodically
- **Downloads**: download sources (everything, or chosen shelves, libraries,
  magic shelves and series), download folder, deleting removed books
- **Network**: turning WiFi on when needed

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

[latest-plugin]: https://github.com/niklas389/grimmory.koplugin/releases/latest/download/grimmory.koplugin.zip
