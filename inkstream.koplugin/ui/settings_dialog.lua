-- Settings popup: toggle cover display per screen, choose the live books folder,
-- check for updates (the title shows the installed version).
-- Reopens itself after each change so the button labels stay current.
local UIManager         = require("ui/uimanager")
local InfoMessage       = require("ui/widget/infomessage")
local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
local Settings          = require("settings")

local SettingsDialog = {}
local _dlg = nil

local function on_off(key)
    return Settings:get(key) and "ON" or "OFF"
end

-- Current live books folder (the setting, or the KOReader home folder).
local function live_dir()
    local ok, Epub = pcall(require, "core.epub")
    local home = ok and Epub.home_dir() or "."
    return Settings:get("live_books_dir") or home
end

local function live_dir_label()
    local ok, filemanagerutil = pcall(require, "apps/filemanager/filemanagerutil")
    local dir = live_dir()
    if ok and filemanagerutil then dir = filemanagerutil.abbreviate(dir) end
    return dir
end

-- Move every live book into the chosen folder and report what happened.
local function move_live_books(new_dir)
    Settings:set("live_books_dir", new_dir)

    local LiveBook = require("core.livebook")
    local open_file
    local ok_r, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok_r and ReaderUI.instance and ReaderUI.instance.document then
        open_file = ReaderUI.instance.document.file
    end

    local moved, skipped = LiveBook.move_live_books(new_dir, open_file)

    local text = "Moved " .. #moved .. " live book" .. (#moved == 1 and "" or "s")
        .. " to " .. live_dir_label() .. "."
    if #skipped > 0 then
        text = text .. "\nSkipped:\n" .. table.concat(skipped, "\n")
    end
    UIManager:show(InfoMessage:new{ text = text, timeout = #skipped > 0 and 6 or 4 })
end

local function choose_live_folder()
    local PathChooser = require("ui/widget/pathchooser")
    UIManager:show(PathChooser:new{
        path             = live_dir(),
        select_directory = true,
        select_file      = false,
        show_files       = false,
        onConfirm        = function(path)
            if path ~= live_dir() then
                move_live_books(path)
            end
            SettingsDialog.show()
        end,
    })
end

-- Label of the "New books" row for the current book_mode setting.
local function book_mode_label()
    local mode = Settings:get("book_mode") or "ask"
    if mode == "window" then return "Always window" end
    if mode == "full"  then return "Always download all" end
    return "Ask every time"
end

-- Choice dialog for the chapters-per-volume setting. The note in the title
-- spells out that only novels started after the change are affected.
local function choose_volume_size()
    local options = { 100, 200, 300, 400, 500, 750, 1000 }
    local buttons = {}
    for _, n in ipairs(options) do
        local v = n
        table.insert(buttons, {{
            text     = tostring(v) .. " chapters",
            callback = function()
                Settings:set("volume_size", v)
                SettingsDialog.show()
            end,
        }})
    end
    UIManager:show(ButtonDialogTitle:new{
        title   = "Chapters per volume\n(applies to novels started after the change; existing novels keep their size)",
        buttons = buttons,
    })
end

function SettingsDialog.show()
    if _dlg then UIManager:close(_dlg) end

    _dlg = ButtonDialogTitle:new{
        title   = "Inkstream Settings  ·  v" .. (_G.INKSTREAM_VERSION or "?"),
        buttons = {
            {
                {
                    text     = "Covers · Library Page: " .. on_off("covers_library"),
                    callback = function()
                        Settings:toggle("covers_library")
                        SettingsDialog.show()
                    end,
                },
            },
            {
                {
                    text     = "Covers · Browse Page: " .. on_off("covers_browse"),
                    callback = function()
                        Settings:toggle("covers_browse")
                        SettingsDialog.show()
                    end,
                },
            },
            {
                {
                    text     = "Covers · Detail Page: " .. on_off("covers_detail"),
                    callback = function()
                        Settings:toggle("covers_detail")
                        SettingsDialog.show()
                    end,
                },
            },
            {
                {
                    text     = "Live books folder: " .. live_dir_label(),
                    callback = choose_live_folder,
                },
            },
            {
                {
                    text     = "New books: " .. book_mode_label(),
                    callback = function()
                        -- Cycle: ask → window → full → ask.
                        local mode = Settings:get("book_mode") or "ask"
                        local next_mode = mode == "ask" and "window"
                            or mode == "window" and "full" or "ask"
                        Settings:set("book_mode", next_mode)
                        SettingsDialog.show()
                    end,
                },
            },
            {
                {
                    text     = "Chapters per volume: "
                        .. tostring(Settings:get("volume_size") or 200),
                    callback = choose_volume_size,
                },
            },
            {
                {
                    text     = "Check for updates",
                    callback = function()
                        UIManager:close(_dlg)
                        _dlg = nil
                        require("core.updater").checkNow()
                    end,
                },
            },
            {
                {
                    text     = "Close",
                    callback = function()
                        UIManager:close(_dlg)
                        _dlg = nil
                    end,
                },
            },
        },
    }
    UIManager:show(_dlg)
end

return SettingsDialog