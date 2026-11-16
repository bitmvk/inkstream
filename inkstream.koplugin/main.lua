-- Inkstream — main plugin entry point.
_G.INKSTREAM_VERSION = "1.2.3"

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")

local plugin_dir = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\][^/\\]+$") or "."
package.path = plugin_dir .. "/?.lua;"
    .. plugin_dir .. "/?/init.lua;"
    .. package.path

local Event     = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local logger    = require("logger")
local Live      = require("core.live")
local LiveBook  = require("core.livebook")
local BgTask    = require("core.bgtask")
local DB        = require("core.db")

-- Close-all helper: shuts every Inkstream widget
local function close_all()
    local InkstreamUI = package.loaded["ui.main_widget"]
    if InkstreamUI then pcall(InkstreamUI.close) end
end
_G.inkstream_close_all = close_all

local _ready = false

-- Turn Wi-Fi on (no prompt, whatever KOReader's Wi-Fi setting says) and run
-- callback once connected. If Wi-Fi cannot be turned on, nothing happens and
-- Inkstream stays open for offline use. Devices that manage Wi-Fi themselves
-- (Android, desktop) are left alone.
local function go_online(callback)
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr:isConnected() then return callback() end
    if not require("device"):hasWifiToggle() then return end
    NetworkMgr:turnOnWifiAndWaitForConnection(callback)
end

local function open_inkstream()
    local ok, err = pcall(function()
        local InkstreamUI = require("ui.main_widget")
        local Library  = require("ui.library")
        local Browse   = require("ui.browse")
        local Detail   = require("ui.detail")
        local ExtMgr   = require("core.extmgr")

        if not _ready then
            ExtMgr.ensure_init()

            -- Wire the root screen builders (the Sources screen is pushed from
            -- Browse, so it has no root).
            InkstreamUI.set_root_builder("library", function() return Library.build_screen() end)
            InkstreamUI.set_root_builder("browse",  function() return Browse.build_screen()  end)

            -- Tapping a novel (library or browse) pushes the novel screen and fetches it.
            Library.on_novel_tap = function(novel)
                Detail.open(novel.source_id, novel.path)
            end
            Browse.on_novel_tap = function(source_id, novel_meta)
                Detail.open(source_id, novel_meta.path or novel_meta.sourceUrl or "")
            end

            _ready = true
        end

        InkstreamUI.show("library")
        -- Protected: a Wi-Fi failure must never take Inkstream down with it.
        pcall(go_online, function() require("core.updater").autoCheck() end)
    end)

    if not ok then
        UIManager:show(InfoMessage:new{
            text    = "Inkstream failed to open:\n" .. tostring(err),
            timeout = 6,
        })
    end
end

-- ── Live reading (reader-side) ────────────────────────────────────────────────
-- KOReader instantiates this plugin for both FileManager and ReaderUI; all live
-- code below acts only when self.ui.document is a live book from the index.

local _live = nil  -- session state for the open live book:
                   -- { state, chapters, cur, vol, vol_front, last_fragment,
                   --   refreshed_end, task }

local function live_doc_file(self)
    if not self.ui or not self.ui.document then return nil end
    return self.ui.document.file
end

-- Run a background subprocess task tied to the open live document (see
-- core/bgtask.lua): the task is aborted when the document closes or another
-- file is opened meanwhile.
local function start_bg_task(self, kind, child_fn, done_cb)
    if not _live or _live.task then return end  -- never two tasks at once
    local state = _live.state
    local task = BgTask.start(kind, child_fn, function(data)
        if _live then _live.task = nil end
        done_cb(data)
    end, function()
        -- Abort when the document closed or another file opened meanwhile
        -- (matched by key, since full mode spans several volume files).
        local file = live_doc_file(self)
        return file ~= nil and LiveBook.index_lookup(file) == state.key
    end)
    _live.task = task
end

-- Load installed extensions (idempotent) in the parent process before forking
-- a fetch subprocess, so the child inherits the loaded extension tables and
-- ExtMgr.get() works even when the book was opened straight from the file
-- browser (where open_inkstream() never ran).
local function ensure_extensions()
    require("core.extmgr").ensure_init()
end

-- ── Refill: download the chapters missing from the new window in a
-- subprocess, then rebuild the EPUB via reloadDocument and restore position.
-- Works in both directions: the missing set is whatever falls outside the
-- current window, be it before or after it.

local function start_refill(self, cur)
    local live     = _live
    if not live or live.task then return end
    local state, chapters = live.state, live.chapters
    if not chapters or #chapters == 0 then return end
    local total = #chapters
    if not (Live.needs_refill(cur, state.win_last, total)
            or Live.needs_refill_back(cur, state.win_first)) then
        return
    end

    local nf, nl = Live.plan_window(total, cur, Live.BEHIND, Live.AHEAD)
    local missing = {}  -- chapter paths outside the current window
    for idx = nf, nl do
        if idx < state.win_first or idx > state.win_last then
            local ch = chapters[idx]
            if ch then
                table.insert(missing, ch.path or ch.sourceUrl or ("#" .. idx))
            end
        end
    end

    local source_id, novel_path = state.source_id, state.novel_path
    local old_first, old_last   = state.win_first, state.win_last
    local center                = cur

    ensure_extensions()  -- parent loads extensions before the fork below

    start_bg_task(self, "refill", BgTask.child(function()
        local ExtMgr = require("core.extmgr")
        local ext = ExtMgr.get(source_id)
        local result = {}
        for _, p in ipairs(missing) do
            local content
            if ext then
                local ok, html = pcall(ext.parseChapter, ext, p)
                content = ok and html or nil
            end
            result[p] = content  -- nil on failure, so the parent can tell them apart
        end
        return result
    end), function(data)
        -- BgTask.child reports { ok = false, error = ... } when its body throws.
        if not data or data.ok == false then
            UIManager:show(InfoMessage:new{
                text = "Inkstream: chapter fetch failed.", timeout = 3 })
            return
        end

        -- Assemble the new window: reuse cached chapters, use fetched ones.
        -- Failed chapters keep the placeholder for this build but are not
        -- cached; build_window owns the cache write and pruning.
        local map = LiveBook.load_window_chapters(state.key)
        local window_items = {}
        for idx = nf, nl do
            local ch   = chapters[idx]
            local path = ch and (ch.path or ch.sourceUrl or ("#" .. idx)) or ("#" .. idx)
            local entry = map[path]
            if not entry or not entry.content then
                local fetched = data[path]
                entry = {
                    title   = ch and (ch.name or ch.title) or ("Chapter " .. idx),
                    content = fetched or "<p>Could not load this chapter.</p>",
                }
            end
            table.insert(window_items, { title = entry.title, content = entry.content })
        end

        local cover_data, cover_ext = LiveBook.load_cover(state)
        -- Capture the exact position now; the callback below runs after the
        -- document is closed.
        local xp = self.ui.document:getXPointer()
        local added = math.max(0, nl - old_last) + math.max(0, old_first - nf)
        self.ui:reloadDocument(function()
            LiveBook.rebuild_window_sidecar(state, chapters, center, nf, nl,
                window_items, cover_data, cover_ext, xp)
        end)
        UIManager:show(InfoMessage:new{ text = "+" .. added .. " chapters", timeout = 2 })
        logger.dbg("Inkstream/Live: refilled window", nf, "-", nl)
    end)
end

-- ── Refresh the full chapter list (used when the reader reaches the last
-- known chapter, or the chapter cache is missing).

local function start_refresh_list(self)
    local live = _live
    if not live or live.task then return end
    live.refreshed_end = true  -- stop page turns queueing a retry while connecting
    local state      = live.state
    local source_id  = state.source_id
    local novel_path = state.novel_path
    local old_total  = state.total or 0
    local key        = state.key

    -- Check the source online first: go_online turns Wi-Fi on without
    -- prompting (or does nothing on devices that manage Wi-Fi themselves).
    -- The check itself runs in the callback once connected.
    go_online(function()
        -- The book may have closed or changed while connecting.
        if not _live or _live.state.key ~= key or _live.task then return end

        ensure_extensions()  -- parent loads extensions before the fork below

        start_bg_task(self, "refresh_list", BgTask.child(function()
            local ExtMgr    = require("core.extmgr")
            local LiveBookC = require("core.livebook")
            local ext = ExtMgr.get(source_id)
            local chapters = LiveBookC.refresh_chapter_list(ext, source_id, novel_path)
            return { total = chapters and #chapters or nil }
        end), function(data)
            local total = data and data.total
            if not total then
                _live.refreshed_end = false  -- allow a retry on the next page turn
                UIManager:show(InfoMessage:new{
                    text = "Inkstream: could not refresh chapter list.", timeout = 3 })
                return
            end
            _live.chapters = LiveBook.chapter_list(source_id, novel_path)
            if total <= old_total then
                UIManager:show(InfoMessage:new{ text = "No new chapters yet", timeout = 3 })
                return
            end
            _live.refreshed_end = false  -- allow another check at the new end
            state.total = total
            LiveBook.save_state(state)
            -- Keep the Library's chapter total (and so its new-chapter badge)
            -- in step with the chapter list just fetched.
            DB.update(source_id, novel_path, { total_chapters = total })
            UIManager:show(InfoMessage:new{
                text = (total - old_total) .. " new chapter(s) found", timeout = 3 })
            if state.mode == "full" then
                -- New chapters: the downloader appends them to the last volume
                -- (until it reaches volume_size, then a new volume starts).
                local Downloader = require("core.downloader")
                Downloader.enqueue(state.key)
                Downloader.tick()
            elseif Live.needs_refill(_live.cur, state.win_last, total) then
                start_refill(self, _live.cur)
            end
        end)
    end)
end

-- Manual "Check for new chapters" (reader menu): runs the same refresh as the
-- automatic end-of-book check, but on demand and regardless of refreshed_end,
-- so it works mid-book and in both window and full modes.
local function check_new_chapters(self, state)
    if not _live or _live.state.key ~= state.key then return end
    if _live.task then
        UIManager:show(InfoMessage:new{
            text = "Inkstream is busy, try again in a moment.", timeout = 3 })
        return
    end
    UIManager:show(InfoMessage:new{
        text = "Checking for new chapters…", timeout = 2 })
    start_refresh_list(self)
end

-- ── "Go to chapter…" menu ─────────────────────────────────────────────────────

-- Full mode: chapter idx lives in volume volume_of(idx). Jump inside the
-- open volume, switchDocument to another volume (landing on the chapter
-- start), or report that the chapter is not downloaded yet.
local function goto_chapter_full(self, state, idx)
    local V = state.volume_size
    local d = state.downloaded or 0
    if idx > d then
        UIManager:show(InfoMessage:new{
            text = "Chapter " .. idx .. " will be available when the download"
                .. " reaches it (" .. d .. "/" .. (state.total or 0) .. ").",
            timeout = 3 })
        return
    end
    local v = Live.volume_of(idx, V)
    if _live and _live.vol == v then
        -- Same volume: plain jump.
        local first = Live.volume_range(v, V, d)
        local xp = Live.chapter_start_xpointer(_live.vol_front, first, idx)
        self.ui:handleEvent(Event:new("GotoXPointer", xp, xp))
        return
    end
    local path = LiveBook.volume_path_for(state, v)
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if ok_ds then
        local front = (state.volumes and state.volumes[v]
            and state.volumes[v].front) or 0
        local first = Live.volume_range(v, V, d)
        local ds = DocSettings:open(path)
        LiveBook.save_position(ds,
            Live.chapter_start_xpointer(front, first, idx))
        ds:flush()
    end
    self.ui:switchDocument(path)
end

local function goto_chapter(self, state, chapters, idx)
    if state.mode == "full" then
        goto_chapter_full(self, state, idx)
        return
    end
    if idx >= state.win_first and idx <= state.win_last then
        -- Inside the current window: plain jump.
        local xp = Live.chapter_start_xpointer(state.front or 0, state.win_first, idx)
        self.ui:handleEvent(Event:new("GotoXPointer", xp, xp))
        return
    end
    -- Outside the window: recenter (blocking fetch with a progress message).
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenConnected(function()
        local info = InfoMessage:new{ text = "Fetching chapters…" }
        UIManager:show(info)
        UIManager:scheduleIn(0.1, function()
            local ExtMgr = require("core.extmgr")
            ExtMgr.ensure_init()
            local ext = ExtMgr.get(state.source_id)
            local cover_data, cover_ext = LiveBook.load_cover(state)
            local ok, first, last, items = pcall(LiveBook.plan_and_fetch,
                ext, state, chapters, idx)
            UIManager:close(info)
            if not ok or not first then
                UIManager:show(InfoMessage:new{
                    text = "Could not fetch chapters.", timeout = 3 })
                return
            end
            self.ui:reloadDocument(function()
                LiveBook.rebuild_window_sidecar(state, chapters, idx,
                    first, last, items, cover_data, cover_ext, nil)
            end)
        end)
    end)
end

local function show_goto_chapter_menu(self, state)
    local chapters = _live and _live.chapters
    if not chapters then
        chapters = LiveBook.chapter_list(state.source_id, state.novel_path)
    end
    if not chapters or #chapters == 0 then
        UIManager:show(InfoMessage:new{
            text = "Chapter list unavailable.", timeout = 3 })
        return
    end
    local Menu = require("ui/widget/menu")
    local items = {}
    local cur = state.cur or state.win_first
    local furthest = state.furthest or cur
    if furthest > cur then
        -- Reading back through older chapters: offer a quick return.
        table.insert(items, {
            text      = "Back to Ch. " .. furthest .. " (furthest)",
            mandatory = "Furthest",
            callback  = function()
                goto_chapter(self, state, chapters, furthest)
            end,
        })
    end
    for i, ch in ipairs(chapters) do
        local idx = i
        table.insert(items, {
            text      = ch.name or ch.title or ("Chapter " .. i),
            mandatory = "Ch." .. i,
            callback  = function()
                goto_chapter(self, state, chapters, idx)
            end,
        })
    end
    local title = state.title or "Chapters"
    -- Declared first so close_callback's closure sees the menu (a
    -- `local menu = Menu:new{...}` would capture an undefined global).
    local menu
    menu = Menu:new{
        title      = title,
        item_table = items,
        -- Menu:onMenuSelect only closes via close_callback.
        close_callback = function()
            UIManager:close(menu)
        end,
    }
    UIManager:show(menu)
    -- Open on the page containing the current chapter (offset by the
    -- optional "Back to furthest" item).
    menu:switchItemTable(title, items, cur + (#items - #chapters))
end

-- ── Plugin instance ───────────────────────────────────────────────────────────

local Inkstream = WidgetContainer:extend{
    name        = "inkstream",
    fullname    = "Inkstream",
    description = "Web novel tracker and EPUB exporter",
    is_doc_only = false,
}

function Inkstream:init()
    self.ui.menu:registerToMainMenu(self)
    local ok, Dispatcher = pcall(require, "dispatcher")
    if ok and Dispatcher then
        Dispatcher:init()
        Dispatcher:registerAction("inkstream_open", {
            category   = "none",
            event      = "InkstreamOpen",
            title      = "Inkstream: Open",
            general    = true,
        })
    end
    -- Resume unfinished full-mode downloads. Runs once per KOReader session
    -- (both the FileManager and the Reader instantiate this plugin).
    require("core.downloader").resume_once()
end

function Inkstream:onInkstreamOpen()
    open_inkstream()
    return true
end

-- Launcher for other plugins: Simple UI's "KOReader plugin" Quick Action
-- looks for a method named launch/show/open to call.
function Inkstream:launch()
    open_inkstream()
end

-- Resume queued downloads when KOReader regains a connection. The downloader
-- stops its polling chain while offline (see core/downloader.lua); this is
-- the only path that restarts it, on KOReader's NetworkConnected event.
function Inkstream:onNetworkConnected()
    require("core.downloader").resume()
end

function Inkstream:addToMainMenu(menu_items)
    menu_items["inkstream"] = {
        text         = "Inkstream",
        sorting_hint = "tools",
        callback     = open_inkstream,
    }

    -- Reader-only: chapter navigation for the open live book.
    local file = live_doc_file(self)
    if not file then return end
    local state = LiveBook.state_for_epub(file)
    if not state then return end
    menu_items.inkstream_go_to_chapter = {
        text         = "Go to chapter…",
        sorting_hint = "navi",
        callback     = function()
            show_goto_chapter_menu(self, state)
        end,
    }
    menu_items.inkstream_check_new_chapters = {
        text         = "Check for new chapters",
        sorting_hint = "navi",
        callback     = function()
            check_new_chapters(self, state)
        end,
    }
end

-- ── Reader lifecycle ──────────────────────────────────────────────────────────

function Inkstream:onReaderReady()
    local file = live_doc_file(self)
    if not file then return end
    local key, vol = LiveBook.index_lookup_volume(file)
    if not key then return end
    local state = LiveBook.load_state(key)
    if not state then return end

    local chapters = LiveBook.chapter_list(state.source_id, state.novel_path)
    _live = {
        state         = state,
        chapters      = chapters,
        cur           = state.cur or state.win_first,
        vol           = vol,   -- nil for window books
        vol_front     = nil,
        last_fragment = nil,
        refreshed_end = false,
        task          = nil,
    }

    -- Restore position is handled by KOReader; record which chapter we are in.
    local xp   = self.ui.document:getXPointer()
    local frag = Live.fragment_of(xp)
    if frag then _live.last_fragment = frag end
    local cur
    if vol then
        -- Full mode: chapter = (v-1)*V + (fragment - front).
        _live.vol_front = (state.volumes and state.volumes[vol]
            and state.volumes[vol].front) or 0
        cur = Live.volume_chapter_at(xp, _live.vol_front, vol, state.volume_size)
    else
        cur = Live.chapter_at(xp, state.front, state.win_first)
    end
    if cur then
        _live.cur = cur
        LiveBook.set_cur(state, cur)
        -- Reaching a chapter clears it from the Library's new-chapter badge.
        DB.markSeenUpTo(state.source_id, state.novel_path, cur)
    end

    if not chapters then
        start_refresh_list(self)  -- chapter cache missing: reload it
    elseif vol then
        -- Opening a fully-downloaded volume checks the source for new ones.
        local d = state.downloaded or 0
        if d >= state.total and not _live.refreshed_end then
            start_refresh_list(self)
        end
    elseif _live.cur == state.total and not _live.refreshed_end then
        start_refresh_list(self)  -- reopening at the end: check for new ones
    elseif Live.needs_refill(_live.cur, state.win_last, state.total) then
        start_refill(self, _live.cur)
    elseif Live.needs_refill_back(_live.cur, state.win_first) then
        start_refill(self, _live.cur)  -- reopened in the window's first chapter
    end
    logger.dbg("Inkstream/Live: ready ch=", tostring(_live.cur),
        "mode=", state.mode, "vol=", tostring(vol),
        "win=", state.win_first, "-", state.win_last, "total=", state.total)
end

-- Rebuild the open volume via reloadDocument. Appending downloaded chapters
-- never renumbers earlier DocFragments, so the reading position stays valid;
-- the front count can still change (e.g. the cover fetch failed), in which
-- case the saved xpointers are remapped (the old/new-front fix).
local function rebuild_open_volume(self)
    local live  = _live
    local state = live.state
    local vol   = live.vol
    local old_front = live.vol_front
    local xp = self.ui.document:getXPointer()

    local ok_b, new_front = LiveBook.build_full_volume(state, vol)
    if not ok_b then
        UIManager:show(InfoMessage:new{
            text = "Inkstream: could not update this volume.", timeout = 3 })
        return
    end
    state.pending_volume_rebuild = nil
    LiveBook.save_state(state)

    local path = LiveBook.volume_path_for(state, vol)
    self.ui:reloadDocument(function()
        local ok_ds, DocSettings = pcall(require, "docsettings")
        if not ok_ds then return end
        local ds = DocSettings:open(path)
        local first, last = Live.volume_range(vol, state.volume_size,
            state.downloaded or 0)
        local new_xp = Live.remap_xpointer(xp, old_front, new_front or 0,
            first, first, last)
        LiveBook.save_position(ds,
            new_xp or Live.chapter_start_xpointer(new_front or 0, first, first))
        local annotations = ds:readSetting("annotations")
        if type(annotations) == "table" then
            local kept = Live.remap_annotations(annotations, old_front,
                new_front or 0, first, first, last)
            ds:saveSetting("annotations", kept)
            ds:saveSetting("annotations_externally_modified", true)
        end
        ds:flush()
    end)
    UIManager:show(InfoMessage:new{ text = "Volume updated", timeout = 2 })
end

-- Full-mode page turn handling: deferred volume rebuild near the volume's
-- end, and a new-chapter check at the last downloaded chapter.
local function on_page_update_full(self, cur)
    local state = _live.state
    local d     = state.downloaded or 0
    if state.pending_volume_rebuild == _live.vol then
        -- Within 2 chapters of the end of the open volume: rebuild it now.
        local first, last = Live.volume_range(_live.vol, state.volume_size, d)
        if cur >= last - 1 then
            rebuild_open_volume(self)
            return
        end
    end
    -- Reached the last downloaded chapter: look for new ones at the source.
    if cur >= d and not _live.refreshed_end then
        start_refresh_list(self)
    end
end

function Inkstream:onPageUpdate()
    if not _live then return end
    local file = live_doc_file(self)
    if not file or LiveBook.index_lookup(file) ~= _live.state.key then return end

    local xp   = self.ui.document:getXPointer()
    local frag = Live.fragment_of(xp)
    if not frag or frag == _live.last_fragment then return end  -- only on change
    _live.last_fragment = frag

    local state = _live.state
    local cur
    if _live.vol then
        cur = Live.volume_chapter_at(xp, _live.vol_front, _live.vol,
            state.volume_size)
    else
        cur = Live.chapter_at(xp, state.front, state.win_first)
    end
    if not cur then return end  -- front matter
    _live.cur = cur
    LiveBook.set_cur(state, cur)
    -- Reaching a chapter clears it from the Library's new-chapter badge, even
    -- while a background task is running (hence before the task guard below).
    DB.markSeenUpTo(state.source_id, state.novel_path, cur)

    if _live.task then return end  -- one background task at a time

    if _live.vol then
        on_page_update_full(self, cur)
        return
    end

    local total = _live.chapters and #_live.chapters or state.total
    if cur == total and not _live.refreshed_end then
        start_refresh_list(self)  -- reached the last known chapter
    elseif _live.chapters and (Live.needs_refill(cur, state.win_last, total)
            or Live.needs_refill_back(cur, state.win_first)) then
        start_refill(self, cur)
    end
end

-- End of a full-mode volume: offer "Continue to Vol. v+1" when that volume
-- exists. ReaderStatus (a built-in module, registered before plugins) has
-- already shown KOReader's default end-of-book dialog for the live volume;
-- close it and show ours instead, so the user never sees two dialogs.
function Inkstream:onEndOfBook()
    if not _live or not _live.vol then return end
    local state = _live.state
    local v     = _live.vol
    local d     = state.downloaded or 0
    if v * state.volume_size >= d then return end  -- no next volume yet

    local top = UIManager:getTopmostVisibleWidget()
    if top and top.name == "end_document" then
        UIManager:close(top)
    end

    local ConfirmBox = require("ui/widget/confirmbox")
    local next_path  = LiveBook.volume_path_for(state, v + 1)
    UIManager:show(ConfirmBox:new{
        text        = "Continue to Vol. " .. (v + 1) .. "?",
        ok_text     = "Continue",
        ok_callback = function()
            local ok_ds, DocSettings = pcall(require, "docsettings")
            if ok_ds then
                local first = Live.volume_range(v + 1, state.volume_size, d)
                local front = (state.volumes and state.volumes[v + 1]
                    and state.volumes[v + 1].front) or 0
                local ds = DocSettings:open(next_path)
                LiveBook.save_position(ds,
                    Live.chapter_start_xpointer(front, first, first))
                ds:flush()
            end
            self.ui:switchDocument(next_path)
        end,
        cancel_text = "Stay here",
    })
    return true
end

function Inkstream:onCloseDocument()
    if _live then
        if _live.task then
            BgTask.terminate(_live.task)
            logger.dbg("Inkstream/Live: terminated background task")
        end
        -- A download batch skipped this volume because it was open: rebuild
        -- it now that the document is closed.
        local state = _live.state
        if state.mode == "full" and state.pending_volume_rebuild then
            LiveBook.build_full_volume(state, state.pending_volume_rebuild)
            state.pending_volume_rebuild = nil
            LiveBook.save_state(state)
        end
        _live = nil
    end
    -- The reader no longer holds a live volume: finish any pending
    -- window→full switch and continue queued downloads.
    require("core.downloader").resume()
end

return Inkstream
