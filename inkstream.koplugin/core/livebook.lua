-- Live reading: per-novel state + I/O.
-- State JSON:  <settings>/inkstream/live/<key>.json
-- Window chapters cache: <settings>/inkstream/live/<key>.chapters.json
--   (a map of chapter path -> {title, content} so refills reuse already
--    downloaded chapters; pruned on each build to the current window's
--    successfully-fetched chapters only)
-- Full-mode chapter store: <settings>/inkstream/live/<key>/ch/<index>.html
--   plus <key>/titles.json (index -> title); volumes are rebuilt from it.
-- Cover bytes: <settings>/inkstream/live/<key>.cover.<ext>
-- Index:      <settings>/inkstream/live/index.json — maps epub_path to a
--   window book's key (string), or to {key = …, vol = …} for a full-mode
--   volume, so the reader can recognise any live book from document.file.
local DataStorage = require("datastorage")
local logger      = require("logger")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then lfs = require("lfs") end
local ok_json, JSON = pcall(require, "rapidjson")
if not ok_json then JSON = require("json") end
-- Plugin settings (may be unavailable in stub/spec environments).
local ok_settings, Settings = pcall(require, "settings")
local DB   = require("core.db")
local Epub = require("core.epub")
local Live = require("core.live")

local LiveBook = {}

local live_dir   = DataStorage:getSettingsDir() .. "/inkstream/live"
local index_path = live_dir .. "/index.json"
local _index     = nil  -- epub_path -> key (lazy loaded)
-- Single shared in-memory copy of each live state (key -> table). load_state
-- returns the same table every call, so the reader, the downloader and the UI
-- all mutate one object and a save from one cannot overwrite another's newer
-- fields with stale data. Subprocess children are forks that only READ state
-- (they never save_state), so the parent stays the sole writer.
local _states    = {}

local function ensure_dir()
    Epub.mkdirp(live_dir)
end

-- ── Keys ──────────────────────────────────────────────────────────────────────

-- Filesystem-safe key for a novel: md5 hex of source_id \0 novel_path.
local ok_sha, sha = pcall(require, "ffi/sha2")
local function key_for(source_id, novel_path)
    local raw = tostring(source_id) .. "\0" .. tostring(novel_path)
    if ok_sha and sha and sha.md5 then
        local h = sha.md5(raw)
        if h and h ~= "" then return h end
    end
    -- Fallback when ffi/sha2 is unavailable (still filesystem-safe).
    return raw:gsub("[^%w%-]", "_")
end

-- ── State ─────────────────────────────────────────────────────────────────────

function LiveBook.load_state(key)
    if _states[key] ~= nil then return _states[key] end
    local f = io.open(live_dir .. "/" .. key .. ".json", "r")
    if not f then return nil end
    local raw = f:read("*all"); f:close()
    local ok, state = pcall(JSON.decode, raw)
    if not ok or not state or not state.epub_path then return nil end
    state.key = key
    -- States created before "furthest" existed: seed it from the current chapter.
    if not state.furthest then
        state.furthest = state.cur or state.win_first
    end
    -- States created before full mode existed are window books.
    state.mode = state.mode or "window"
    _states[key] = state
    return state
end

function LiveBook.save_state(state)
    ensure_dir()
    local f = io.open(live_dir .. "/" .. state.key .. ".json", "w")
    if not f then return false end
    f:write(JSON.encode(state)); f:close()
    _states[state.key] = state
    return true
end

function LiveBook.state_for(source_id, novel_path)
    return LiveBook.load_state(key_for(source_id, novel_path))
end

-- ── Index: epub_path -> key (window books) or {key, vol} (full volumes) ───────

local function index_load()
    if _index then return _index end
    ensure_dir()
    local f = io.open(index_path, "r")
    if not f then _index = {}; return _index end
    local raw = f:read("*all"); f:close()
    local ok, data = pcall(JSON.decode, raw)
    _index = (ok and type(data) == "table") and data or {}
    return _index
end

local function index_save()
    ensure_dir()
    local f = io.open(index_path, "w")
    if not f then return end
    f:write(JSON.encode(_index or {})); f:close()
end

-- Key for an entry of either format (string or {key, vol}).
local function entry_key(entry)
    return type(entry) == "table" and entry.key or entry
end

function LiveBook.index_add(epub_path, key)
    index_load()[epub_path] = key
    index_save()
end

-- Record a full-mode volume file (key plus volume number).
function LiveBook.index_add_volume(epub_path, key, vol)
    index_load()[epub_path] = { key = key, vol = vol }
    index_save()
end

function LiveBook.index_remove(epub_path)
    if index_load()[epub_path] then
        _index[epub_path] = nil
        index_save()
    end
end

-- Key for an indexed path (string entry, or the key field of a volume entry).
function LiveBook.index_lookup(epub_path)
    return entry_key(index_load()[epub_path])
end

-- Key, volume for an indexed path; vol is nil for window books.
function LiveBook.index_lookup_volume(epub_path)
    local entry = index_load()[epub_path]
    if type(entry) == "table" then return entry.key, entry.vol end
    return entry, nil
end

-- Live state for a document path, if it is a live book.
function LiveBook.state_for_epub(epub_path)
    local key = LiveBook.index_lookup(epub_path)
    if not key then return nil end
    return LiveBook.load_state(key)
end

-- States of every live book in the index (stale entries skipped). A
-- full-mode novel has one index entry per volume; each state is listed once.
function LiveBook.all_states()
    local out, seen = {}, {}
    for epub_path, entry in pairs(index_load()) do
        local key = entry_key(entry)
        if not seen[key] then
            seen[key] = true
            local state = LiveBook.load_state(key)
            if state then out[#out + 1] = state end
        end
    end
    return out
end

-- Write the reading position into a book's sidecar (ds = DocSettings).
-- On a sidecar KOReader has never opened, also record the latest CREngine
-- DOM version: with a last_xpointer but no cre_dom_version, ReaderRolling
-- assumes a very old book, requests the oldest DOM version and offers a
-- bookmark "upgrade" (readerrolling.lua onReadSettings).
function LiveBook.save_position(ds, xp)
    ds:saveSetting("last_xpointer", xp)
    if ds:readSetting("cre_dom_version") == nil then
        local ok, cre = pcall(function()
            return require("document/credocument"):engineInit()
        end)
        if ok and cre then
            ds:saveSetting("cre_dom_version", cre.getLatestDomVersion())
        end
    end
end

-- Record the current chapter, extending `furthest` (max chapter ever reached).
function LiveBook.set_cur(state, idx)
    state.cur = idx
    if not state.furthest or idx > state.furthest then
        state.furthest = idx
    end
    LiveBook.save_state(state)
end

-- Number of chapters recorded as permanently failed for a full-mode novel
-- (state.failed_chapters maps tostring(index) -> true; see core/downloader.lua).
function LiveBook.failed_count(state)
    local n = 0
    for _ in pairs(state.failed_chapters or {}) do n = n + 1 end
    return n
end

-- ── Window chapters cache ─────────────────────────────────────────────────────
-- Map of chapter path -> {title, content}; written at each build.

local function window_cache_path(key)
    return live_dir .. "/" .. key .. ".chapters.json"
end

function LiveBook.load_window_chapters(key)
    local f = io.open(window_cache_path(key), "r")
    if not f then return {} end
    local raw = f:read("*all"); f:close()
    local ok, map = pcall(JSON.decode, raw)
    return (ok and type(map) == "table") and map or {}
end

function LiveBook.save_window_chapters(key, map)
    ensure_dir()
    local f = io.open(window_cache_path(key), "w")
    if not f then return end
    f:write(JSON.encode(map)); f:close()
end

-- ── Full-mode chapter store ───────────────────────────────────────────────────
-- One HTML file per chapter plus a small titles map, so volumes can be
-- rebuilt without redownloading and without one huge JSON file. A failed
-- chapter fetch is never written here (downloaded stays contiguous).

local function store_dir(key)
    return live_dir .. "/" .. key .. "/ch"
end

local function titles_path(key)
    return live_dir .. "/" .. key .. "/titles.json"
end

function LiveBook.load_stored_chapter(key, idx)
    local f = io.open(store_dir(key) .. "/" .. idx .. ".html", "rb")
    if not f then return nil end
    local data = f:read("*all"); f:close()
    return data ~= "" and data or nil
end

-- Returns false when the chapter could not be written (callers must not
-- count it as downloaded).
function LiveBook.save_stored_chapter(key, idx, content)
    ensure_dir()
    local dir = store_dir(key)
    Epub.mkdirp(dir)
    local f = io.open(dir .. "/" .. idx .. ".html", "wb")
    if not f then return false end
    f:write(content); f:close()
    return true
end

function LiveBook.load_store_titles(key)
    local f = io.open(titles_path(key), "r")
    if not f then return {} end
    local raw = f:read("*all"); f:close()
    local ok, map = pcall(JSON.decode, raw)
    return (ok and type(map) == "table") and map or {}
end

function LiveBook.save_store_titles(key, titles)
    ensure_dir()
    Epub.mkdirp(live_dir .. "/" .. key)
    local f = io.open(titles_path(key), "w")
    if not f then return end
    f:write(JSON.encode(titles)); f:close()
end

-- Delete the whole chapter store (chapter files + titles).
function LiveBook.clear_chapter_store(key)
    local function rm_r(path)
        local attr = lfs.attributes(path, "mode")
        if attr == "directory" then
            for entry in lfs.dir(path) do
                if entry ~= "." and entry ~= ".." then
                    rm_r(path .. "/" .. entry)
                end
            end
            lfs.rmdir(path)
        elseif attr == "file" then
            os.remove(path)
        end
    end
    rm_r(live_dir .. "/" .. key)
end

-- ── Cover cache ───────────────────────────────────────────────────────────────

function LiveBook.save_cover(state, data, ext)
    ensure_dir()
    local f = io.open(live_dir .. "/" .. state.key .. ".cover." .. ext, "wb")
    if not f then return end
    f:write(data); f:close()
    state.cover_ext = ext
end

function LiveBook.load_cover(state)
    if not state.cover_ext then return nil end
    local f = io.open(live_dir .. "/" .. state.key .. ".cover." .. state.cover_ext, "rb")
    if not f then return nil end
    local data = f:read("*all"); f:close()
    return data ~= "" and data or nil, state.cover_ext
end

-- ── Chapter list ──────────────────────────────────────────────────────────────

-- Full chapter list from the existing chapter cache (same keys as ui/detail).
function LiveBook.chapter_list(source_id, novel_path)
    local cache = DB.loadChapterCache(source_id, novel_path)
    return cache and cache.chapters or nil
end

-- Refresh the full chapter list via the extension and save the cache.
-- Mirrors ui/detail.lua: parseNovelMeta total check first, then parseNovel.
function LiveBook.refresh_chapter_list(ext, source_id, novel_path)
    local chapters
    if ext and type(ext.parseNovelMeta) == "function" then
        local ok, meta = pcall(ext.parseNovelMeta, ext, novel_path)
        if ok and meta and meta.total_chapters then
            local cache = DB.loadChapterCache(source_id, novel_path)
            if cache and cache.total == meta.total_chapters
               and meta.total_chapters > 0 then
                chapters = cache.chapters
            end
        end
    end
    if not chapters then
        if not ext then return nil end
        local ok, full = pcall(ext.parseNovel, ext, novel_path)
        if not ok or not full then return nil end
        chapters = full.chapters or {}
    end
    DB.saveChapterCache(source_id, novel_path, chapters, #chapters)
    return chapters
end

-- ── Chapter fetching ──────────────────────────────────────────────────────────

-- Placeholder used in the built EPUB when a chapter fetch fails. It is never
-- written to the window cache, so a later refill/recenter retries the chapter.
local PLACEHOLDER = "<p>Could not load this chapter.</p>"

-- Fetch {title, content} for each chapter in chapters_slice (list of
-- {name/path} entries from the chapter list). A failed fetch leaves content
-- nil; callers substitute a placeholder for the EPUB build and must not
-- cache nil-content entries.
function LiveBook.fetch_chapters(ext, chapters_slice)
    local out = {}
    for _, ch in ipairs(chapters_slice) do
        local title = ch.name or ch.title
            or ("Chapter " .. (ch.chapter_number or ""))
        local content
        if ext and ch.path then
            local ok, html = pcall(ext.parseChapter, ext, ch.path)
            content = ok and html or nil
        end
        table.insert(out, {
            title   = title,
            content = content,
        })
    end
    return out
end

-- ── Building ──────────────────────────────────────────────────────────────────

-- EPUB path for a live novel: "<live_books_dir>/<title, sanitised>.epub",
-- defaulting to the KOReader home folder. Exports are unaffected.
function LiveBook.epub_path_for(title)
    local safe = (title or "Novel"):gsub('[<>:"/\\|?*]', "_")
    local dir
    if ok_settings and Settings then
        dir = Settings:get("live_books_dir")
    end
    if not dir or dir == "" then dir = Epub.home_dir() end
    return dir .. "/" .. safe .. ".epub"
end

-- Fetch (or reuse from cache) the window's chapters centred on center_idx.
-- Returns win_first, win_last, items[{title, content}]. Failed chapters get a
-- placeholder in `items` (so the EPUB still builds) but are not written to
-- the cache; build_window owns the cache and prunes it to the window's
-- successful chapters, so a later refill/recenter retries any failure.
function LiveBook.plan_and_fetch(ext, state, full_chapters, center_idx)
    local total  = #full_chapters
    local first, last = Live.plan_window(total, center_idx, Live.BEHIND, Live.AHEAD)
    local map    = LiveBook.load_window_chapters(state.key)
    local items  = {}
    for idx = first, last do
        local ch   = full_chapters[idx]
        local path = ch.path or ch.sourceUrl or ("#" .. idx)
        local entry = map[path]
        if not entry or not entry.content then
            entry = LiveBook.fetch_chapters(ext, {ch})[1]
        end
        table.insert(items, {
            title   = entry.title,
            content = entry.content or PLACEHOLDER,
        })
    end
    return first, last, items
end

-- CoverBrowser caches extracted metadata (cover, series, …) per file and
-- never refreshes an existing row on its own; drop the cached row so the
-- next view re-extracts it. Silently does nothing when CoverBrowser is not
-- installed or disabled (its bookinfomanager module is not on package.path).
function LiveBook.invalidate_bookinfo(filepath)
    local ok, BookInfoManager = pcall(require, "bookinfomanager")
    if ok and BookInfoManager and BookInfoManager.deleteBookInfo then
        BookInfoManager:deleteBookInfo(filepath)
    end
end

-- Build the live EPUB for a window over full_chapters and persist state.
-- window_items must line up with full_chapters[win_first .. win_last].
-- Writes to a temp file next to the target, then os.rename over it.
-- Returns ok, front (front-matter spine item count: 1 with cover, else 0).
function LiveBook.build_window(state, full_chapters, win_first, win_last,
                               window_items, cover_data, cover_ext)
    local meta = {
        title        = state.title,
        author       = state.author,
        language     = "en",
        series       = state.title,
        -- Series index = the current chapter, so cover browser / Simple UI
        -- sort the live book by the chapter it holds.
        series_index = Live.series_index_for(full_chapters, state.cur),
        cover_url    = state.cover_url,
        summary      = state.summary,
        cover_data   = cover_data,
        cover_ext    = cover_ext,
    }
    local tmp_path = state.epub_path .. ".tmp"
    local ok, front = Epub.build(meta, window_items, tmp_path, { live = true })
    if not ok then
        os.remove(tmp_path)
        return false, "build_failed"
    end
    -- Atomic on POSIX: rename over the target so a half-written EPUB is
    -- never visible at the final path.
    local ok_r, err_r = os.rename(tmp_path, state.epub_path)
    if not ok_r then
        os.remove(tmp_path)
        return false, tostring(err_r)
    end

    -- Stable file date across rebuilds (recorded at first creation) so file
    -- browsers and reading history do not reshuffle the book on every refill.
    state.created_at = state.created_at or os.time()
    if lfs.touch then
        lfs.touch(state.epub_path, state.created_at, state.created_at)
    end
    LiveBook.invalidate_bookinfo(state.epub_path)

    state.front     = front or 0
    state.win_first = win_first
    state.win_last  = win_last
    state.total     = #full_chapters
    if state.cur == nil then state.cur = win_first end
    LiveBook.save_state(state)
    LiveBook.index_add(state.epub_path, state.key)

    -- Persist exactly this window's chapters (successes only) so the cache
    -- cannot grow without bound, and failed chapters are retried next time.
    local map = {}
    for i = 1, #window_items do
        local ch   = full_chapters[win_first + i - 1]
        local path = ch and (ch.path or ch.sourceUrl or ("#" .. (win_first + i - 1)))
        local content = window_items[i].content
        if content and content ~= PLACEHOLDER then
            map[path] = { title = window_items[i].title, content = content }
        end
    end
    LiveBook.save_window_chapters(state.key, map)
    logger.dbg("Inkstream/Live: built window", win_first, "-", win_last,
        "of", #full_chapters, "front=", front)
    return true, front
end

-- ── Central rebuild while a sidecar exists ────────────────────────────────────
-- Single path for every live rebuild that happens after the book was first
-- opened (refill, goto recenter, back-to-furthest, "Read from here"):
-- builds the new window, then updates the book's sidecar — last_xpointer
-- (remapped from from_xp, or the centre chapter's start), annotations
-- remapped/stashed/merged across the window change — and saves the stash
-- into state.stash. Call from reloadDocument's after_close_callback in the
-- reader (the sidecar is flushed by then); outside the reader, call directly
-- before opening the book.
-- Returns true on success.
function LiveBook.rebuild_window_sidecar(state, full_chapters, center_idx,
        win_first, win_last, window_items, cover_data, cover_ext, from_xp)
    local old_first = state.win_first
    -- The saved xpointers were written under the OLD build's front count;
    -- build_window below may change state.front (e.g. a rebuild whose cover
    -- fetch failed), so the remaps must take old and new fronts separately.
    local old_front = state.front or 0
    state.cur = center_idx
    if not state.furthest or center_idx > state.furthest then
        state.furthest = center_idx
    end

    local ok_b, front = LiveBook.build_window(state, full_chapters,
        win_first, win_last, window_items, cover_data, cover_ext)
    if not ok_b then return false end

    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not ok_ds then return false end
    local ds = DocSettings:open(state.epub_path)

    -- Reading position: remap the captured xpointer, else the centre's start.
    local new_xp
    if from_xp then
        new_xp = Live.remap_xpointer(from_xp, old_front, front, old_first,
            win_first, win_last)
    end
    LiveBook.save_position(ds,
        new_xp or Live.chapter_start_xpointer(front, win_first, center_idx))

    -- Bookmarks + highlights (both live in the sidecar "annotations" list):
    -- remap those inside the new window, stash those outside, and merge
    -- stashed ones whose chapter re-entered the window. Runs also when the
    -- current list is empty but the stash is not (everything was stashed
    -- away by an earlier shift).
    local annotations = ds:readSetting("annotations")
    if type(annotations) ~= "table" then annotations = nil end
    local stash = state.stash
    if annotations or (type(stash) == "table" and next(stash) ~= nil) then
        local kept, new_stash = Live.remap_annotations(annotations or {},
            old_front, front, old_first, win_first, win_last)
        stash = stash or {}
        for key, entries in pairs(new_stash) do stash[key] = entries end
        Live.merge_stashed(kept, stash, front, win_first, win_last)
        state.stash = stash
        ds:saveSetting("annotations", kept)
        -- KOReader recomputes pageno/pageref and resorts on the next open.
        ds:saveSetting("annotations_externally_modified", true)
    end
    ds:flush()
    LiveBook.save_state(state)
    return true
end

-- ── Moving live books to another folder ───────────────────────────────────────
-- Moves every live EPUB from the index into new_dir, together with its
-- KOReader sidecar (DocSettings.updateLocation), reading history and
-- collections (like the file manager does), and the index entry.
-- Full-mode novels move into "<new_dir>/<safe title>/" and their state.folder
-- follows, so later volumes land in the same place.
-- open_file (a path) is skipped — it is open in the reader right now.
-- Returns moved, skipped: arrays of "<title> (<reason>)" strings.
function LiveBook.move_live_books(new_dir, open_file)
    local moved, skipped = {}, {}

    -- Snapshot: index keys are mutated below.
    local entries = {}
    for epub_path, entry in pairs(index_load()) do
        entries[#entries + 1] = { epub_path = epub_path, entry = entry }
    end

    local moved_titles, folder_for = {}, {}  -- dedup per novel

    for _, e in ipairs(entries) do
        local key   = entry_key(e.entry)
        local state = LiveBook.load_state(key)
        local title = (state and state.title) or "Novel"
        if not state then
            LiveBook.index_remove(e.epub_path)  -- stale entry
        elseif e.epub_path == open_file then
            table.insert(skipped, title .. " (open in reader)")
        else
            local name = e.epub_path:match("([^/\\]+)$")
                or ("book-" .. state.key .. ".epub")
            local new_path
            if state.mode == "full" then
                -- Full-mode volumes live in a per-novel folder (created here).
                local base = folder_for[state.key]
                    or new_dir .. "/" .. (state.title or "Novel"):gsub('[<>:"/\\|?*]', "_")
                folder_for[state.key] = base
                Epub.mkdirp(base)
                new_path = base .. "/" .. name
            else
                new_path = new_dir .. "/" .. name
            end
            if lfs.attributes(new_path) ~= nil then
                table.insert(skipped, title .. " (name collision)")
            elseif not LiveBook.move_file(e.epub_path, new_path) then
                table.insert(skipped, title .. " (move failed)")
            else
                local ok_ds, DocSettings = pcall(require, "docsettings")
                if ok_ds then pcall(DocSettings.updateLocation,
                    e.epub_path, new_path) end
                -- Keep Simple UI's Recent / Currently Reading working after
                -- the move, exactly like the file manager does.
                local ok_rh, ReadHistory = pcall(require, "readhistory")
                if ok_rh and ReadHistory and ReadHistory.updateItem then
                    pcall(ReadHistory.updateItem, ReadHistory,
                        e.epub_path, new_path)
                end
                local ok_rc, ReadCollection = pcall(require, "readcollection")
                if ok_rc and ReadCollection and ReadCollection.updateItem then
                    pcall(ReadCollection.updateItem, ReadCollection,
                        e.epub_path, new_path)
                end
                state.epub_path = new_path
                LiveBook.save_state(state)
                LiveBook.index_remove(e.epub_path)
                if type(e.entry) == "table" then
                    LiveBook.index_add_volume(new_path, e.entry.key, e.entry.vol)
                else
                    LiveBook.index_add(new_path, state.key)
                end
                LiveBook.invalidate_bookinfo(e.epub_path)
                if not moved_titles[state.key] then
                    moved_titles[state.key] = true
                    table.insert(moved, title)
                end
            end
        end
    end

    -- Full-mode novels: point the folder (and the nominal first-volume path)
    -- at the new location so future volumes are built there.
    for key, base in pairs(folder_for) do
        local state = LiveBook.load_state(key)
        if state then
            state.folder    = base
            state.epub_path = base .. "/" .. Live.volume_file_name(
                (state.title or "Novel"):gsub('[<>:"/\\|?*]', "_"), 1)
            LiveBook.save_state(state)
        end
    end

    return moved, skipped
end

-- os.rename with a copy+remove fallback for cross-device moves.
function LiveBook.move_file(old, new)
    if os.rename(old, new) then return true end
    local src = io.open(old, "rb")
    if not src then return false end
    local dst = io.open(new, "wb")
    if not dst then src:close(); return false end
    local ok = true
    while true do
        local chunk = src:read(65536)
        if not chunk then break end
        if not dst:write(chunk) then ok = false; break end
    end
    src:close(); dst:close()
    if not ok then os.remove(new); return false end
    if not os.remove(old) then return false end
    return true
end

-- ── High level: create a fresh live book ──────────────────────────────────────
-- Fetches the chapter list (or reuses the one passed in), downloads the
-- window centred on start_idx, builds the EPUB and saves state.
function LiveBook.new_start(ext, meta, source_id, novel_path, start_idx, chapters)
    chapters = chapters or LiveBook.chapter_list(source_id, novel_path)
    if not chapters then
        chapters = LiveBook.refresh_chapter_list(ext, source_id, novel_path)
    end
    if not chapters or #chapters == 0 then return nil, "no chapters" end

    local total  = #chapters
    local center = math.max(1, math.min(start_idx or 1, total))
    local title  = meta.title or meta.name or "Novel"
    local key    = key_for(source_id, novel_path)
    -- When a previous live state exists (e.g. the EPUB was deleted by hand),
    -- carry the annotation stash and the creation date over.
    local prev   = LiveBook.load_state(key)
    local state  = {
        key        = key,
        source_id  = source_id,
        novel_path = novel_path,
        title      = title,
        author     = meta.author,
        summary    = meta.summary,
        cover_url  = meta.cover_url or meta.cover,
        epub_path  = LiveBook.epub_path_for(title),
        front      = 0,
        win_first  = 1,
        win_last   = 1,
        total      = total,
        cur        = center,
        furthest   = prev and prev.furthest and math.max(prev.furthest, center)
                     or center,
        stash      = prev and prev.stash or nil,
        created_at = prev and prev.created_at or nil,
    }

    -- Cover: fetched once, cached next to the state file.
    local cover_data, cover_ext
    if state.cover_url and state.cover_url ~= "" then
        cover_data, cover_ext = Epub.fetch_cover(state.cover_url)
        if cover_data then LiveBook.save_cover(state, cover_data, cover_ext) end
    end

    local first, last, items = LiveBook.plan_and_fetch(ext, state, chapters, center)
    local ok, res = LiveBook.build_window(state, chapters, first, last,
        items, cover_data, cover_ext)
    if not ok then return nil, res end
    return state
end

-- ── Full mode ("Download all") ────────────────────────────────────────────────

-- Folder holding a full-mode novel's volumes: <live books dir>/<safe title>/.
function LiveBook.volume_dir_for(title)
    local safe = (title or "Novel"):gsub('[<>:"/\\|?*]', "_")
    local dir
    if ok_settings and Settings then
        dir = Settings:get("live_books_dir")
    end
    if not dir or dir == "" then dir = Epub.home_dir() end
    return dir .. "/" .. safe
end

-- EPUB path of volume v (names are fixed by the volume number; see
-- Live.volume_file_name).
function LiveBook.volume_path_for(state, v)
    local safe = (state.title or "Novel"):gsub('[<>:"/\\|?*]', "_")
    return (state.folder or LiveBook.volume_dir_for(state.title))
        .. "/" .. Live.volume_file_name(safe, v)
end

-- Build (or rebuild) volume v of a full-mode novel from the chapter store.
-- Returns ok, front. Volumes are fixed partitions (Live.volume_range), so a
-- rebuild only ever appends chapters at the end of the spine: existing
-- DocFragment numbers, last_xpointer and annotations stay valid. On the
-- FIRST build of a volume, stashed annotations (from a window→full switch)
-- whose chapters fall inside it are merged into its sidecar.
function LiveBook.build_full_volume(state, v)
    local V     = state.volume_size
    local d     = state.downloaded or 0
    local first, last = Live.volume_range(v, V, d)
    if last < first then return true, nil end  -- nothing downloaded for it yet

    local path   = LiveBook.volume_path_for(state, v)
    local is_new = state.volumes == nil or state.volumes[v] == nil
    local vol    = (state.volumes and state.volumes[v]) or {}
    local titles = LiveBook.load_store_titles(state.key)
    local items  = {}
    for idx = first, last do
        local content = LiveBook.load_stored_chapter(state.key, idx)
        if not content then return false, "missing_chapter:" .. idx end
        local title = titles[tostring(idx)] or ("Chapter " .. idx)
        table.insert(items, { title = title, content = content })
    end

    local cover_data, cover_ext = LiveBook.load_cover(state)
    local meta = {
        title        = string.format("%s Vol. %d (Ch. %d–%d)",
                        state.title, v, first, last),
        author       = state.author,
        language     = "en",
        series       = state.title,
        series_index = v,
        cover_url    = state.cover_url,
        summary      = state.summary,
        cover_data   = cover_data,
        cover_ext    = cover_ext,
    }
    local tmp_path = path .. ".tmp"
    local ok, front = Epub.build(meta, items, tmp_path, { live = true })
    if not ok then
        os.remove(tmp_path)
        return false, "build_failed"
    end
    local ok_r, err_r = os.rename(tmp_path, path)
    if not ok_r then
        os.remove(tmp_path)
        return false, tostring(err_r)
    end

    -- Stable file date per volume (recorded at first creation).
    vol.created_at = vol.created_at or os.time()
    if lfs.touch then
        lfs.touch(path, vol.created_at, vol.created_at)
    end
    LiveBook.invalidate_bookinfo(path)

    vol.front = front or 0
    if not state.volumes then state.volumes = {} end
    state.volumes[v] = vol
    LiveBook.save_state(state)
    LiveBook.index_add_volume(path, state.key, v)

    -- First build of this volume: merge stashed annotations whose chapters
    -- fall inside it into its sidecar.
    if is_new then
        local ok_ds, DocSettings = pcall(require, "docsettings")
        if ok_ds and state.stash and next(state.stash) ~= nil then
            local ds = DocSettings:open(path)
            local annotations = ds:readSetting("annotations")
            if type(annotations) ~= "table" then annotations = {} end
            Live.merge_stashed(annotations, state.stash, front, first, last)
            ds:saveSetting("annotations", annotations)
            ds:saveSetting("annotations_externally_modified", true)
            ds:flush()
            LiveBook.save_state(state)
        end
    end
    logger.dbg("Inkstream/Live: built volume", v, first, "-", last,
        "of", state.total or "?", "front=", front)
    return true, front
end

-- Create a fresh full-mode novel: saves the state and fetches the cover.
-- The chapters themselves are downloaded in batches by core/downloader.lua
-- (the caller enqueues the returned state's key).
function LiveBook.new_start_full(ext, meta, source_id, novel_path, chapters)
    chapters = chapters or LiveBook.chapter_list(source_id, novel_path)
    if not chapters then
        chapters = LiveBook.refresh_chapter_list(ext, source_id, novel_path)
    end
    if not chapters or #chapters == 0 then return nil, "no chapters" end

    local title  = meta.title or meta.name or "Novel"
    local key    = key_for(source_id, novel_path)
    local prev   = LiveBook.load_state(key)
    local volume_size = (ok_settings and Settings and Settings:get("volume_size"))
        or 200
    local state  = {
        key         = key,
        source_id   = source_id,
        novel_path  = novel_path,
        title       = title,
        author      = meta.author,
        summary     = meta.summary,
        cover_url   = meta.cover_url or meta.cover,
        mode        = "full",
        volume_size = volume_size,
        downloaded  = 0,
        total       = #chapters,
        folder      = LiveBook.volume_dir_for(title),
        volumes     = {},
        -- Nominal path (volume 1); every volume has its own index entry.
        epub_path   = LiveBook.volume_dir_for(title) .. "/"
            .. Live.volume_file_name(title:gsub('[<>:"/\\|?*]', "_"), 1),
        cur         = (prev and prev.cur) or 1,
        furthest    = (prev and prev.furthest) or 1,
        stash       = prev and prev.stash or nil,
    }

    -- Cover: fetched once, cached next to the state file (like window mode).
    if state.cover_url and state.cover_url ~= "" then
        local cover_data, cover_ext = Epub.fetch_cover(state.cover_url)
        if cover_data then LiveBook.save_cover(state, cover_data, cover_ext) end
    end

    LiveBook.save_state(state)
    return state
end

-- ── Removing live files from KOReader's bookkeeping ───────────────────────────
-- Sidecar (DocSettings purge), reading history, collections, CoverBrowser
-- cache and the index entry. The file itself is NOT removed here.

function LiveBook.remove_live_file(epub_path)
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if ok_ds then
        pcall(function()
            DocSettings:open(epub_path):purge()
        end)
    end
    local ok_rh, ReadHistory = pcall(require, "readhistory")
    if ok_rh and ReadHistory and ReadHistory.fileDeleted then
        pcall(ReadHistory.fileDeleted, ReadHistory, epub_path)
    end
    local ok_rc, ReadCollection = pcall(require, "readcollection")
    if ok_rc and ReadCollection and ReadCollection.removeItems then
        pcall(ReadCollection.removeItems, ReadCollection, { [epub_path] = true })
    end
    LiveBook.index_remove(epub_path)
    LiveBook.invalidate_bookinfo(epub_path)
end

-- Insert one annotation item (chapter-relative stash form) for chapter idx
-- into volume v's sidecar, as absolute xpointers for that volume's numbering.
function LiveBook.insert_volume_annotation(state, v, idx, stashed_item)
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not ok_ds then return end
    local path = LiveBook.volume_path_for(state, v)
    local ds   = DocSettings:open(path)
    local annotations = ds:readSetting("annotations")
    if type(annotations) ~= "table" then annotations = {} end
    local first, last = Live.volume_range(v, state.volume_size,
        state.downloaded or 0)
    table.insert(annotations, Live.unstash_annotation(stashed_item,
        (state.volumes and state.volumes[v] and state.volumes[v].front) or 0,
        first, last, idx))
    ds:saveSetting("annotations", annotations)
    ds:saveSetting("annotations_externally_modified", true)
    ds:flush()
end

-- ── Full → window switch ──────────────────────────────────────────────────────
-- Called right after new_start rebuilt the window book: moves every volume
-- sidecar's annotations into the new window book's sidecar (chapters inside
-- the window get remapped, the rest are stashed into state.stash), then
-- removes the volume files, their sidecars/history/index entries and the
-- chapter store.
function LiveBook.migrate_volumes_to_window(state)
    local ok_ds, DocSettings = pcall(require, "docsettings")
    local V      = state.volume_size
    local kept   = {}
    local stash  = state.stash or {}
    for v, vol in pairs(state.volumes or {}) do
        local path = LiveBook.volume_path_for(state, v)
        if ok_ds then
            local ds = DocSettings:open(path)
            local annotations = ds:readSetting("annotations")
            if type(annotations) == "table" then
                for _, item in ipairs(annotations) do
                    if type(item) == "table" then
                        -- Chapter position inside the volume, then full index.
                        local pos = type(item.page) == "string" and
                            Live.chapter_at(item.page, vol.front or 0, 1) or nil
                        if pos then
                            local idx = (v - 1) * V + pos
                            if idx >= state.win_first and idx <= state.win_last then
                                table.insert(kept, Live.remap_annotation(item,
                                    vol.front or 0, state.front or 0, 1,
                                    state.win_first, state.win_last))
                            else
                                local key = tostring(idx)
                                stash[key] = stash[key] or {}
                                table.insert(stash[key], Live.stash_annotation(item))
                            end
                        else
                            table.insert(kept, item)
                        end
                    end
                end
            end
        end
        LiveBook.remove_live_file(path)
        os.remove(path)
    end
    state.stash = stash
    LiveBook.clear_chapter_store(state.key)
    state.mode       = "window"
    state.folder     = nil
    state.volumes    = nil
    state.downloaded = nil
    LiveBook.save_state(state)

    -- Write the migrated items into the window book's sidecar.
    if ok_ds and #kept > 0 then
        local ds = DocSettings:open(state.epub_path)
        local annotations = ds:readSetting("annotations")
        if type(annotations) ~= "table" then annotations = {} end
        for _, item in ipairs(kept) do table.insert(annotations, item) end
        ds:saveSetting("annotations", annotations)
        ds:saveSetting("annotations_externally_modified", true)
        ds:flush()
    end
end

return LiveBook
