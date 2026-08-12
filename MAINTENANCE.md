# Maintenance

This plugin stands on no supported extension point. It works by wrapping four KOReader class
methods and reading a handful of internals, which means a KOReader update can break it
**without raising a single error**: the lock quietly stops locking, or a folder becomes
unreachable. Nothing in the log says so.

This file exists so whoever picks it up next — a future me included — can decide in under an
hour whether it still works, and knows where to look when it does not.

Everything below was verified against **koreader/koreader `74e3ffb`**
(`v2026.07-3-g74e3ffbde`, 2026-07-28), the tree the 1.0.x releases were tested on.

> Line numbers rot; symbol names do not. Grep for the symbol first and treat the number as a
> hint about where it used to be.

## Contact surface with KOReader

### Patched class methods

All four are wrapped in `patchFunnels()`, originals kept in locals, guarded by the module-level
`patched` flag — the plugin is instantiated once for the file manager and again for every
document opened, and the patch must be applied exactly once. Idiom borrowed from
`coverbrowser.koplugin/main.lua`.

| Symbol | v2026.07 | Why it is patched | Symptom if upstream changes |
| --- | --- | --- | --- |
| `FileChooser.changeToPath(self, path, focused_path)` | `frontend/ui/widget/filechooser.lua:340` | Gate #1: taps on a folder, folder shortcuts, "go to folder", file-search results | A new positional argument is silently dropped by the wrapper (it forwards exactly two) — focus or selection breaks. If navigation stops routing through it, protected folders open with no prompt. |
| `ReaderUI.showReader(self, file, ...)` | `frontend/apps/reader/readerui.lua:616` | Gate #2: History, Collections, file searcher, "open last file" — all reach a document without ever navigating to its folder | Wrapper is varargs-safe, so added parameters pass through. The real risk is a caller reaching `showReaderCoroutine` (`:711`) or `doShowReader` (`:739`) **directly**, bypassing the gate. Both are currently downstream of `showReader`; verify that after an update. |
| `Screensaver.setup(self, ...)` | `frontend/ui/screensaver.lua:346` | Re-locks on sleep, notes what to re-ask for, and swaps a cover-revealing sleep screen | Renamed or bypassed: the whole sleep/wake feature stops with no error. Suspending would then leave a protected folder unlocked and possibly show the cover. |
| `Screensaver.close(self, ...)` | `frontend/ui/screensaver.lua:710` | Steps out of protected content *before* the sleep screen comes down, then prompts | Wake-up prompt never fires; the reader reappears on the page it was on. |

**Why the sleep logic hangs off `Screensaver` and not an `onSuspend` handler** — this is the
non-obvious one and it must not be "simplified" back:

- Kindle: `Kindle:intoScreenSaver()` (`frontend/device/kindle/device.lua:752`) calls
  `Screensaver:setup()` and `:show()` directly at `:758-759` and **never broadcasts
  `Event:new("Suspend")`** on the power-button path. Only `powerd:beforeSuspend()` runs, which
  is not an event. An `onSuspend` handler would first fire on the *next* suspend — by then the
  cover has already been on screen once.
- Waking runs through `Screensaver:close()` on both platforms: `Kindle:outofScreenSaver()`
  (`device.lua:777`, calls close at `:782`) and `Emulator:simulateResume()`
  (`frontend/device/sdl/device.lua:466-468`).
- The emulator takes the same route via `Emulator:simulateSuspend()` (`sdl/device.lua:458-461`),
  which is why **F2** in the emulator is a faithful test of the device behaviour
  (`frontend/device/sdl/event_map_sdl2.lua:51` maps F2 to `Power`).

There is deliberately **no `onSuspend` method** on the plugin. A comment in `main.lua` says so;
keep it.

### Official extension point

`FileManager:addFileDialogButtons(row_id, row_func)` (`filemanager.lua:484`) — the
protect/unprotect row in the folder long-press dialog. Rows are collected right before the
`ButtonDialog` is built (`filemanager.lua:328-335`), and returning `nil` from `row_func` skips
the row, which is how the row hides itself for files and for the current/parent entries.

Two fragile details:

- `attachFolderDialogRow()` reads the **private** `fm.file_dialog_added_buttons.index` table
  (`filemanager.lua:486-489`) to decide whether it already attached. If that structure changes,
  expect either a duplicated button or none at all. Upstream dedupes by `row_id` anyway, so the
  worst case of losing the check is a redundant call, not a duplicate row.
- The dialog is built by whichever `FileManager` instance is current (`file_manager` captured in
  the closure at `filemanager.lua:328`), which is not necessarily the instance this plugin was
  constructed with — returning from the reader can hand over a file manager the plugin never
  attached to. That is why `onPathChanged` re-attaches on every path change.

`coverbrowser.koplugin/main.lua:562` uses the same API and its `row_func` takes a third
argument (`bookinfo`); ours ignores it. Only `FileManager` defines the method, so reader
instances skip registration (`registerFolderDialogButton` logs at `dbg` and returns).

### Event handled

`PathChanged(path)` — covers the case no patch can: a file manager **built** at a protected
folder rather than navigated to.

- `FileManager:showFiles()` resolves `lastdir` at `filemanager.lua:1319` and hands it to
  `FileChooser:new{ path = self.root_path }` (`:1325` → `:138-140`), never passing through
  `changeToPath`, and all of it happens before any plugin exists.
- Checking it in `init()` does not work either: plugins are instantiated in the loop at
  `filemanager.lua:418`, and `setupLayout()` — which creates `file_chooser` — only runs at
  `:431`. **`self.ui.file_chooser` is `nil` during a plugin's `init()`.**
- The earliest a plugin can see that path is the `PathChanged` the file manager fires right
  after `setupLayout` at `:434`. `FileChooser:changeToPath` fires the same event
  (`filechooser.lua:363`), so this handler doubles as a backstop for any navigation that
  skipped the patched funnel.
- **This depends on `FileManager.onPathChanged` returning nothing.** It is aliased to
  `updateTitleBarPath` (`filemanager.lua:114`). If it ever starts returning `true`, the event
  stops propagating, and startup coverage disappears silently.

An alternative to `PathChanged` is `self.ui:registerPostInitCallback(fn)`
(`filemanager.lua:391`; used by `autowarmth.koplugin/main.lua:61` and
`readtimer.koplugin/main.lua:148`) — worth remembering if the event ever gets consumed.

### Load order the plugin relies on

`refuseProtectedDocument()` catches the one document `showReader` cannot: the file resumed at
startup (or passed on the command line), opened before the plugin existed.

It is safe because plugins load at `readerui.lua:464`, *inside* `ReaderUI:init`, and
`doShowReader` (`:739`) only calls `UIManager:show()` after `ReaderUI:new()` returns — so
nothing has been painted yet and the page never reaches the screen. The document object does
exist and is parsed at that point, which is why the plugin hands over to the file manager
instead of trying to prompt on top of it.

`self.ui:showFileManager(folder)` (`readerui.lua:581`) is passed the **folder**, not its parent,
on purpose: it splits the path, so the file manager opens at the parent with the protected
folder focused — exactly where the prompt belongs.

### Internals read directly

| Used | Where |
| --- | --- |
| `require("apps/filemanager/filemanager").instance` and `.file_chooser.path` | `goHome`, `armWakeupPrompt`, `leavePendingTarget`, `askAfterWakeup`, `folderDialogRow` |
| `require("apps/reader/readerui").instance` and `.document.file` | `armWakeupPrompt`, `leavePendingTarget`, `overrideScreensaverIfProtected` |
| `G_reader_settings`: `screensaver_type`, `screensaver_show_message`, `lastfile`, `language` | `overrideScreensaverIfProtected`, `loadTranslations` |
| `plugin_module.path` (injected at `pluginloader.lua:248`) | `loadTranslations`, as `self.path` |

`require("apps/reader/readerui")` is **function-local everywhere on purpose**: `readerui.lua:28`
requires `pluginloader`, so pulling it in at module level from inside a plugin risks a circular
require. `calibre.koplugin/search.lua` and `coverbrowser.koplugin/bookinfomanager.lua:496` do
the same.

### Sleep-screen modes

`COVER_LEAKING_TYPES` in `main.lua` lists the `screensaver_type` values that would give the book
away: `cover`, `document_cover`, `bookstatus`, `readingprogress`. `disable`, `message` and
`random_image` reveal nothing and are left exactly as configured.

**If KOReader adds a new sleep-screen mode that shows a cover or a title, it must be added to
that table**, otherwise the feature silently stops covering that case. The override sets
`screensaver_type = "random_image"`, which with no folder configured falls back to the bundled
`resources/koreader.png` (`screensaver.lua:439`); the cover shown would otherwise come from the
open document or, in the file manager, from `lastfile` (`screensaver.lua:373`).
`screensaver_show_message` is forced off while overriding because the message template can carry
the title (`%T`). Both settings are restored right after `setup_orig` returns.

### KOReader libraries

`ffi/sha2` (`sha2.sha256`), `ffi/util` (`realpath`, `template`), `luasettings`
(`readSetting`, `saveSetting`, `nilOrTrue`, `makeTrue`, `makeFalse`, `flush`), `datastorage`
(`getSettingsDir`), plus the standard widgets. `/dev/urandom` provides the salt, with a weaker
`math.random` fallback that only exists so a missing device node cannot fail the install.

### Lua 5.1 constraints worth remembering

- `unpack`, not `table.unpack`.
- **A nested closure cannot reference `...`** — that is why the `showReader` wrapper captures
  `select("#", ...)` and `{...}` into locals before building the retry closure. Do not
  "simplify" that into a direct `...` reference inside the closure; it will not compile.

## Settings and runtime state

Persisted in `<settings dir>/folderlock.lua` (Kindle: `/mnt/us/koreader/settings/folderlock.lua`;
emulator: inside the emulator directory, or `$KO_HOME` when set):

| Key | Meaning |
| --- | --- |
| `folders` | map of **normalized** (realpath'd) folder path → `true` |
| `pin_hash` | `sha256(salt .. pin)` |
| `pin_salt` | 16 random bytes, hex |
| `ask_pin_on_wakeup` | `nilOrTrue` — absent means on |
| `hide_cover_when_suspended` | `nilOrTrue` — absent means on |

Never persisted, module-level so it survives the FileManager ↔ ReaderUI instance switch:
`unlocked` (folder → true) and `pending_wakeup` (`{folder, file}`).

Paths are stored normalized because `changeToPath` normalizes too — without it,
`books/../books/private` would walk straight past the check. `isInside` compares with a trailing
`/` boundary so `/books/private` does not also match `/books/private2`.

**Recovery, for support questions:** a forgotten PIN is not recoverable by design and not worth
pretending otherwise — delete `folderlock.lua` (or just the `pin_hash`, `pin_salt` and `folders`
keys) with KOReader closed. This is not a backdoor being added; the README already states that
deleting that file removes the protection.

## Acceptance test script

Run this against every new KOReader release before assuming the plugin still works. It is
ordered so each step leaves the state the next one needs. Emulator is enough for 1–13; do at
least 1, 6, 8 on the device too, since the sleep path differs.

Setup: a folder with at least two books in it, a sibling folder, and a book outside.

| # | Action | Expected |
| --- | --- | --- |
| 0 | **Tools → more tools → Folder lock → Set PIN**, then long-press the folder → **Protect with PIN** | Confirmation toast; folder appears under **Protected folders (n)** |
| 1 | Tap the protected folder | PIN prompt |
| 2 | Enter a wrong PIN | "Wrong PIN", lands in the home folder |
| 3 | Tap it again, enter the correct PIN | Folder opens |
| 4 | Go up to the parent, then back into the folder | Prompt again (leaving re-locks) |
| 5 | Unlock, open a book inside, then close it back to the file manager | Book opens with no second prompt; still inside, still unlocked |
| 6 | Restart KOReader while a protected book was the last one open | File manager at the parent, folder focused, "… is protected" message. No page ever flashes |
| 7 | Restart KOReader while the file manager was sitting inside the folder | Bounced out to the parent |
| 8 | Open a protected book from **History**; likewise from **Collections** and from the file searcher | PIN prompt on each |
| 9 | With a protected book open, sleep (F2 in the emulator, power button on device) | Sleep screen shows a default background, no title, no cover |
| 10 | Wake up | PIN prompt; correct PIN reopens the same book at the same page |
| 11 | Turn **Ask for the PIN after waking up** off, sleep and wake | Straight back into the book, no prompt |
| 12 | Unlock a folder, then **Lock now** while standing inside it | Bounced out to the parent, toast shown |
| 13 | Long-press the folder → **Remove PIN protection**; long-press the current folder and the `../` entry | Removal asks for the PIN; no button on the current folder or on `../` |
| 14 | Read `crash.log` (device) or the emulator log | Gate events at `info` — blocked, unlocked, left, refusing, sleeping, waking. Nothing per page, nothing per long-press |
| 15 | `luacheck --config <koreader>/.luacheckrc folderlock.koplugin` | Clean |

## Release checklist

There is **no version string in the code** — `_meta.lua` carries only `fullname` and
`description`. The version lives in the git tag and in `CHANGELOG.md`, and nothing else needs
bumping.

1. Update `CHANGELOG.md` (Keep a Changelog format) and add the release link reference at the
   bottom.
2. If any user-visible string changed, regenerate the template, check for `msgid` drift and
   recompile the catalog — see the Development section of the README. **The `.mo` is committed
   on purpose**: installing is a plain copy, there is no build step on the device.
3. `luacheck` clean.
4. Run the acceptance script above: emulator, then the device.
5. Tag `vX.Y.Z` and push the tag.
6. Publish a GitHub release with a zip whose **root contains `folderlock.koplugin/`**, so
   unzipping into `plugins/` lands correctly.
7. **Bump the submodule in `koreader/contrib`.** The catalog carries this repo as a submodule
   pinned to a tag (PR #159 pinned `v1.0.1`), so a new release is invisible to contrib users
   until a follow-up PR moves the pin. Easy thing to forget — the release itself looks complete
   without it.

## What is intentionally not fixed

Read the "What this is *not*" section of the README before treating any of these as bugs: no
encryption, no attempt limit, files readable over USB/SSH, hash and folder list in a plain
settings file, and titles of protected books still surfacing in History, Collections and
reading statistics. Those are accepted limits of a privacy-from-snooping tool, documented
rather than hidden.
