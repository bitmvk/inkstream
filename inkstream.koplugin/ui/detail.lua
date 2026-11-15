-- Novel screen: a single list with Read/Continue, Back to furthest, About,
-- Track/Untrack, the mode and retry rows when applicable, "Chapter options…"
-- (select/export/refresh) and every chapter (tap to read, long-press to
-- toggle export selection). Live reading, mode switching and fetching below
-- stay as before.
local UIManager    = require("ui/uimanager")
local InfoMessage  = require("ui/widget/infomessage")
local ConfirmBox   = require("ui/widget/confirmbox")
local TextViewer   = require("ui/widget/textviewer")
local ImageViewer  = require("ui/widget/imageviewer")
local ButtonDialog = require("ui/widget/buttondialog")
local NetworkMgr   = require("ui/network/manager")
local ExtMgr       = require("core.extmgr")
local DB           = require("core.db")
local Live         = require("core.live")
local LiveBook     = require("core.livebook")

local function get_export_ui() return require("ui.export") end

local Detail = {}

local _source_id    = nil
local _novel_info   = nil
local _all_chapters = {}
local _selected     = {}
local _cover_bb     = nil
local _fetch_id     = 0  -- cancels stale in-flight fetches

local function close_all()
    if _G.inkstream_close_all then _G.inkstream_close_all() end
end

local function ch_path(ch, idx)
    return ch.path or ch.sourceUrl or tostring(idx)
end

local function count_selected()
    local n = 0
    for _ in pairs(_selected) do n = n + 1 end
    return n
end

local function select_all()
    _selected = {}
    for i, ch in ipairs(_all_chapters) do
        _selected[ch_path(ch, i)] = true
    end
end

local function deselect_all()
    _selected = {}
end

local function selected_chapters()
    local out = {}
    for i, ch in ipairs(_all_chapters) do
        if _selected[ch_path(ch, i)] then out[#out + 1] = ch end
    end
    return out
end

local function reset_state(source_id)
    _source_id    = source_id
    _selected     = {}
    _all_chapters = {}
    _novel_info   = nil
    if _cover_bb then _cover_bb:free(); _cover_bb = nil end
end

-- ── About / Cover ─────────────────────────────────────────────────────────────

local function show_about(info)
    local lines = {
        info.name or info.title or "Novel",
        "",
        "Author: " .. (info.author or "Unknown"),
        "Status: " .. (info.status or "?"),
        "Chapters: " .. #_all_chapters,
    }
    if info.summary and info.summary ~= "" then
        lines[#lines + 1] = ""
        lines[#lines + 1] = info.summary
    end

    -- Fold the separate Cover row into the About viewer as a "Cover" button.
    local buttons_table
    if _cover_bb then
        buttons_table = {
            {
                { text = "Cover", callback = function() show_cover(info) end },
            },
        }
    end

    UIManager:show(TextViewer:new{
        title         = info.name or info.title or "Novel",
        text          = table.concat(lines, "\n"),
        buttons_table = buttons_table,
    })
end

local function show_cover(info)
    if not _cover_bb then return end
    UIManager:show(ImageViewer:new{
        image            = _cover_bb,
        image_disposable = false,  -- Detail frees _cover_bb itself
        title_text       = info.name or info.title or "Novel",
        with_title_bar   = true,
    })
end

-- ── Chapter options dialog ────────────────────────────────────────────────────

local function show_chapter_options(info)
    local ext       = ExtMgr.get(_source_id)
    local sel_count = count_selected()
    local buttons   = {}
    local dlg

    table.insert(buttons, {{
        text     = "Select all (" .. #_all_chapters .. ")",
        callback = function()
            UIManager:close(dlg)
            select_all()
            Detail.rebuild(info, true)
        end,
    }})
    table.insert(buttons, {{
        text     = "Deselect all",
        callback = function()
            UIManager:close(dlg)
            deselect_all()
            Detail.rebuild(info, true)
        end,
    }})
    if sel_count > 0 then
        table.insert(buttons, {{
            text     = "Export (" .. sel_count .. " chapters)",
            callback = function()
                UIManager:close(dlg)
                if not ext then return end
                get_export_ui().show({
                    chapters       = selected_chapters(),
                    novel          = info,
                    source_id      = _source_id,
                    total_chapters = #_all_chapters,
                    fetch_fn       = function(path)
                        local ok, html = pcall(ext.parseChapter, ext, path)
                        return ok and html or nil
                    end,
                })
            end,
        }})
    end
    table.insert(buttons, {{
        text     = "Refresh chapter list",
        callback = function()
            UIManager:close(dlg)
            Detail.fetchForceRefresh(_source_id, info.path or "")
        end,
    }})
    table.insert(buttons, {{
        text     = "Close",
        callback = function() UIManager:close(dlg) end,
    }})

    dlg = ButtonDialog:new{ title = "Chapter options", buttons = buttons }
    UIManager:show(dlg)
end

-- ── Screen builder ────────────────────────────────────────────────────────────

function Detail.build_screen()
    local info = _novel_info
    if not info then
        return { title = "Novel", items = { { text = "Loading…", dim = true } } }
    end

    local live_state   = LiveBook.state_for(_source_id, info.path or "")
    local is_tracked   = DB.find(_source_id, info.path or "") ~= nil
    local exported_set = DB.getExportedChapterSet(_source_id, info.path or "")

    local items = {}

    -- Read / Continue reading
    table.insert(items, {
        text     = live_state and live_state.cur
            and ("Continue reading (Ch. " .. live_state.cur .. ")")
            or "Read",
        bold     = true,
        callback = function() Detail.start_live_reading(info, nil) end,
    })

    -- Reading back through older chapters: offer a quick return.
    if live_state and live_state.furthest and live_state.cur
       and live_state.furthest > live_state.cur then
        table.insert(items, {
            text     = "Back to furthest (Ch. " .. live_state.furthest .. ")",
            bold     = true,
            callback = function()
                Detail.start_live_reading(info, live_state.furthest)
            end,
        })
    end

    -- About (metadata + synopsis in a TextViewer; the cover is folded into
    -- that viewer as a "Cover" button when a cover was fetched).
    local meta_str = (info.author or "Unknown")
        .. "  ·  " .. (info.status or "?")
        .. "  ·  " .. #_all_chapters .. " ch"
    table.insert(items, {
        text     = "About — " .. meta_str,
        callback = function() show_about(info) end,
    })

    -- Track / Untrack.
    table.insert(items, {
        text     = is_tracked and "Untrack novel" or "Track novel",
        bold     = true,
        callback = function()
            if is_tracked then
                DB.untrack(_source_id, info.path or "")
                Detail.rebuild(info, true)
            elseif LiveBook.state_for(_source_id, info.path or "") then
                DB.track(Detail.track_fields(info))
                Detail.rebuild(info, true)
            else
                Detail.choose_and_start(info, nil, false)
            end
        end,
    })

    -- Mode row (when a live state exists) + Retry failed chapters.
    if live_state then
        local mode_label
        if live_state.mode == "full" then
            local failed_n = LiveBook.failed_count(live_state)
            mode_label = "Mode: Download all ("
                .. tostring(live_state.downloaded or 0) .. "/"
                .. tostring(live_state.total or 0) .. " chapters"
                .. (failed_n > 0 and (", " .. failed_n .. " failed") or "")
                .. ")"
        else
            mode_label = "Mode: Window"
        end
        table.insert(items, {
            text     = mode_label,
            bold     = true,
            callback = function() Detail.switch_mode(info, live_state) end,
        })

        if live_state.mode == "full" and LiveBook.failed_count(live_state) > 0 then
            table.insert(items, {
                text     = "Retry failed chapters",
                bold     = true,
                callback = function() Detail.retry_failed(info, live_state) end,
            })
        end
    end

    -- Chapter options (select / export / refresh).
    table.insert(items, {
        text     = "Chapter options…",
        bold     = true,
        callback = function() show_chapter_options(info) end,
    })

    -- Chapters.
    if #_all_chapters == 0 then
        table.insert(items, { text = "No chapters found", dim = true })
    else
        for i, ch in ipairs(_all_chapters) do
            local p         = ch_path(ch, i)
            local label     = ch.name or ch.title or ("Chapter " .. i)
            local inf       = info
            local is_exp    = exported_set[p] and true or false
            local is_sel    = _selected[p] and true or false
            local is_locked = ch.locked == true
            local prefix    = is_exp and "✓" or " "
            local display   = is_locked
                and (prefix .. " (locked) " .. label)
                or  (prefix .. (is_sel and " [x] " or " [ ] ") .. label)
            table.insert(items, {
                text      = display,
                mandatory = ch.chapter_number and ("Ch." .. ch.chapter_number) or nil,
                bold      = is_sel and not is_locked,
                dim       = is_locked,
                -- Tap: read this novel live, centred on this chapter.
                callback  = is_locked and nil or function()
                    UIManager:show(ConfirmBox:new{
                        text = "Read from here (Ch. "
                            .. tostring(ch.chapter_number or i) .. ")?",
                        ok_text     = "Read",
                        ok_callback = function()
                            Detail.start_live_reading(inf, i)
                        end,
                    })
                end,
                -- Long-press: toggle the chapter's export selection.
                hold_callback = is_locked and nil or function()
                    if _selected[p] then _selected[p] = nil
                    else _selected[p] = true end
                    Detail.rebuild(inf, true)
                end,
            })
        end
    end

    return { title = info.name or info.title or "Novel", items = items }
end

-- ── Rebuild / open ────────────────────────────────────────────────────────────

-- Rebuild the novel screen in place (partial is kept for API compatibility;
-- the Menu handles the repaint).
function Detail.rebuild(info, partial)
    require("ui.main_widget").rebuild_current()
end

-- Open a novel: reset the screen state, push its screen, then fetch.
function Detail.open(source_id, path)
    reset_state(source_id)
    require("ui.main_widget").push(function() return Detail.build_screen() end)
    Detail.fetch(source_id, path)
end


-- Clear chapter cache then re-fetch from scratch.
function Detail.fetchForceRefresh(source_id, path)
    DB.clearChapterCache(source_id, path)
    Detail.fetch(source_id, path)
end

-- Fields for DB.track, shared by the Track row and the live-start flow.
function Detail.track_fields(info)
    return {
        title          = info.name or info.title or "Novel",
        source_id      = _source_id,
        path           = info.path or "",
        cover          = info.cover,
        author         = info.author,
        status         = info.status,
        summary        = info.summary,
        total_chapters = #_all_chapters,
    }
end

-- Open a full-mode novel at chapter idx (nil = the saved position). A jump
-- (idx given) lands on the chapter start.
function Detail.open_full_at(state, idx)
    local V = state.volume_size
    local d = state.downloaded or 0
    local target = idx or state.cur or 1
    if target > d then
        UIManager:show(InfoMessage:new{
            text = "Chapter " .. target .. " will be available when the"
                .. " download reaches it (" .. d .. "/"
                .. (state.total or 0) .. ").",
            timeout = 3 })
        return
    end
    local v = Live.volume_of(target, V)
    local path = LiveBook.volume_path_for(state, v)
    local f = io.open(path, "rb")
    if f then
        f:close()
    else
        UIManager:show(InfoMessage:new{
            text = "This volume is still downloading (" .. d .. "/"
                .. (state.total or 0) .. " chapters).",
            timeout = 3 })
        return
    end
    -- A jump ("Back to furthest" / "Read from here"), or the first open of a
    -- volume with no saved position: land on the chapter start. (Continue
    -- otherwise keeps KOReader's saved position.)
    local DocSettings = require("docsettings")
    local ds = DocSettings:open(path)
    local front = (state.volumes and state.volumes[v]
        and state.volumes[v].front) or 0
    local first = Live.volume_range(v, V, d)
    if idx or (target > 1 and not ds:readSetting("last_xpointer")) then
        LiveBook.save_position(ds,
            Live.chapter_start_xpointer(front, first, target))
        ds:flush()
    end
    close_all()
    require("apps/reader/readerui"):showReader(path)
end

-- Full mode: create the state, enqueue the downloader, and tell the user
-- what happens next. start_idx (tapped chapter, "Read from here") is remembered
-- as the reading position; the volume opens once the download reaches it.
function Detail.start_full_reading(info, start_idx)
    local source_id  = _source_id
    local novel_path = info.path or ""
    local meta = {
        title     = info.name or info.title or "Novel",
        author    = info.author,
        summary   = info.summary,
        cover_url = info.cover,
    }
    NetworkMgr:runWhenConnected(function()
        local msg = InfoMessage:new{ text = "Preparing novel…" }
        UIManager:show(msg)
        UIManager:scheduleIn(0.1, function()
            local chapters = #_all_chapters > 0 and _all_chapters
                or LiveBook.chapter_list(source_id, novel_path)
            local ok_state, err = LiveBook.new_start_full(
                ExtMgr.get(_source_id), meta, source_id, novel_path, chapters)
            UIManager:close(msg)
            if not ok_state then
                UIManager:show(InfoMessage:new{
                    text    = "Could not start downloading: " .. tostring(err),
                    timeout = 4,
                })
                return
            end
            if start_idx then
                -- "Read from here": remember where to continue.
                LiveBook.set_cur(ok_state, start_idx)
                ok_state.open_when_ready = start_idx
                LiveBook.save_state(ok_state)
            end
            local Downloader = require("core.downloader")
            Downloader.enqueue(ok_state.key)
            Downloader.tick()
            if start_idx then
                UIManager:show(InfoMessage:new{
                    text = "Chapter " .. start_idx .. " will be available when"
                        .. " the download reaches it (0/" .. (ok_state.total or 0)
                        .. ").",
                    timeout = 4 })
            else
                UIManager:show(InfoMessage:new{
                    text = "Downloading all chapters in the background (volumes"
                        .. " of " .. tostring(ok_state.volume_size) .. ").",
                    timeout = 4 })
            end
            Detail.rebuild(info, true)
        end)
    end)
end

-- Window mode: create the window centred on start_idx (or chapter 1) and,
-- unless open=false, open it at the start of that chapter.
function Detail.start_window_reading(info, start_idx, open)
    local source_id  = _source_id
    local novel_path = info.path or ""
    local meta = {
        title     = info.name or info.title or "Novel",
        author    = info.author,
        summary   = info.summary,
        cover_url = info.cover,
    }
    NetworkMgr:runWhenConnected(function()
        local msg = InfoMessage:new{ text = "Preparing chapters…" }
        UIManager:show(msg)
        UIManager:scheduleIn(0.1, function()
            -- First fetch may block the UI; that is acceptable here.
            local center = start_idx or 1
            local ok_state, err = LiveBook.new_start(ExtMgr.get(_source_id),
                meta, source_id, novel_path, center, _all_chapters)
            UIManager:close(msg)
            if not ok_state then
                UIManager:show(InfoMessage:new{
                    text    = "Could not start reading: " .. tostring(err),
                    timeout = 4,
                })
                return
            end
            if open == false then
                -- Track Novel row: the book is created, not opened.
                Detail.rebuild(info, true)
                return
            end
            -- Open at the start of the requested chapter.
            local DocSettings = require("docsettings")
            local ds = DocSettings:open(ok_state.epub_path)
            LiveBook.save_position(ds,
                Live.chapter_start_xpointer(ok_state.front,
                    ok_state.win_first, center))
            ds:flush()

            close_all()
            require("apps/reader/readerui"):showReader(ok_state.epub_path)
        end)
    end)
end

-- Track (if not tracked) and start the book in the chosen mode. Untracking
-- never deletes books; tracking keeps working as before for the library.
function Detail.begin_live_reading(info, start_idx, open, mode)
    if not DB.find(_source_id, info.path or "") then
        DB.track(Detail.track_fields(info))
    end
    if mode == "full" then
        Detail.start_full_reading(info, start_idx)
    else
        Detail.start_window_reading(info, start_idx, open)
    end
end

-- "How should <title> be downloaded?" dialog (book_mode == "ask").
function Detail.ask_for_mode(info, start_idx, open)
    local Settings = require("settings")
    local V     = Settings:get("volume_size") or 200
    local title = info.name or info.title or "Novel"
    local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
    UIManager:show(ButtonDialogTitle:new{
        title   = "How should " .. title .. " be downloaded?",
        buttons = {
            {{
                text     = "Window (stream as you read)",
                callback = function()
                    Detail.begin_live_reading(info, start_idx, open, "window")
                end,
            }},
            {{
                text     = "Download all (volumes of " .. V .. " chapters)",
                callback = function()
                    Detail.begin_live_reading(info, start_idx, open, "full")
                end,
            }},
            {{
                text     = "Cancel",
                callback = function() end,
            }},
        },
    })
end

-- Resolve the mode for a novel with no live state (book_mode setting, or
-- the choice dialog when it is "ask"), then track + start it.
-- open=false only creates the book (the Track Novel row).
function Detail.choose_and_start(info, start_idx, open, forced_mode)
    local ext = ExtMgr.get(_source_id)
    if not ext then
        UIManager:show(InfoMessage:new{
            text    = "Extension not loaded: " .. tostring(_source_id),
            timeout = 3,
        })
        return
    end
    local Settings = require("settings")
    local mode = Live.resolve_book_mode(
        Settings:get("book_mode") or "ask", forced_mode)
    if not mode then
        Detail.ask_for_mode(info, start_idx, open)
        return
    end
    Detail.begin_live_reading(info, start_idx, open, mode)
end

-- Start (or continue) live reading of this novel.
-- start_idx: full-list chapter index to centre the window on; nil = continue
-- an existing live book (or start at chapter 1 when there is none).
-- open=false: create the book without opening the reader.
-- forced_mode: explicit mode choice from the "How should …" dialog.
function Detail.start_live_reading(info, start_idx, open, forced_mode)
    local ext = ExtMgr.get(_source_id)
    if not ext then
        UIManager:show(InfoMessage:new{
            text    = "Extension not loaded: " .. tostring(_source_id),
            timeout = 3,
        })
        return
    end
    local source_id  = _source_id
    local novel_path = info.path or ""
    local meta = {
        title     = info.name or info.title or "Novel",
        author    = info.author,
        summary   = info.summary,
        cover_url = info.cover,
    }

    local state = LiveBook.state_for(source_id, novel_path)

    -- Existing state without an explicit mode choice: continue / jump.
    if state and not forced_mode then
        if state.mode == "full" then
            Detail.open_full_at(state, start_idx)
            return
        end

        -- Continue: reuse the existing window and just open the EPUB.
        if not start_idx then
            local f = io.open(state.epub_path, "r")
            local exists = f ~= nil
            if f then f:close() end
            if exists then
                close_all()
                require("apps/reader/readerui"):showReader(state.epub_path)
                return
            end
            -- EPUB gone: fall through and rebuild from the window cache.
        end

        -- Recenter an existing window book (tapped chapter "Read from here" /
        -- "Back to furthest"), or rebuild one whose EPUB was deleted: reuse
        -- its state and sidecar through the shared path so the reading
        -- position, highlights and bookmarks are remapped.
        NetworkMgr:runWhenConnected(function()
            local msg = InfoMessage:new{ text = "Preparing chapters…" }
            UIManager:show(msg)
            UIManager:scheduleIn(0.1, function()
                local chapters = #_all_chapters > 0 and _all_chapters
                    or LiveBook.chapter_list(source_id, novel_path)
                if not chapters then
                    UIManager:close(msg)
                    UIManager:show(InfoMessage:new{
                        text = "Chapter list unavailable.", timeout = 3 })
                    return
                end
                local center = start_idx or state.cur or 1
                local ok_p, first, last, items = pcall(LiveBook.plan_and_fetch,
                    ext, state, chapters, center)
                UIManager:close(msg)
                if not ok_p or not first then
                    UIManager:show(InfoMessage:new{
                        text = "Could not fetch chapters.", timeout = 3 })
                    return
                end
                local cover_data, cover_ext = LiveBook.load_cover(state)
                local ok_b = LiveBook.rebuild_window_sidecar(state, chapters,
                    center, first, last, items, cover_data, cover_ext, nil)
                if not ok_b then
                    UIManager:show(InfoMessage:new{
                        text    = "Could not rebuild live book.",
                        timeout = 4,
                    })
                    return
                end
                close_all()
                require("apps/reader/readerui"):showReader(state.epub_path)
            end)
        end)
        return
    end

    -- No live state yet (or a mode just chosen in the dialog).
    Detail.choose_and_start(info, start_idx, open, forced_mode)
end

-- ── Mode switching (novel screen) ─────────────────────────────────────────────

-- Confirm and switch between window and full mode.
function Detail.switch_mode(info, state)
    if state.mode == "full" then
        UIManager:show(ConfirmBox:new{
            text = "Switch back to window mode?\n\nThis rebuilds a window of"
                .. " chapters around Ch. " .. tostring(state.cur or 1)
                .. " and removes the downloaded volumes and chapter files.",
            ok_text     = "Switch to window",
            ok_callback = function()
                Detail.switch_to_window(info, state)
            end,
        })
    else
        local Settings = require("settings")
        local V = state.volume_size or (Settings:get("volume_size") or 200)
        UIManager:show(ConfirmBox:new{
            text = "Download all chapters?\n\nThis downloads the whole novel"
                .. " in volumes of " .. V .. " chapters in the background."
                .. " The current window book stays usable until its position"
                .. " is available in a volume; bookmarks and highlights move"
                .. " with it.",
            ok_text     = "Download all",
            ok_callback = function()
                Detail.switch_to_full(info, state)
            end,
        })
    end
end

-- Window → full: flip the mode and let the downloader take over. The window
-- EPUB is removed (with its annotations migrated) once the volume holding
-- the reading position is built; until then it stays usable.
function Detail.switch_to_full(info, state)
    local Settings = require("settings")
    state.mode          = "full"
    state.volume_size   = state.volume_size
        or (Settings:get("volume_size") or 200)
    state.downloaded    = state.downloaded or 0
    state.total         = state.total or #_all_chapters
    state.folder        = LiveBook.volume_dir_for(state.title)
    state.volumes       = state.volumes or {}
    state.switch_pending = "full"
    LiveBook.save_state(state)
    local Downloader = require("core.downloader")
    Downloader.enqueue(state.key)
    Downloader.tick()
    UIManager:show(InfoMessage:new{
        text = "Downloading all chapters in the background (volumes of "
            .. tostring(state.volume_size) .. ").",
        timeout = 4 })
    Detail.rebuild(info, true)
end

-- Full → window: rebuild the window around state.cur from the chapter store,
-- move the volume annotations into it (stashing chapters outside the
-- window), then remove the volumes and the chapter store.
function Detail.switch_to_window(info, state)
    NetworkMgr:runWhenConnected(function()
        local msg = InfoMessage:new{ text = "Preparing chapters…" }
        UIManager:show(msg)
        UIManager:scheduleIn(0.1, function()
            local chapters = #_all_chapters > 0 and _all_chapters
                or LiveBook.chapter_list(state.source_id, state.novel_path)
            if not chapters or #chapters == 0 then
                UIManager:close(msg)
                UIManager:show(InfoMessage:new{
                    text = "Chapter list unavailable.", timeout = 3 })
                return
            end
            local center = state.cur or 1

            -- Preload the window cache from the chapter store so the rebuild
            -- reuses downloaded content instead of re-fetching it.
            local first, last = Live.plan_window(#chapters, center,
                Live.BEHIND, Live.AHEAD)
            local map, titles = {}, LiveBook.load_store_titles(state.key)
            for idx = first, last do
                local content = LiveBook.load_stored_chapter(state.key, idx)
                if content then
                    local ch = chapters[idx]
                    local path = ch and (ch.path or ch.sourceUrl
                        or ("#" .. idx)) or ("#" .. idx)
                    map[path] = {
                        title = titles[tostring(idx)]
                            or (ch and (ch.name or ch.title))
                            or ("Chapter " .. idx),
                        content = content,
                    }
                end
            end
            LiveBook.save_window_chapters(state.key, map)

            local meta = {
                title     = state.title or info.name or "Novel",
                author    = state.author,
                summary   = state.summary,
                cover_url = state.cover_url or info.cover,
            }
            local ok_state, err = LiveBook.new_start(ExtMgr.get(_source_id),
                meta, state.source_id, state.novel_path, center, chapters)
            UIManager:close(msg)
            if not ok_state then
                UIManager:show(InfoMessage:new{
                    text = "Could not rebuild: " .. tostring(err),
                    timeout = 4 })
                return
            end

            -- Move the volume annotations into the window book and remove
            -- the volume files + chapter store.
            LiveBook.migrate_volumes_to_window(ok_state)

            -- Land on the current chapter.
            local DocSettings = require("docsettings")
            local ds = DocSettings:open(ok_state.epub_path)
            LiveBook.save_position(ds,
                Live.chapter_start_xpointer(ok_state.front,
                    ok_state.win_first, center))
            ds:flush()

            UIManager:show(InfoMessage:new{
                text = "Switched to window mode.", timeout = 3 })
            Detail.rebuild(info, true)
        end)
    end)
end

-- Retry chapters that failed permanently at the source (state.failed_chapters):
-- re-download them, replace their placeholders and rebuild the affected
-- volumes.
function Detail.retry_failed(info, state)
    local ext = ExtMgr.get(_source_id)
    if not ext then
        UIManager:show(InfoMessage:new{
            text    = "Extension not loaded: " .. tostring(_source_id),
            timeout = 3,
        })
        return
    end
    NetworkMgr:runWhenConnected(function()
        local msg = InfoMessage:new{ text = "Retrying failed chapters…" }
        UIManager:show(msg)
        UIManager:scheduleIn(0.1, function()
            local Downloader = require("core.downloader")
            local ok, res = Downloader.retry_failed(state, ext)
            UIManager:close(msg)
            if not ok then
                UIManager:show(InfoMessage:new{
                    text = "Could not retry failed chapters: " .. tostring(res),
                    timeout = 4 })
            else
                UIManager:show(InfoMessage:new{
                    text = "Retried " .. tostring(res.retried) .. " chapter(s); "
                        .. tostring(res.still_failed) .. " still failed.",
                    timeout = 4 })
            end
            Detail.rebuild(info, true)
        end)
    end)
end

function Detail.fetch(source_id, path)
    _fetch_id   = _fetch_id + 1
    local my_id = _fetch_id
    reset_state(source_id)

    local ext = ExtMgr.get(source_id)
    if not ext then
        UIManager:show(InfoMessage:new{
            text    = "Extension not loaded: " .. tostring(source_id),
            timeout = 3,
        })
        return
    end

    NetworkMgr:runWhenConnected(function()
        local loading = InfoMessage:new{ text = "Loading novel details…" }
        UIManager:show(loading)

        UIManager:scheduleIn(0.1, function()
            if my_id ~= _fetch_id then return end

            local info

            if type(ext.parseNovelMeta) == "function" then
                -- ── Fast path: metadata-only fetch + smart chapter loading ────
                -- Only 1 HTTP request when the chapter count hasn't changed.
                local ok, meta = pcall(ext.parseNovelMeta, ext, path)
                if not ok or not meta then
                    UIManager:close(loading)
                    UIManager:show(InfoMessage:new{
                        text    = "Failed to load novel: " .. tostring(meta),
                        timeout = 4,
                    })
                    return
                end
                info = meta

                local new_total = info.total_chapters or 0
                local cache     = DB.loadChapterCache(source_id, path)

                if cache and cache.total == new_total and new_total > 0 then
                    -- Cache hit: chapter count unchanged, use cached list
                    _all_chapters = cache.chapters
                elseif cache and cache.total > 0 and new_total > cache.total
                       and type(ext.parsePage) == "function" and ext.chapters_per_page then
                    -- Delta: fetch only the new pages
                    local per_page     = ext.chapters_per_page
                    local first_new_pg = math.floor(cache.total / per_page) + 1
                    local last_pg      = math.ceil(new_total / per_page)
                    local new_chs      = {}
                    for pg = first_new_pg, last_pg do
                        local ok_p, pdata = pcall(ext.parsePage, ext, path, tostring(pg))
                        if ok_p and pdata and pdata.chapters then
                            for _, ch in ipairs(pdata.chapters) do
                                table.insert(new_chs, ch)
                            end
                        end
                    end
                    local seen = {}
                    _all_chapters = {}
                    for _, ch in ipairs(cache.chapters) do
                        seen[ch.path or ""] = true
                        table.insert(_all_chapters, ch)
                    end
                    for _, ch in ipairs(new_chs) do
                        if not seen[ch.path or ""] then
                            table.insert(_all_chapters, ch)
                        end
                    end
                    DB.saveChapterCache(source_id, path, _all_chapters, #_all_chapters)
                else
                    -- Full fetch (cache miss, count decreased, or no delta support)
                    local ok_n, full = pcall(ext.parseNovel, ext, path)
                    if ok_n and full then
                        _all_chapters = full.chapters or {}
                        for k, v in pairs(full) do
                            if info[k] == nil then info[k] = v end
                        end
                    end
                    DB.saveChapterCache(source_id, path, _all_chapters, #_all_chapters)
                end
                info.total_chapters = #_all_chapters

            else
                -- ── Legacy path: parseNovel returns everything ────────────────
                local ok, full = pcall(ext.parseNovel, ext, path)
                if not ok or not full then
                    UIManager:close(loading)
                    UIManager:show(InfoMessage:new{
                        text    = "Failed to load novel: " .. tostring(full),
                        timeout = 4,
                    })
                    return
                end
                info          = full
                _all_chapters = full.chapters or {}
                DB.saveChapterCache(source_id, path, _all_chapters, #_all_chapters)
            end

            UIManager:close(loading)
            _novel_info = info

            -- ── Cover: disk cache first, download if missing ──────────────────
            if info.cover and info.cover ~= "" then
                local ok_epub, Epub       = pcall(require, "core.epub")
                local ok_ri,  RenderImage = pcall(require, "ui/renderimage")
                if ok_epub and ok_ri then
                    local cdata = DB.loadCoverCache(source_id, path)
                    if not cdata then
                        cdata = Epub.fetch_cover(info.cover)
                        if cdata then DB.saveCoverCache(source_id, path, cdata) end
                    end
                    if cdata then
                        local ok_bb, native = pcall(
                            RenderImage.renderImageData, RenderImage,
                            cdata, #cdata, false)
                        if ok_bb and native then
                            local nw, nh = native:getWidth(), native:getHeight()
                            if nw > 0 and nh > 0 then
                                _cover_bb = native  -- ImageViewer scales to fit
                            else
                                native:free()
                            end
                        end
                    end
                end
            end

            -- ── Persist summary for tracked novels ────────────────────────────
            if info.summary and info.summary ~= "" then
                local tracked = DB.find(source_id, info.path or path)
                if tracked and not tracked.summary then
                    DB.update(source_id, info.path or path, { summary = info.summary })
                end
            end

            Detail.rebuild(info)
        end)
    end)
end

function Detail.free_cover()
    if _cover_bb then
        _cover_bb:free()
        _cover_bb = nil
    end
end

return Detail
