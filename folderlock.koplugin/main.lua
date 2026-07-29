--[[--
PIN-protects folders. Entering a protected folder in the file manager, or opening any
document inside one, asks for a numeric PIN first.

Two funnels are patched, following the idiom of coverbrowser.koplugin (original class
methods kept in locals, restored on disable):

  * `FileChooser.changeToPath` covers navigating into the folder -- taps, folder
    shortcuts, "go to folder" and file-search results all end up there.
  * `ReaderUI.showReader` covers History, Collections, the file searcher and the
    "open last file" path, which reach a document without ever navigating to its folder.
    Patching only the first one would leave those as a back door.

The PIN is stored as sha256(salt .. pin) with a random per-install salt, never in clear
text. Unlocks live in memory only and are dropped when the device suspends.

@module koplugin.folderlock
--]]--

local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local FileChooser = require("ui/widget/filechooser")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local logger = require("logger")
local sha2 = require("ffi/sha2")
local T = ffiUtil.template
local _ = require("gettext")

-- An unlock is valid only while you are *inside* the folder: walking out re-locks it, so
-- coming back always asks again. Reading a book from it counts as being inside, otherwise
-- closing the book would lock you out mid-session.
--
-- Module level, so it is shared by every plugin instance: KOReader instantiates the plugin
-- again when switching between FileManager and ReaderUI, and the unlock has to survive that
-- switch. Never persisted.
local unlocked = {}
local settings

local function getSettings()
    if not settings then
        settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/folderlock.lua")
    end
    return settings
end

local function getFolders()
    return getSettings():readSetting("folders") or {}
end

local function saveFolders(folders)
    local s = getSettings()
    s:saveSetting("folders", folders)
    s:flush()
end

local function protectFolder(path)
    local folders = getFolders()
    folders[path] = true
    saveFolders(folders)
end

local function hideCoverEnabled()
    return getSettings():nilOrTrue("hide_cover_when_suspended")
end

local function askPinOnWakeupEnabled()
    return getSettings():nilOrTrue("ask_pin_on_wakeup")
end

-- Translations ----------------------------------------------------------------------

local translations_loaded = false

--[[--
Loads the plugin's own catalog.

A plugin living outside the KOReader tree is not covered by the official l10n catalog, but
`GetText.loadMO` (gettext.lua:251) merges any .mo into the table that `changeLang` already
filled, and plugins are instantiated after changeLang has run at startup.

Caveat: changeLang() wipes the table (gettext.lua:162-164), so switching the interface
language at runtime drops these strings until the next restart.
--]]
local function loadTranslations(plugin_path)
    if translations_loaded or not plugin_path then return end
    translations_loaded = true
    local lang = G_reader_settings:readSetting("language")
    -- pt_BR is the only catalog shipped; plain "pt" gets it too.
    if not lang or not lang:match("^pt") then return end
    local mo = plugin_path .. "/l10n/pt_BR/folderlock.mo"
    if _.loadMO(mo) then
        logger.info("FolderLock: loaded translations from", mo)
    else
        logger.warn("FolderLock: no translations at", mo)
    end
end

-- Paths -----------------------------------------------------------------------------

-- changeToPath() itself normalizes with realpath, so protected paths are stored
-- normalized too. Without this, "books/../books/private" would slip past the check.
local function normalize(path)
    if not path or path == "" then return nil end
    return ffiUtil.realpath(path) or path
end

local function basename(path)
    return path:match("([^/]+)/?$") or path
end

local function parentDir(file)
    local dir = file:match("^(.*)/[^/]*$")
    if dir == "" then return "/" end
    return dir
end

local function isInside(path, folder)
    -- The "/" boundary matters: without it, /books/private would also match the
    -- unrelated sibling /books/private2.
    return path == folder or path:sub(1, #folder + 1) == folder .. "/"
end

--- Returns the protected folder covering `path`, or nil.
local function protectedFolderFor(path)
    path = normalize(path)
    if not path then return nil end
    for folder in pairs(getFolders()) do
        if isInside(path, folder) then
            return folder
        end
    end
    return nil
end

--- Re-locks every unlocked folder that `path` is no longer inside of.
local function relockOutside(path)
    path = normalize(path)
    for folder in pairs(unlocked) do
        if not (path and isInside(path, folder)) then
            -- Clearing the current key during pairs() is allowed in Lua.
            unlocked[folder] = nil
            logger.info("FolderLock: left", folder, "- locked again")
        end
    end
end

-- PIN -------------------------------------------------------------------------------

local function randomSalt()
    local f = io.open("/dev/urandom", "rb")
    if f then
        local bytes = f:read(16)
        f:close()
        if bytes and #bytes == 16 then
            return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
        end
    end
    -- Should not happen on Kindle/Kobo/Linux, but never fail closed on a missing device.
    logger.warn("FolderLock: /dev/urandom unavailable, falling back to a weaker salt")
    math.randomseed(os.time() + math.floor(os.clock() * 1000))
    local out = {}
    for i = 1, 16 do
        out[i] = string.format("%02x", math.random(0, 255))
    end
    return table.concat(out)
end

local function hasPin()
    return getSettings():readSetting("pin_hash") ~= nil
end

local function checkPin(pin)
    local s = getSettings()
    local hash, salt = s:readSetting("pin_hash"), s:readSetting("pin_salt")
    if not hash or not salt or not pin or pin == "" then return false end
    return sha2.sha256(salt .. pin) == hash
end

local function storePin(pin)
    local s = getSettings()
    local salt = randomSalt()
    s:saveSetting("pin_salt", salt)
    s:saveSetting("pin_hash", sha2.sha256(salt .. pin))
    s:flush()
end

--- Sends the user to the home folder. Used when an access prompt is dismissed: giving up
--- should land somewhere neutral rather than next to the content that was refused.
local function goHome()
    local fm = require("apps/filemanager/filemanager").instance
    if fm then
        fm:onHome()
    end
end

--- Prompts for a PIN. `on_ok` runs only on a correct PIN; `on_cancel` on dismissal and on
--- a wrong PIN, which are the same thing from the caller's point of view: no access.
local function askPin(title, on_ok, on_cancel)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input_type = "number",
        text_type = "password",
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                    if on_cancel then on_cancel() end
                end,
            },
            {
                text = _("Unlock"),
                is_enter_default = true,
                callback = function()
                    local pin = dialog:getInputText()
                    UIManager:close(dialog)
                    if checkPin(pin) then
                        on_ok()
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("Wrong PIN."),
                            timeout = 2,
                        })
                        if on_cancel then on_cancel() end
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Prompts for a new PIN twice and stores it only if both entries match.
local function askNewPin(on_done)
    local first
    first = InputDialog:new{
        title = _("Enter a new PIN"),
        input_type = "number",
        text_type = "password",
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(first)
                end,
            },
            {
                text = _("Next"),
                is_enter_default = true,
                callback = function()
                    local pin = first:getInputText()
                    UIManager:close(first)
                    if not pin or pin == "" then
                        UIManager:show(InfoMessage:new{ text = _("The PIN cannot be empty."), timeout = 2 })
                        return
                    end
                    local second
                    second = InputDialog:new{
                        title = _("Repeat the new PIN"),
                        input_type = "number",
                        text_type = "password",
                        buttons = {{
                            {
                                text = _("Cancel"),
                                id = "close",
                                callback = function()
                                    UIManager:close(second)
                                end,
                            },
                            {
                                text = _("Save"),
                                is_enter_default = true,
                                callback = function()
                                    local again = second:getInputText()
                                    UIManager:close(second)
                                    if again == pin then
                                        storePin(pin)
                                        UIManager:show(InfoMessage:new{ text = _("PIN saved."), timeout = 2 })
                                        if on_done then on_done() end
                                    else
                                        UIManager:show(InfoMessage:new{
                                            text = _("The two entries do not match. PIN unchanged."),
                                        })
                                    end
                                end,
                            },
                        }},
                    }
                    UIManager:show(second)
                    second:onShowKeyboard()
                end,
            },
        }},
    }
    UIManager:show(first)
    first:onShowKeyboard()
end

-- Gate ------------------------------------------------------------------------------

--- True when `path` may be opened right now. Otherwise shows the PIN prompt and
--- returns false; `on_unlock` runs once the correct PIN is entered.
local function allowed(path, on_unlock)
    local folder = protectedFolderFor(path)
    if not folder or unlocked[folder] then return true end
    logger.info("FolderLock: blocked access to", folder)
    askPin(T(_("PIN for %1"), basename(folder)), function()
        unlocked[folder] = true
        logger.info("FolderLock: unlocked", folder)
        on_unlock()
    end, goHome)
    return false
end

-- Sleep and wake ---------------------------------------------------------------------

-- What has to be unlocked again after waking up, noted while going to sleep.
local pending_wakeup = nil

--[[--
Locks everything when the device goes to sleep, and notes what was open.

This has to hang off the sleep screen rather than an `onSuspend` handler: on Kindle the
power event path is IntoSS -> Kindle:intoScreenSaver(), which calls Screensaver:setup()
and :show() directly (device/kindle/device.lua:752-759) and never broadcasts
Event:new("Suspend"). Only powerd:beforeSuspend() runs there, which is not an event. An
onSuspend handler simply never fires on the device.
--]]
local function armWakeupPrompt()
    -- Switched off means convenience wins: the session survives sleep and you wake up
    -- exactly where you were, protected folder still open.
    if not askPinOnWakeupEnabled() then
        pending_wakeup = nil
        return
    end

    local ui = require("apps/reader/readerui").instance
    local file = ui and ui.document and ui.document.file
    local folder
    if file then
        folder = protectedFolderFor(parentDir(file))
    else
        file = nil
        local fm = require("apps/filemanager/filemanager").instance
        local path = fm and fm.file_chooser and fm.file_chooser.path
        folder = path and protectedFolderFor(path) or nil
    end

    -- Sleeping always re-locks, whether or not anything protected was open.
    unlocked = {}

    if folder then
        pending_wakeup = { folder = folder, file = file }
        logger.info("FolderLock: sleeping inside", folder, "- will ask for the PIN on wake-up")
    else
        pending_wakeup = nil
    end
end

--- Steps out of the protected content while the sleep screen still covers it, so waking up
--- never flashes a page or a folder listing.
local function leavePendingTarget(target)
    local ui = require("apps/reader/readerui").instance
    if ui and ui.document then
        -- Closing the document saves the reading position, so reopening resumes the page.
        ui:showFileManager(target.folder)
        return
    end
    local fm = require("apps/filemanager/filemanager").instance
    if fm and fm.file_chooser then
        fm.file_chooser:changeToPath(parentDir(target.folder))
    end
end

--- Asks for the PIN after waking up and puts the user back where they were.
local function askAfterWakeup(target)
    askPin(T(_("PIN for %1"), basename(target.folder)), function()
        unlocked[target.folder] = true
        logger.info("FolderLock: unlocked after wake-up", target.folder)
        if target.file then
            require("apps/reader/readerui"):showReader(target.file)
        else
            local fm = require("apps/filemanager/filemanager").instance
            if fm and fm.file_chooser then
                fm.file_chooser:changeToPath(target.folder)
            end
        end
    end, goHome)
end

-- Sleep screen ----------------------------------------------------------------------

-- Sleep screen modes that would give away which book is open. "disable", "message" and
-- "random_image" reveal nothing, so those are left exactly as the user configured them.
local COVER_LEAKING_TYPES = {
    cover = true,
    document_cover = true,
    bookstatus = true,      -- shows title and reading status
    readingprogress = true, -- shows the book being read
}

--[[--
Forces one of KOReader's default backgrounds when the sleep screen would otherwise reveal a
protected book. Returns a function restoring the settings, or nil when nothing was changed.

`random_image` with no folder configured falls back to `resources/koreader.png`
(screensaver.lua:439) -- the bundled KOReader background.
--]]
local function overrideScreensaverIfProtected()
    if not hideCoverEnabled() then return nil end

    local type_now = G_reader_settings:readSetting("screensaver_type")
    if not COVER_LEAKING_TYPES[type_now] then return nil end

    -- The cover shown belongs to the open document, or to the last read book when sitting
    -- in the file manager (screensaver.lua:372 falls back to lastfile).
    local ui = require("apps/reader/readerui").instance
    local file = ui and ui.document and ui.document.file
    if not file then
        file = G_reader_settings:readSetting("lastfile")
    end
    if not file or not protectedFolderFor(parentDir(file)) then return nil end

    logger.info("FolderLock: hiding the sleep screen cover of a protected book")
    local had_message = G_reader_settings:isTrue("screensaver_show_message")
    G_reader_settings:saveSetting("screensaver_type", "random_image")
    if had_message then
        -- The message template can carry the title (%T), so it has to go as well.
        G_reader_settings:makeFalse("screensaver_show_message")
    end
    return function()
        G_reader_settings:saveSetting("screensaver_type", type_now)
        if had_message then
            G_reader_settings:makeTrue("screensaver_show_message")
        end
    end
end

local patched = false

local function patchFunnels()
    if patched then return end
    patched = true

    local changeToPath_orig = FileChooser.changeToPath
    FileChooser.changeToPath = function(self, path, focused_path)
        if allowed(path, function() self:changeToPath(path, focused_path) end) then
            return changeToPath_orig(self, path, focused_path)
        end
    end

    -- Function-local require on purpose: readerui.lua:28 requires pluginloader, so
    -- pulling it in at module level from inside a plugin risks a circular require.
    -- calibre.koplugin and coverbrowser.koplugin require it this way for the same reason.
    local ReaderUI = require("apps/reader/readerui")
    local showReader_orig = ReaderUI.showReader
    ReaderUI.showReader = function(self, file, ...)
        if not file then
            return showReader_orig(self, file, ...)
        end
        -- Lua 5.1 cannot reference `...` from a nested closure, so capture it.
        local n = select("#", ...)
        local extra = { ... }
        local retry = function()
            ReaderUI.showReader(self, file, unpack(extra, 1, n))
        end
        if allowed(parentDir(file), retry) then
            return showReader_orig(self, file, unpack(extra, 1, n))
        end
    end

    -- Wrapping Screensaver:setup rather than reacting to the Suspend event is deliberate:
    -- on Kindle, Kindle:intoScreenSaver() calls Screensaver:setup() and :show() directly
    -- (device/kindle/device.lua:752-759) and never broadcasts Suspend on that path, so an
    -- onSuspend handler would only take effect on the *next* suspend -- the cover would
    -- already have been on screen once.
    local Screensaver = require("ui/screensaver")
    local setup_orig = Screensaver.setup
    Screensaver.setup = function(sself, ...)
        local restore = overrideScreensaverIfProtected()
        armWakeupPrompt()
        setup_orig(sself, ...)
        if restore then restore() end
    end

    -- Waking up runs through Screensaver:close() on both platforms:
    -- Kindle:outofScreenSaver() (device/kindle/device.lua:782) and
    -- Emulator:simulateResume() (device/sdl/device.lua:468).
    local close_orig = Screensaver.close
    Screensaver.close = function(sself, ...)
        local target = pending_wakeup
        pending_wakeup = nil
        -- Step out *before* the sleep screen is taken down, so the content underneath is
        -- already gone when the screen repaints.
        if target then
            leavePendingTarget(target)
        end
        local ret = close_orig(sself, ...)
        if target then
            askAfterWakeup(target)
        end
        return ret
    end
end

-- Plugin ----------------------------------------------------------------------------

local FolderLock = WidgetContainer:extend{
    name = "folderlock",
    is_doc_only = false,
}

function FolderLock:init()
    loadTranslations(self.path)
    patchFunnels()
    self.ui.menu:registerToMainMenu(self)
    self:registerFolderDialogButton()
    self:refuseProtectedDocument()
end

--[[--
Adds the protect/unprotect button to the long-press dialog of a folder.

`FileManager:addFileDialogButtons(row_id, row_func)` (filemanager.lua:484) is the official
extension point; the rows are collected right before the ButtonDialog is built
(filemanager.lua:328-335), and returning nil skips the row. coverbrowser.koplugin:562 uses
the same API. Only the FileManager defines it, so ReaderUI instances skip this.
--]]
function FolderLock:folderDialogRow()
    return function(file, is_file)
        if is_file then return nil end
        local path = normalize(file)
        if not path then return nil end
        -- Only the go-up entry is excluded, by resolved path: filechooser.lua:271 gives it
        -- `<current>/..`, which realpath turns into the parent. An earlier version demanded
        -- that the item be a direct child of the current folder, which silently hid the
        -- button whenever the two paths did not normalize identically.
        local fm = require("apps/filemanager/filemanager").instance
        local fc = (fm and fm.file_chooser) or self.ui.file_chooser
        local current = normalize(fc and fc.path)
        if current and (path == current or path == parentDir(current)) then return nil end
        -- info, not dbg: dbg is silent unless debug logging is on, which makes it useless
        -- for diagnosing anything on the device.
        logger.info("FolderLock: adding folder dialog button for", path)

        local protected = getFolders()[path] ~= nil
        return {
            {
                text = protected and _("Remove PIN protection") or _("Protect with PIN"),
                callback = function()
                    if fc and fc.file_dialog then
                        UIManager:close(fc.file_dialog)
                    end
                    if protected then
                        self:unprotectFolder(path)
                    else
                        self:protectFolderWithPin(path)
                    end
                end,
            },
        }
    end
end

--[[--
Attaches the row to a file manager, if it is not on it already.

`addFileDialogButtons` keeps the rows on the FileManager *instance* and dedupes by row_id
(filemanager.lua:484-491), so calling this repeatedly is harmless. That matters because the
dialog is built by whichever instance is current (`file_manager` in the closure at
filemanager.lua:328), which is not necessarily the one this plugin instance was created
with -- returning from the reader can hand us a file manager we never attached to.
--]]
function FolderLock:attachFolderDialogRow(fm)
    if not (fm and fm.addFileDialogButtons) then return end
    if fm.file_dialog_added_buttons and fm.file_dialog_added_buttons.index.folderlock then
        return -- already on this one
    end
    logger.info("FolderLock: folder dialog button registered on", tostring(fm))
    fm:addFileDialogButtons("folderlock", self:folderDialogRow())
end

function FolderLock:registerFolderDialogButton()
    if not self.ui.addFileDialogButtons then
        logger.info("FolderLock: no addFileDialogButtons here, skipping the folder button")
        return
    end
    self:attachFolderDialogRow(self.ui)
end

--- Protects `path`, walking the user through creating a PIN first if there is none.
function FolderLock:protectFolderWithPin(path)
    local function done()
        protectFolder(path)
        UIManager:show(InfoMessage:new{
            text = T(_("%1 is now protected."), basename(path)),
            timeout = 2,
        })
    end
    if hasPin() then
        done()
    else
        -- No PIN yet: set one, then protect. Protecting first would lock the folder
        -- with no way back in.
        askNewPin(done)
    end
end

--[[--
Refuses a document that was opened without passing the gate.

The patch on ReaderUI.showReader cannot cover the very first document of a session:
KOReader resumes the last file (or takes one on the command line) and the plugin is only
instantiated during ReaderUI:init, by which time showReader has already run unpatched.

This is still called before anything is painted -- doShowReader() only calls
UIManager:show() after ReaderUI:new() returns, and plugins load at readerui.lua:475,
inside init -- so the pages never reach the screen. The document object exists and is
parsed at this point, which is why we hand over to the file manager instead of trying to
prompt on top of it.

Passing the folder itself to showFileManager is deliberate: it splits the path
(readerui.lua:583), so the file manager opens at the *parent* with the protected folder
focused, exactly where the PIN prompt belongs.
--]]
function FolderLock:refuseProtectedDocument()
    local doc = self.ui.document
    local file = doc and doc.file
    if not file then return end
    local folder = protectedFolderFor(parentDir(file))
    if not folder or unlocked[folder] then return end
    logger.info("FolderLock: refusing document opened outside the gate, from", folder)
    UIManager:nextTick(function()
        self.ui:showFileManager(folder)
        UIManager:show(InfoMessage:new{
            text = T(_("%1 is protected. Open it with your PIN to read its books."), basename(folder)),
        })
    end)
end

--[[--
Leaves a protected folder that the file manager was *built* at, rather than navigated to.

Patching changeToPath does not cover this: FileManager:showFiles() resolves `lastdir` and
hands it to FileChooser:new() as `root_path` (filemanager.lua:1319 and :138), so a restart
while the last folder was protected would land straight inside it, and that happens before
any plugin exists.

Checking it in init() does not work either -- setupLayout() creates the file_chooser at
filemanager.lua:431, *after* the plugin loop at :418, so self.ui.file_chooser is still nil
there. The FileManager fires PathChanged with the initial path right after setupLayout
(:434), which is the earliest a plugin can see it. FileChooser:changeToPath fires the same
event (filechooser.lua:363), so this also backstops any navigation that somehow skipped
the patched funnel.
--]]
function FolderLock:onPathChanged(path)
    -- Cheap insurance: make sure the row is on whichever file manager is live now, not only
    -- on the one this plugin instance was built with.
    self:attachFolderDialogRow(require("apps/filemanager/filemanager").instance)
    -- Walking out of a folder re-locks it, so re-entering always asks for the PIN again.
    relockOutside(path)
    local folder = protectedFolderFor(path)
    if not folder or unlocked[folder] then return end
    local fc = self.ui.file_chooser
    if not fc then return end
    logger.info("FolderLock: file manager sits inside", folder, "- leaving")
    UIManager:nextTick(function()
        fc:changeToPath(parentDir(folder))
    end)
end

--- Bounces out of the folder on screen if it is protected and no longer unlocked.
function FolderLock:leaveIfLocked()
    local fc = self.ui.file_chooser
    if not fc then return end
    local folder = protectedFolderFor(fc.path)
    if not folder or unlocked[folder] then return end
    logger.info("FolderLock: leaving", folder)
    fc:changeToPath(parentDir(folder))
end

-- Note: there is deliberately no onSuspend handler. Locking on sleep hangs off the
-- Screensaver:setup patch instead, because Kindle never broadcasts a Suspend event on the
-- power-button path -- see armWakeupPrompt.

function FolderLock:addToMainMenu(menu_items)
    menu_items.folderlock = {
        text = _("Folder lock"),
        sorting_hint = "more_tools",
        sub_item_table_func = function() return self:getSubMenu() end,
    }
end

function FolderLock:getCurrentFolder()
    local fc = self.ui.file_chooser
    return fc and normalize(fc.path) or nil
end

function FolderLock:countFolders()
    local n = 0
    for _k in pairs(getFolders()) do
        n = n + 1
    end
    return n
end

function FolderLock:protectCurrentFolder()
    local path = self:getCurrentFolder()
    if not path then return end
    -- The user is standing in it right now, so count it as unlocked: bouncing them out of
    -- the folder they just protected would be rude. It re-locks as soon as they leave.
    unlocked[path] = true
    self:protectFolderWithPin(path)
end

function FolderLock:unprotectFolder(folder)
    askPin(_("Enter the PIN to remove protection"), function()
        local folders = getFolders()
        folders[folder] = nil
        saveFolders(folders)
        unlocked[folder] = nil
        UIManager:show(InfoMessage:new{
            text = T(_("%1 is no longer protected."), basename(folder)),
            timeout = 2,
        })
    end)
end

function FolderLock:getFolderListMenu()
    local items = {}
    local sorted = {}
    for folder in pairs(getFolders()) do
        table.insert(sorted, folder)
    end
    table.sort(sorted)
    for i = 1, #sorted do
        local folder = sorted[i]
        table.insert(items, {
            text = folder,
            keep_menu_open = true,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = T(_("Remove protection from %1?"), folder),
                    ok_text = _("Remove"),
                    ok_callback = function()
                        self:unprotectFolder(folder)
                    end,
                })
            end,
        })
    end
    if #items == 0 then
        table.insert(items, {
            text = _("No protected folders yet"),
            enabled = false,
        })
    end
    return items
end

function FolderLock:getSubMenu()
    local current = self:getCurrentFolder()
    local current_protected = current and protectedFolderFor(current) == current

    return {
        {
            text = hasPin() and _("Change PIN") or _("Set PIN"),
            keep_menu_open = true,
            callback = function()
                if hasPin() then
                    askPin(_("Enter the current PIN"), function()
                        askNewPin()
                    end)
                else
                    askNewPin()
                end
            end,
        },
        {
            text = _("Protect this folder"),
            keep_menu_open = true,
            -- Only meaningful in the file manager: ReaderUI has no file_chooser.
            enabled_func = function()
                return current ~= nil and not current_protected
            end,
            -- protectCurrentFolder() walks through creating a PIN when there is none.
            callback = function()
                self:protectCurrentFolder()
            end,
        },
        {
            text_func = function()
                return T(_("Protected folders (%1)"), self:countFolders())
            end,
            sub_item_table_func = function() return self:getFolderListMenu() end,
        },
        {
            text = _("Ask for the PIN after waking up"),
            help_text = _("When off, waking up puts you back where you were and protected folders stay unlocked for that session."),
            checked_func = askPinOnWakeupEnabled,
            keep_menu_open = true,
            callback = function()
                local s = getSettings()
                if askPinOnWakeupEnabled() then
                    s:makeFalse("ask_pin_on_wakeup")
                else
                    s:makeTrue("ask_pin_on_wakeup")
                end
                s:flush()
            end,
        },
        {
            text = _("Hide cover of protected books when suspended"),
            help_text = _("Shows one of KOReader's default backgrounds instead, so the sleep screen does not give away what you were reading."),
            checked_func = hideCoverEnabled,
            keep_menu_open = true,
            callback = function()
                local s = getSettings()
                if hideCoverEnabled() then
                    s:makeFalse("hide_cover_when_suspended")
                else
                    s:makeTrue("hide_cover_when_suspended")
                end
                s:flush()
            end,
        },
        {
            text = _("Lock now"),
            keep_menu_open = true,
            enabled_func = function()
                return next(unlocked) ~= nil
            end,
            callback = function()
                unlocked = {}
                -- Locking while standing inside one has to walk out of it too, otherwise
                -- the listing stays on screen until the next navigation.
                self:leaveIfLocked()
                UIManager:show(InfoMessage:new{
                    text = _("Protected folders are locked again."),
                    timeout = 2,
                })
            end,
        },
    }
end

return FolderLock
