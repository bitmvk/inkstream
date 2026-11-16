-- core/downloader.lua — background batch downloader for full-mode novels.
-- Owns a queue of full-mode states with downloaded < total. One subprocess
-- at a time (core/bgtask.lua); each batch downloads the next
-- Downloader.BATCH chapters into the chapter store — the child writes the
-- chapter files itself and returns only counts over the pipe, never HTML.
-- Batches only run while the device is already online; Wi-Fi is never
-- turned on.
local logger = require("logger")
local ok_ui, UIManager = pcall(require, "ui/uimanager")
local ok_notif, Notification = pcall(require, "ui/widget/notification")
local Live     = require("core.live")
local LiveBook = require("core.livebook")
local BgTask   = require("core.bgtask")

local Downloader = {}
Downloader.BATCH       = 50
Downloader.TICK_DELAY  = 2   -- between consecutive batches
Downloader.RETRY_DELAY = 15  -- when offline or a batch made no progress
Downloader.FAIL_LIMIT  = 3   -- failed batches on one chapter before it is skipped

-- Placeholder stored for a chapter that failed FAIL_LIMIT times (gone or
-- broken at the source): it is skipped so later chapters still download, and
-- recorded in state.failed_chapters for the "Retry failed chapters" action.
local FAILED_PLACEHOLDER = "<p>This chapter could not be downloaded.</p>"

local _task    = nil    -- running BgTask (one at a time)
local _queue   = {}     -- ordered keys
local _queued  = {}     -- key -> true
local _resumed = false

local function schedule(delay, fn)
    if UIManager then UIManager:scheduleIn(delay, fn) end
end

-- True while the device already has a connection. Deliberately never calls
-- the NetworkMgr connect/wifi machinery, and never isOnline() (its DNS
-- probe would block the UI thread). No manager at all: assume online — a
-- failed chapter fetch is harmless (the batch just stops early).
local function online()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or not NetworkMgr or not NetworkMgr.isConnected then return true end
    local ok2, res = pcall(NetworkMgr.isConnected, NetworkMgr)
    return ok2 and res == true
end

function Downloader.enqueue(key)
    if not _queued[key] then
        _queued[key] = true
        table.insert(_queue, key)
    end
end

-- key, vol of the document currently open in the reader (nil, nil when the
-- reader is closed or the document is not a live volume).
function Downloader.open_live_volume()
    local ok_r, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok_r or not ReaderUI or not ReaderUI.instance then return nil, nil end
    local doc = ReaderUI.instance.document
    if not doc or not doc.file then return nil, nil end
    return LiveBook.index_lookup_volume(doc.file)
end

-- ── Batch core ────────────────────────────────────────────────────────────────

-- True when the source still answers for a chapter other than `idx`.
-- parseChapter returns nil both for a chapter that is gone at the source and
-- for a plain network failure, so a neighbouring chapter is probed before a
-- failed chapter is written off as permanently broken: an outage (Wi-Fi
-- associated but no internet) must not fill the store with placeholders.
local function source_reachable(ext, chapters, idx, total)
    if not ext then return false end
    local probe = idx < total and idx + 1 or idx - 1
    local ch = probe >= 1 and chapters[probe] or nil
    if not ch or not ch.path then return false end
    local ok, html = pcall(ext.parseChapter, ext, ch.path)
    return ok and html ~= nil
end

-- Download chapters from..to into the chapter store. A failed fetch stops
-- the batch (downloaded stays contiguous; the chapter is retried next time),
-- unless it has failed Downloader.FAIL_LIMIT batches in a row on the same
-- chapter and the source still answers for a neighbouring one (else it is a
-- network problem, not a broken chapter) — then a placeholder is stored and
-- the chapter is reported as `skipped` so the caller records it in
-- state.failed_chapters and advances past it. Runs in a forked child in
-- production (where it only writes the chapter store, never state), so the
-- consecutive-failure bookkeeping is returned here and applied by the parent.
-- Returns { downloaded, failed, total, skipped, fail_idx, fail_count }.
function Downloader.download_range(state, ext, chapters, from, to)
    local total = #chapters
    local n     = state.downloaded or 0
    local fail_idx   = state.fail_idx
    local fail_count = state.fail_count or 0
    local failed, skipped
    local titles = LiveBook.load_store_titles(state.key)
    for idx = from, to do
        if idx > total then break end
        local ch = chapters[idx]
        local content
        if ext and ch and ch.path then
            local ok, html = pcall(ext.parseChapter, ext, ch.path)
            content = ok and html or nil
        end
        if not content then
            -- Consecutive failures on the same chapter.
            if fail_idx == idx then
                fail_count = fail_count + 1
            else
                fail_idx = idx
                fail_count = 1
            end
            if fail_count >= Downloader.FAIL_LIMIT
               and source_reachable(ext, chapters, idx, total) then
                -- Permanently broken at the source: skip it so the rest of
                -- the novel is not stalled. The placeholder keeps the volume
                -- buildable and is replaced by the retry action on success.
                if not LiveBook.save_stored_chapter(state.key, idx, FAILED_PLACEHOLDER) then
                    failed = idx
                    break
                end
                titles[tostring(idx)] = ch and (ch.name or ch.title)
                    or ("Chapter " .. idx)
                skipped   = idx
                fail_idx  = nil
                fail_count = 0
                n = idx
            else
                -- Still failing, or the source is unreachable right now
                -- (offline, extension not loaded): keep the chapter pending
                -- and stop, the next batch retries it.
                failed = idx
                break
            end
        elseif not LiveBook.save_stored_chapter(state.key, idx, content) then
            -- Could not write to the chapter store (a local problem, not the
            -- source): stop without counting it so the next batch retries.
            failed = idx
            break
        else
            titles[tostring(idx)] = ch.name or ch.title or ("Chapter " .. idx)
            fail_idx  = nil
            fail_count = 0
            n = idx
        end
    end
    LiveBook.save_store_titles(state.key, titles)
    return {
        downloaded = n,
        failed     = failed,
        total      = total,
        skipped    = skipped,
        fail_idx   = fail_idx,
        fail_count = fail_count,
    }
end

-- Child side of a batch: reload the state + chapter list inside the fork
-- (extensions are inherited from the parent) and write chapters to disk.
local function child_body(key, from, to)
    return function()
        local LiveBookC = require("core.livebook")
        local ExtMgr    = require("core.extmgr")
        local DL        = require("core.downloader")
        local state = LiveBookC.load_state(key)
        if not state then return { ok = false, error = "state_gone" } end
        local chapters = LiveBookC.chapter_list(state.source_id, state.novel_path)
        if not chapters or #chapters == 0 then
            chapters = LiveBookC.refresh_chapter_list(ExtMgr.get(state.source_id),
                state.source_id, state.novel_path)
        end
        if not chapters or #chapters == 0 then
            return { ok = false, error = "no chapters" }
        end
        return DL.download_range(state, ExtMgr.get(state.source_id), chapters, from, to)
    end
end

-- Rebuild every volume the last batch touched, except a volume currently
-- open in the reader: that one is marked for a deferred rebuild (main.lua
-- rebuilds it when the document closes, or earlier via reloadDocument).
function Downloader.rebuild_changed(state, before)
    local V = state.volume_size
    local d = state.downloaded or 0
    if d <= before then return end
    local v_first = Live.volume_of(before + 1, V)
    local v_last  = Live.volume_of(d, V)
    local open_key, open_vol = Downloader.open_live_volume()
    local open = open_key == state.key and open_vol or nil
    -- Only one volume can be deferred (the one open in the reader; main.lua
    -- rebuilds it on reloadDocument or when the document closes). Build a
    -- volume deferred by an earlier batch that is no longer open: this batch
    -- would overwrite the flag, and the chapters appended to it meanwhile
    -- would otherwise never reach the file.
    local rebuilt = state.pending_volume_rebuild
    if rebuilt and rebuilt ~= open then
        LiveBook.build_full_volume(state, rebuilt)
        state.pending_volume_rebuild = nil
    end
    for v = v_first, v_last do
        if open == v then
            state.pending_volume_rebuild = v
        elseif v ~= rebuilt then
            LiveBook.build_full_volume(state, v)
        end
    end
    LiveBook.save_state(state)
end

-- Finish a window→full switch: once the volume containing state.cur is
-- built, migrate the window book's annotations into the volume sidecars
-- (chapters not downloaded yet are stashed) and remove the window EPUB.
function Downloader.process_switch(state)
    if not state or state.switch_pending ~= "full" then return end
    local d = state.downloaded or 0
    local cur = state.cur or state.win_first or 1
    local target_v = Live.volume_of(cur, state.volume_size)
    if d < cur or not (state.volumes and state.volumes[target_v]) then
        return  -- the volume holding the reading position is not built yet
    end
    -- Do not remove the EPUB while it is open in the reader.
    local open_key, open_vol = Downloader.open_live_volume()
    if open_key == state.key and not open_vol then return end

    local ok_ds, DocSettings = pcall(require, "docsettings")
    local stash = state.stash or {}
    if ok_ds then
        local ds = DocSettings:open(state.epub_path)
        -- Carry the reading position into the volume holding it (remapped to
        -- that volume's numbering and front count).
        local last_xp = ds:readSetting("last_xpointer")
        if type(last_xp) == "string" then
            local idx = Live.chapter_at(last_xp, state.front or 0,
                state.win_first or 1)
            if idx and idx <= d then
                local v = Live.volume_of(idx, state.volume_size)
                local vol = state.volumes[v]
                if vol then
                    local first, last = Live.volume_range(v, state.volume_size, d)
                    local new_xp = Live.remap_xpointer(last_xp, state.front or 0,
                        vol.front or 0, state.win_first or 1, first, last)
                    local ds_v = DocSettings:open(LiveBook.volume_path_for(state, v))
                    LiveBook.save_position(ds_v, new_xp
                        or Live.chapter_start_xpointer(vol.front or 0, first, idx))
                    ds_v:flush()
                end
            end
        end
        local annotations = ds:readSetting("annotations")
        if type(annotations) == "table" then
            local old_front = state.front or 0
            local old_first = state.win_first or 1
            for _, item in ipairs(annotations) do
                if type(item) == "table" then
                    local idx = type(item.page) == "string"
                        and Live.chapter_at(item.page, old_front, old_first) or nil
                    if idx then
                        local v = Live.volume_of(idx, state.volume_size)
                        if idx <= d and state.volumes[v] then
                            -- Chapter already in a volume: insert there.
                            LiveBook.insert_volume_annotation(state, v, idx,
                                Live.stash_annotation(item))
                        else
                            local key_s = tostring(idx)
                            stash[key_s] = stash[key_s] or {}
                            table.insert(stash[key_s], Live.stash_annotation(item))
                        end
                    end
                end
            end
        end
    end
    state.stash = stash
    LiveBook.remove_live_file(state.epub_path)
    os.remove(state.epub_path)
    state.epub_path   = LiveBook.volume_path_for(state, 1)
    state.switch_pending = nil
    state.win_first, state.win_last = nil, nil
    LiveBook.save_state(state)
    logger.dbg("Inkstream/Downloader: window book removed, now full mode")
end

function Downloader.notify_finished(state)
    logger.dbg("Inkstream/Downloader: finished", state.title)
    if not ok_notif or not Notification or not UIManager then return end
    UIManager:show(Notification:new{
        text    = "Inkstream: " .. (state.title or "Novel")
            .. " downloaded (" .. tostring(state.downloaded) .. " chapters).",
        timeout = 3,
    })
end

-- "Read from here" on a fresh full-mode novel: once the download reaches the
-- requested chapter, tell the user it is available.
function Downloader.notify_chapter_ready(state, idx)
    logger.dbg("Inkstream/Downloader: chapter ready", state.title, idx)
    if not ok_notif or not Notification or not UIManager then return end
    UIManager:show(Notification:new{
        text    = "Inkstream: Chapter " .. idx .. " of "
            .. (state.title or "Novel") .. " is ready to read.",
        timeout = 3,
    })
end

-- ── Queue / scheduling ────────────────────────────────────────────────────────

function Downloader.start_batch(state)
    local from = (state.downloaded or 0) + 1
    local to   = math.min((state.downloaded or 0) + Downloader.BATCH,
        state.total or 0)
    if from > to then
        schedule(Downloader.TICK_DELAY, Downloader.tick)  -- keep the chain alive
        return
    end
    -- Parent loads extensions before the fork so the child inherits them.
    pcall(function() require("core.extmgr").ensure_init() end)
    local key = state.key
    _task = BgTask.start("download",
        BgTask.child(child_body(key, from, to)),
        function(data) Downloader.batch_done(key, data, from) end)
    if not _task then
        Downloader.enqueue(key)
        schedule(Downloader.RETRY_DELAY, Downloader.tick)
    end
end

-- Apply a download_range result to the parent's state: record a permanently
-- skipped chapter, track consecutive failures (or clear them on a clean
-- batch), and advance `downloaded`/`total`. Returns true when the batch made
-- progress (downloaded advanced). The caller saves state (and, on progress,
-- rebuilds volumes).
function Downloader.apply_result(state, data)
    if not data or data.ok == false then return false end
    if data.skipped then
        state.failed_chapters = state.failed_chapters or {}
        state.failed_chapters[tostring(data.skipped)] = true
    end
    -- `failed` nil = the range completed cleanly, so any previous failure
    -- streak on a chapter is over.
    if data.failed then
        state.fail_idx = data.failed
        state.fail_count = data.fail_count or 1
    else
        state.fail_idx = nil
        state.fail_count = nil
    end
    local before = state.downloaded or 0
    if data.downloaded and data.downloaded > before then
        state.downloaded = data.downloaded
        state.total = math.max(state.total or 0, data.total or state.total or 0)
        return true
    end
    return false
end

-- Apply a finished batch. `from` is the first chapter the batch downloaded:
-- the result is dropped when the state no longer matches it (the novel was
-- removed, or switched back to window mode and rebuilt while the batch ran —
-- its chapter store is gone, and a window state has no volume_size to rebuild
-- volumes with). The queue keeps being drained in that case.
function Downloader.batch_done(key, data, from)
    _task = nil
    local state = LiveBook.load_state(key)
    if not state or state.mode ~= "full"
       or (from and from ~= (state.downloaded or 0) + 1) then
        schedule(Downloader.TICK_DELAY, Downloader.tick)
        return
    end
    local before   = state.downloaded or 0
    local progress = Downloader.apply_result(state, data)
    if progress then
        LiveBook.save_state(state)
        Downloader.rebuild_changed(state, before)
        if state.switch_pending == "full" then
            Downloader.process_switch(state)
        end
        if state.open_when_ready and state.downloaded >= state.open_when_ready then
            Downloader.notify_chapter_ready(state, state.open_when_ready)
            state.open_when_ready = nil
            LiveBook.save_state(state)
        end
        if state.downloaded >= state.total then
            Downloader.notify_finished(state)
        end
    elseif data and data.failed then
        -- No progress: persist the consecutive-failure count so the child's
        -- next batch sees it (and, after FAIL_LIMIT, skips the chapter).
        LiveBook.save_state(state)
    end
    if (state.downloaded or 0) < (state.total or 0) then
        Downloader.enqueue(state.key)
    end
    -- Offline: stop the chain (leave the queue intact) instead of polling;
    -- Inkstream:onNetworkConnected resumes it. A batch that fails without
    -- progress is retried after RETRY_DELAY while the device reports a
    -- connection; a failing chapter is only skipped (FAIL_LIMIT) once the
    -- source answers again for a neighbouring chapter.
    if not online() then return end
    schedule(progress and Downloader.TICK_DELAY or Downloader.RETRY_DELAY,
        Downloader.tick)
end

-- Start (or continue) processing the queue. Never turns Wi-Fi on. While
-- offline it stops without rescheduling (the queue is left intact) and is
-- resumed on KOReader's NetworkConnected event.
function Downloader.tick()
    if _task then
        schedule(Downloader.TICK_DELAY, Downloader.tick)
        return
    end
    local key = table.remove(_queue, 1)
    if not key then return end
    _queued[key] = nil
    local state = LiveBook.load_state(key)
    if not state or state.mode ~= "full"
       or (state.downloaded or 0) >= (state.total or 0) then
        schedule(Downloader.TICK_DELAY, Downloader.tick)
        return
    end
    if not online() then
        Downloader.enqueue(key)  -- leave the queue intact
        return                  -- stop the chain; resumed on NetworkConnected
    end
    Downloader.start_batch(state)
end

-- Enqueue every unfinished full-mode novel and finish pending window→full
-- switches whose volume is already available. Idempotent; called on plugin
-- init (FileManager or Reader) so downloads resume after a restart.
function Downloader.resume()
    for _, state in ipairs(LiveBook.all_states()) do
        if state.mode == "full"
           and (state.downloaded or 0) < (state.total or 0) then
            Downloader.enqueue(state.key)
        end
    end
    -- Switches run one UI tick later: resume() also runs from the plugin's
    -- init, inside ReaderUI:init before ReaderUI.instance is set, where
    -- process_switch's open-document guard cannot see the document being
    -- opened and would delete it.
    schedule(0, function()
        for _, state in ipairs(LiveBook.all_states()) do
            if state.mode == "full" and state.switch_pending == "full" then
                Downloader.process_switch(state)
            end
        end
    end)
    Downloader.tick()
end

function Downloader.resume_once()
    if _resumed then return end
    _resumed = true
    Downloader.resume()
end

-- ── Synchronous batch (specs/tests) ───────────────────────────────────────────
-- Runs one batch inline — no subprocess, no scheduling — and rebuilds the
-- changed volumes. ext defaults to the installed extension.
function Downloader.run_batch_inline(state, ext)
    if not ext then
        local ok_e, e = pcall(function()
            return require("core.extmgr").get(state.source_id)
        end)
        ext = ok_e and e or nil
    end
    local chapters = LiveBook.chapter_list(state.source_id, state.novel_path)
    if not chapters or #chapters == 0 then
        chapters = LiveBook.refresh_chapter_list(ext, state.source_id,
            state.novel_path)
    end
    if not chapters or #chapters == 0 then
        return { ok = false, error = "no chapters" }
    end
    local before = state.downloaded or 0
    local from   = before + 1
    local to     = math.min(before + Downloader.BATCH, state.total or #chapters)
    local data   = Downloader.download_range(state, ext, chapters, from, to)
    if Downloader.apply_result(state, data) then
        LiveBook.save_state(state)
        Downloader.rebuild_changed(state, before)
    elseif data and data.failed then
        LiveBook.save_state(state)  -- persist the consecutive-failure count
    end
    return data
end

-- Re-download just the chapters recorded in state.failed_chapters (the
-- "Retry failed chapters" action): replace their placeholders in the store
-- with real content and rebuild the affected volumes. Chapters that still
-- fail keep their placeholder and stay in failed_chapters so they can be
-- retried again later. Synchronous (a few chapters at most); the caller
-- wraps it in NetworkMgr:runWhenConnected. Returns ok, { retried,
-- still_failed }.
function Downloader.retry_failed(state, ext)
    if not ext then
        local ok_e, e = pcall(function()
            return require("core.extmgr").get(state.source_id)
        end)
        ext = ok_e and e or nil
    end
    local chapters = LiveBook.chapter_list(state.source_id, state.novel_path)
    if not chapters or #chapters == 0 then
        chapters = LiveBook.refresh_chapter_list(ext, state.source_id,
            state.novel_path)
    end
    if not chapters or #chapters == 0 then
        return false, "no chapters"
    end

    local failed = state.failed_chapters
    if not failed or next(failed) == nil then return true, { retried = 0, still_failed = 0 } end

    local titles  = LiveBook.load_store_titles(state.key)
    local touched = {}
    local retried, still_failed = 0, 0
    for key in pairs(failed) do
        local idx = tonumber(key)
        if idx and idx <= #chapters then
            local ch = chapters[idx]
            local content
            if ext and ch and ch.path then
                local ok, html = pcall(ext.parseChapter, ext, ch.path)
                content = ok and html or nil
            end
            if content and LiveBook.save_stored_chapter(state.key, idx, content) then
                titles[tostring(idx)] = ch.name or ch.title or ("Chapter " .. idx)
                failed[key] = nil
                retried = retried + 1
            else
                still_failed = still_failed + 1
            end
            touched[Live.volume_of(idx, state.volume_size)] = true
        end
    end
    LiveBook.save_store_titles(state.key, titles)
    LiveBook.save_state(state)

    -- Rebuild the volumes the retried chapters live in, except one currently
    -- open in the reader (deferred like rebuild_changed does).
    local open_key, open_vol = Downloader.open_live_volume()
    for v in pairs(touched) do
        if open_key == state.key and open_vol == v then
            state.pending_volume_rebuild = v
        else
            LiveBook.build_full_volume(state, v)
        end
    end
    LiveBook.save_state(state)
    return true, { retried = retried, still_failed = still_failed }
end

return Downloader
