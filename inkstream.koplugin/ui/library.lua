-- Library screen: the tracked novels list. "Check for new chapters" is the
-- first (bold) row; novel rows open the novel screen and support
-- hold-to-untrack. When covers_library is on, each row shows a cover
-- thumbnail on the left (the stored cover URL, falling back to the older
-- source+path cover cache for novels tracked before the URL was saved).
local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox  = require("ui/widget/confirmbox")
local DB          = require("core.db")
local Settings    = require("settings")
local Covers      = require("core.covers")

local Library = {}
Library.on_novel_tap = nil

local _fetch_id = 0

local function rebuild()
    require("ui.main_widget").rebuild_current()
end

local function do_refresh_confirmed()
    _fetch_id = _fetch_id + 1
    local my_id = _fetch_id

    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenConnected(function()
        if my_id ~= _fetch_id then return end

        local ExtMgr  = require("core.extmgr")
        local loading = InfoMessage:new{ text = "Checking for updates…" }
        UIManager:show(loading)
        UIManager:scheduleIn(0.1, function()
            if my_id ~= _fetch_id then
                UIManager:close(loading)
                return
            end

            local novels  = DB.getAll()
            local updated = 0
            for _, novel in ipairs(novels) do
                local ext = ExtMgr.get(novel.source_id)
                if ext then
                    local ok, info = pcall(ext.parseNovel, ext, novel.path)
                    if ok and info then
                        local new_total = info.chapters and #info.chapters or 0
                        if new_total ~= (novel.total_chapters or 0) then
                            DB.update(novel.source_id, novel.path, { total_chapters = new_total })
                            updated = updated + 1
                        end
                        -- Full-mode live novels: fresh chapter cache and
                        -- download the new chapters in the background.
                        if new_total > 0 and new_total > (novel.total_chapters or 0) then
                            local LiveBook = require("core.livebook")
                            local state = LiveBook.state_for(novel.source_id, novel.path)
                            if state and state.mode == "full" then
                                DB.saveChapterCache(novel.source_id, novel.path,
                                    info.chapters, new_total)
                                state.total = new_total
                                LiveBook.save_state(state)
                                local Downloader = require("core.downloader")
                                Downloader.enqueue(state.key)
                                Downloader.tick()
                            end
                        end
                    end
                end
            end
            UIManager:close(loading)
            UIManager:show(InfoMessage:new{
                text    = updated > 0
                    and (updated .. " novel(s) have new chapters!")
                    or  "No new chapters found.",
                timeout = 3,
            })
            rebuild()
        end)
    end)
end

local function do_refresh()
    UIManager:show(ConfirmBox:new{
        text        = "This checks every tracked novel for new chapters.\n\nThe more novels you have tracked, the longer this takes. To update a specific novel only, open it individually instead.\n\nContinue?",
        ok_text     = "Refresh All",
        cancel_text = "Cancel",
        ok_callback = do_refresh_confirmed,
    })
end

function Library.build_screen()
    local InkstreamUI = require("ui.main_widget")
    local novels = DB.getByFilter("all")
    local items  = {}

    -- First row: the former ☰ action, now a visible (bold) list row.
    table.insert(items, {
        text     = "↻ Check for new chapters",
        bold     = true,
        callback = do_refresh,
    })

    if #novels == 0 then
        table.insert(items, {
            text     = "No novels tracked yet — go to Browse",
            dim      = true,
            callback = function() InkstreamUI.show("browse") end,
        })
    else
        local cover_urls = {}
        for _, n in ipairs(novels) do
            local novel = n
            local new   = novel.new_chapters or 0
            local badge = new > 0 and ("  [+" .. new .. " new]") or ""
            local ch    = novel.total_chapters or 0
            local entry = {
                text = (novel.title or "Unknown") .. badge,
                subtitle = novel.author,
                mandatory = ch .. " ch",
                bold = new > 0,
                callback = function()
                    if Library.on_novel_tap then Library.on_novel_tap(novel) end
                end,
                hold_callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = 'Untrack "' .. (novel.title or "?") .. '"?',
                        ok_callback = function()
                            DB.untrack(novel.source_id, novel.path)
                            rebuild()
                        end,
                    })
                end,
            }
            if Settings:get("covers_library") then
                if novel.cover and novel.cover ~= "" then
                    entry.cover_url = novel.cover
                    cover_urls[#cover_urls + 1] = novel.cover
                else
                    entry.cover_data = DB.loadCoverCache(novel.source_id, novel.path)
                end
            end
            table.insert(items, entry)
        end
        Covers.request(cover_urls, rebuild)
    end

    return { title = "Library", items = items, items_per_page = 8 }
end

return Library
