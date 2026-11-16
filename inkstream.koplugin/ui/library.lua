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

local _task = nil  -- running chapter check (one at a time)

local function rebuild()
    require("ui.main_widget").rebuild_current()
end

-- Apply the subprocess's per-novel results on the UI thread: the Library's
-- chapter total (DB.update also recounts the [+N new] badge), plus the live
-- state of novels that already have a live book. Window and full mode both
-- get the fresh chapter cache and total (neither keeps a stale state.total);
-- full mode also queues its new chapters for download.
local function apply_check_results(results)
    local LiveBook   = require("core.livebook")
    local Downloader = require("core.downloader")
    local updated    = 0
    for _, res in ipairs(results) do
        local novel = DB.find(res.source_id, res.path)
        if novel then
            local old_total = novel.total_chapters or 0
            if res.total ~= old_total then
                DB.update(res.source_id, res.path,
                    { total_chapters = res.total })
                updated = updated + 1
            end
            -- The child sends chapters for exactly the live books with new
            -- chapters, so the cache can be refreshed without a second fetch.
            if res.total > 0 and res.total > old_total and res.chapters then
                local state = LiveBook.state_for(res.source_id, res.path)
                if state then
                    DB.saveChapterCache(res.source_id, res.path,
                        res.chapters, res.total)
                    state.total = res.total
                    LiveBook.save_state(state)
                    if state.mode == "full" then
                        Downloader.enqueue(state.key)
                        Downloader.tick()
                    end
                end
            end
        end
    end
    return updated
end

-- The fetches run in a BgTask subprocess: parsing every tracked novel on the
-- UI thread froze the whole reader for as long as the check took.
local function do_refresh_confirmed()
    if _task then return end

    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenConnected(function()
        if _task then return end

        local jobs = {}
        for _, novel in ipairs(DB.getAll()) do
            jobs[#jobs + 1] = {
                source_id = novel.source_id,
                path      = novel.path,
                old_total = novel.total_chapters or 0,
            }
        end

        -- Parent loads extensions before the fork so the child inherits them.
        require("core.extmgr").ensure_init()

        local loading = InfoMessage:new{ text = "Checking for updates…" }
        UIManager:show(loading)

        local BgTask = require("core.bgtask")
        _task = BgTask.start("check_updates", BgTask.child(function()
            local ExtMgr   = require("core.extmgr")
            local LiveBook = require("core.livebook")
            local out = {}
            for _, job in ipairs(jobs) do
                local ext = ExtMgr.get(job.source_id)
                if ext then
                    local ok, info = pcall(ext.parseNovel, ext, job.path)
                    -- An empty chapter list means the fetch failed (e.g.
                    -- NovelFull's chapter-list request), not that the novel
                    -- lost its chapters: skip it so the stored total stays.
                    local total = ok and info and info.chapters
                        and #info.chapters or 0
                    if total > 0 then
                        local res = {
                            source_id = job.source_id,
                            path      = job.path,
                            total     = total,
                        }
                        if total > 0 and total > job.old_total
                                and LiveBook.state_for(job.source_id, job.path) then
                            res.chapters = info.chapters
                        end
                        out[#out + 1] = res
                    end
                end
            end
            return { results = out }
        end), function(data)
            _task = nil
            UIManager:close(loading)
            if not data or not data.results then
                UIManager:show(InfoMessage:new{
                    text = "Could not check for new chapters.", timeout = 3 })
                return
            end
            local updated = apply_check_results(data.results)
            UIManager:show(InfoMessage:new{
                text    = updated > 0
                    and (updated .. " novel(s) have new chapters!")
                    or  "No new chapters found.",
                timeout = 3,
            })
            rebuild()
        end)

        if not _task then
            UIManager:close(loading)
            UIManager:show(InfoMessage:new{
                text = "Could not check for new chapters.", timeout = 3 })
        end
    end)
end

local function do_refresh()
    if _task then
        UIManager:show(InfoMessage:new{
            text = "A chapter check is already running.", timeout = 2 })
        return
    end
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
