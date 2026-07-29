# folderlock.koplugin

A [KOReader](https://github.com/koreader/koreader) plugin that asks for a PIN before
opening a protected folder or any document inside it.

Built for a jailbroken Kindle, but it only uses portable KOReader APIs, so it should work
on Kobo, PocketBook, Android and the emulator as well.

## What it does

- Long-press a folder in the file manager to protect it with a PIN.
- Entering the folder, or opening any book inside it, asks for the PIN first.
- The unlock lasts only while you stay inside the folder. Walking out re-locks it, so
  coming back asks again.
- Going to sleep re-locks, and waking up asks for the PIN again before putting you back
  where you were. Reading position is preserved.
- On the sleep screen, the cover of a protected book is replaced by one of KOReader's
  default backgrounds, so the lock screen does not give away what you were reading.
- Dismissing a PIN prompt takes you to the home folder rather than leaving you next to the
  content that was refused.

Both sleep-related behaviours are individually switchable, and both default to on.

## What this is *not*

Read this part before trusting it with anything that matters.

**This is not encryption.** It keeps a curious person holding your device out of a folder.
It does not stand up to anyone with file access:

- The files are stored unchanged. Plugging the device in over USB, or reaching it over SSH,
  or opening it with any other reader app, reads them with no PIN involved.
- The PIN is stored as `sha256(salt .. pin)` with a random 16-byte salt, never in clear
  text — but the hash *and* the list of protected folders live in a plain settings file on
  the same device. Deleting that file removes the protection.
- A short numeric PIN is brute-forceable offline in no time. There is no attempt limit.
- **Titles can still leak elsewhere.** The plugin blocks *opening* a protected book from
  History, Collections and the file searcher, but those lists may still show its title and
  cover, and reading statistics keep it too.

If you need real confidentiality, use full-device or filesystem encryption. This plugin is
about privacy from casual snooping, not security against an attacker.

## Requirements

KOReader with `FileManager:addFileDialogButtons`, `ffi/sha2`, and `WidgetContainer:extend`.
Tested against **v2026.07** on a Kindle 10th generation (`KindleBasic3`, 600x800 @ 167 dpi)
and on the SDL emulator.

## Install

Copy `folderlock.koplugin/` into KOReader's `plugins/` directory and restart KOReader.
Plugins are not reloaded while running.

| Device | Destination |
| --- | --- |
| Kindle | `/mnt/us/koreader/plugins/` |
| Kobo | `.adds/koreader/plugins/` |
| Android | `koreader/plugins/` |
| Emulator | `koreader-emulator-*/koreader/plugins/` |

For development you can leave the plugin outside the KOReader tree and point
`extra_plugin_paths` at its parent folder in `settings.reader.lua`:

```lua
["extra_plugin_paths"] = "/path/to/your/plugins",
```

## Usage

1. **Tools → more tools → Folder lock → Set PIN.**
2. Long-press the folder you want to protect and choose **Protect with PIN**. If no PIN
   exists yet, it walks you through creating one first — protecting a folder before there
   is a PIN would lock it with no way back in.
3. Tap the folder. It now asks for the PIN.

The same menu lists the protected folders, lets you remove protection (PIN required), and
lets you re-lock everything immediately with **Lock now**.

## How it works

A folder lock is only as good as the number of ways *around* it, so the plugin covers five
separate paths into protected content:

| Path in | Where it is caught |
| --- | --- |
| Tapping the folder, shortcuts, "go to folder", search results | `FileChooser.changeToPath` |
| History, Collections, file searcher, "open last file" | `ReaderUI.showReader` |
| File manager *built* at a protected folder (restored `lastdir`) | `PathChanged` event |
| Document already open before the plugin exists (resumed on start) | plugin `init` in reader context |
| Going to sleep and waking up | `Screensaver.setup` / `Screensaver.close` |

Two of those deserve an explanation, because the obvious approach does not work:

- **`lastdir` restore.** `FileManager:showFiles()` resolves `lastdir` and hands it to
  `FileChooser:new()` as `root_path`, never passing through `changeToPath`, and it happens
  before any plugin exists. Checking it in the plugin's `init` does not work either, since
  `setupLayout()` creates the `file_chooser` *after* plugins are instantiated. The earliest
  a plugin can see that path is the `PathChanged` event the file manager fires right after
  `setupLayout`.
- **Sleep and wake.** On Kindle the power path is `IntoSS → Kindle:intoScreenSaver()`, which
  calls `Screensaver:setup()` and `:show()` directly and never broadcasts a `Suspend` event.
  An `onSuspend` handler simply never runs on the device. Both Kindle and the emulator do go
  through `Screensaver:setup`/`:close`, so everything hangs off those instead.

Class methods are wrapped following the idiom of `coverbrowser.koplugin`: originals kept in
locals, patched once, guarded against re-patching when the plugin is instantiated again for
the file manager and the reader.

## Translations

The UI follows KOReader's interface language. English is the source; **pt-BR** ships
compiled. A plugin outside the KOReader tree is not covered by the official l10n catalog,
so it loads its own `.mo` with `GetText.loadMO` at startup.

To add a language, translate the template and compile it:

```sh
cd folderlock.koplugin
msginit -i l10n/folderlock.pot -o l10n/<lang>/folderlock.po -l <lang>
# translate, then:
msgfmt -o l10n/<lang>/folderlock.mo l10n/<lang>/folderlock.po
```

Then add the language to the mapping in `loadTranslations()` in `main.lua`.

Note: switching KOReader's interface language at runtime clears the translation table, so
plugin strings fall back to English until the next restart.

## Development

Lint with KOReader's own configuration:

```sh
luacheck --config /path/to/koreader/.luacheckrc folderlock.koplugin
```

After changing any user-visible string, regenerate the template and check that no `msgid`
drifted — a typo in a `msgid` does not error, it just silently stops translating:

```sh
cd folderlock.koplugin
xgettext --language=Lua --keyword=_ --from-code=UTF-8 --no-location \
    --package-name=folderlock -o l10n/folderlock.pot main.lua _meta.lua
msgcmp l10n/pt_BR/folderlock.po l10n/folderlock.pot   # silent output means complete
msgfmt -o l10n/pt_BR/folderlock.mo l10n/pt_BR/folderlock.po
```

In the emulator, **F2** is the power button, so it exercises the whole sleep and wake path.

## License

[AGPL-3.0](LICENSE), matching KOReader: this plugin is loaded into KOReader's process and
uses its internal APIs.
