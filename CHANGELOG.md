# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1] - 2026-07-29

### Fixed

- Three diagnostic log lines, left over from tracking down a bug during development, were
  logging at `info` and shipped that way in 1.0.0. One of them fired on every book opened and
  another on every folder long-press, writing the folder name into the log each time. They are
  `dbg` now. The gate events that are worth auditing — blocked, unlocked, re-locked, refused,
  sleeping, waking — deliberately stay at `info`, so they remain readable on a device without
  debug logging turned on.

## [1.0.0] - 2026-07-29

First release.

### Added

- PIN protection for folders. Long-press a folder in the file manager and choose
  **Protect with PIN**; if no PIN exists yet, it walks you through creating one first.
- Access is gated at five separate points, so the lock has no obvious way around it:
  - `FileChooser.changeToPath` — tapping the folder, folder shortcuts, "go to folder" and
    file-search results.
  - `ReaderUI.showReader` — History, Collections, the file searcher and "open last file",
    which reach a document without ever navigating to its folder.
  - `PathChanged` — the file manager being *built* at a protected folder restored from
    `lastdir`, which never passes through `changeToPath`.
  - plugin `init` in reader context — a document resumed on startup, before the plugin
    existed.
  - `Screensaver.setup` / `Screensaver.close` — going to sleep and waking up.
- An unlock lasts only while you stay inside the folder. Leaving re-locks it, so coming back
  asks again. Reading a book from the folder counts as staying inside.
- **Ask for the PIN after waking up** (on by default, switchable). Sleeping re-locks and
  steps out of the protected content before the sleep screen comes down, so waking never
  flashes a page. Entering the correct PIN returns you to the book at the same page.
- **Hide cover of protected books when suspended** (on by default, switchable). Replaces the
  cover with one of KOReader's default backgrounds and suppresses the sleep-screen message,
  which can carry the title. Only the modes that would actually reveal the book are
  overridden (`cover`, `document_cover`, `bookstatus`, `readingprogress`); the user's setting
  is restored afterwards.
- Dismissing an access prompt, or entering a wrong PIN, sends you to the home folder rather
  than leaving you beside the content that was refused.
- Menu with PIN management, the list of protected folders, and **Lock now**.
- Brazilian Portuguese translation, loaded from the plugin's own catalog.

### Security notes

- The PIN is stored as `sha256(salt .. pin)` with a random 16-byte salt read from
  `/dev/urandom`, never in clear text. Unlocks live in memory only and are never persisted.
- This is **not** encryption, and the README says so in detail. Files stay readable over
  USB, SSH or any other reader app, the hash and folder list sit in a plain settings file on
  the device, there is no attempt limit, and titles of protected books can still surface in
  History, Collections and reading statistics.

### Tested on

- Kindle 10th generation (`KindleBasic3`, 600x800 @ 167 dpi) running KOReader v2026.07.
- KOReader SDL emulator at the same screen geometry.

[1.0.1]: https://github.com/danieldecesaro/koreader-folderlock/releases/tag/v1.0.1
[1.0.0]: https://github.com/danieldecesaro/koreader-folderlock/releases/tag/v1.0.0
