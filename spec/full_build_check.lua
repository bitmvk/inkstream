-- spec/full_build_check.lua — end-to-end full-mode ("Download all") check.
--
-- Same stub approach as spec/live_build_check.lua (shared stubs in
-- spec/stubs.lua) and the REAL NovelFull extension for
-- https://novelfull.com/martial-peak.html. Starts a full-mode novel with
-- volume_size = 5, runs download batches synchronously
-- (Downloader.run_batch_inline), and checks:
--   * volume files/names (zero-padding, fixed per volume number),
--   * OPF titles (Vol. v, Ch. a–b), series = title, series_index = v,
--   * spine counts (front + chapters),
--   * the chapter store (ch/<index>.html + titles.json),
--   * the index value format (window strings + volume {key, vol}),
--   * that a failed chapter stops `downloaded` (contiguous) and is retried
--     by the next batch,
--   * that appending a batch to a partial last volume keeps the earlier
--     DocFragment numbering (sidecar xpointers stay valid),
--   * A1: move_live_books updates the stubbed ReadHistory/ReadCollection.
--
-- Run from the repo root:  luajit spec/full_build_check.lua
-- Requires: luajit, curl, unzip, network access to novelfull.com + GitHub.

local spec_path = debug.getinfo(1, "S").source:sub(2)
local repo_root = spec_path:match("^(.*)/spec/[^/]+%.lua$") or "."
package.path = repo_root .. "/inkstream.koplugin/?.lua;"
    .. repo_root .. "/inkstream.koplugin/?/init.lua;"
    .. repo_root .. "/spec/?.lua;" .. package.path

local tmp_root = "/tmp/inkstream_fullbuild_" .. tostring(os.time())
local check_dir = tmp_root .. "/check"
local home_dir  = tmp_root .. "/home"

local S = require("stubs")
S.setup(tmp_root, home_dir)

local function sh_quote(s) return S.sh_quote(s) end
local function sh(cmd) return S.sh(cmd) end

-- ── Load the real extension ───────────────────────────────────────────────────

sh("mkdir -p " .. sh_quote(check_dir))
S.check_true("check dir created", S.is_dir(check_dir))

local ext_path = check_dir .. "/novelfull.lua"
sh("curl -sS -L --max-time 60 -o " .. sh_quote(ext_path)
    .. " https://raw.githubusercontent.com/bitmvk/mythosext/refs/heads/main/extensions/novelfull.lua")
local f_ext = io.open(ext_path, "rb")
S.check_true("extension downloaded", f_ext ~= nil)
if f_ext then f_ext:close() end
local ext = dofile(ext_path)
S.check_true("extension loaded", type(ext) == "table"
    and type(ext.parseChapter) == "function"
    and type(ext.parseNovel) == "function")

-- Now load the real core modules under test (they pick up the stubs above).
local LiveBook   = require("core.livebook")
local Live       = require("core.live")
local DB         = require("core.db")
local Downloader = require("core.downloader")
local Settings   = require("settings")

-- Small batches so the spec can walk volume boundaries deterministically.
Downloader.BATCH = 5

local NOVEL_PATH = "/martial-peak.html"
local SOURCE_ID  = "novelfull"

-- ── Fetch the chapter list and start the full-mode novel (volume_size 5) ─────

Settings:set("volume_size", 5)
S.check("volume_size setting", Settings:get("volume_size"), 5)

print("Fetching novel metadata + chapter list (2 HTTP requests)…")
local novel = ext:parseNovel(NOVEL_PATH)
S.check_true("parseNovel ok", novel ~= nil and novel.chapters and #novel.chapters > 20)
if not novel or not novel.chapters or #novel.chapters == 0 then
    print("ABORT: could not fetch the chapter list")
    sh("rm -rf " .. sh_quote(tmp_root))
    os.exit(1)
end
local chapters = novel.chapters
DB.saveChapterCache(SOURCE_ID, NOVEL_PATH, chapters, #chapters)

local meta = {
    title     = novel.name or "Martial Peak",
    author    = novel.author,
    summary   = novel.summary,
    cover_url = novel.cover,
}
print("Starting full-mode novel…")
local state, err = LiveBook.new_start_full(ext, meta, SOURCE_ID, NOVEL_PATH, chapters)
S.check_true("new_start_full ok (err=" .. tostring(err) .. ")", state ~= nil)
if not state then
    print("ABORT: new_start_full failed")
    sh("rm -rf " .. sh_quote(tmp_root))
    os.exit(1)
end

S.check("full mode flag", state.mode, "full")
S.check("volume_size 5", state.volume_size, 5)
S.check("downloaded starts at 0", state.downloaded, 0)
S.check("total is the chapter count", state.total, #chapters)
S.check("folder is <home>/<title>", state.folder, home_dir .. "/Martial Peak")

-- ── Batch 1: volume 1 becomes available ───────────────────────────────────────

print("Running batch 1 (chapters 1–5)…")
local b1 = Downloader.run_batch_inline(state, ext)
S.check("batch 1 downloaded", b1.downloaded, 5)
S.check("batch 1 no failure", b1.failed, nil)
S.check("state.downloaded after batch 1", state.downloaded, 5)

local vol1 = state.folder .. "/Martial Peak - Vol 01.epub"
local f = io.open(vol1, "rb")
S.check_true("volume 1 file exists", f ~= nil)
if f then f:close() end

local key1, v1 = LiveBook.index_lookup_volume(vol1)
S.check("index maps volume 1 to the key", key1, state.key)
S.check("index maps volume 1 to vol 1", v1, 1)

-- Chapter store: one HTML file per chapter + titles.json.
for i = 1, 5 do
    S.check_true("store has chapter " .. i,
        LiveBook.load_stored_chapter(state.key, i) ~= nil)
end
S.check_true("store has no chapter 6 yet",
    LiveBook.load_stored_chapter(state.key, 6) == nil)
local titles = LiveBook.load_store_titles(state.key)
S.check("titles.json has the first title", titles["1"],
    chapters[1].name or chapters[1].title)

local function epub_entry(epub, name)
    local p = io.popen("unzip -p " .. sh_quote(epub) .. " " .. sh_quote(name))
    local data = p:read("*a")
    p:close()
    return data
end

local front1 = state.volumes[1] and state.volumes[1].front or 0
S.check_true("volume 1 front recorded", front1 == 0 or front1 == 1)
local opf1 = epub_entry(vol1, "OEBPS/content.opf")
S.check("volume 1 OPF title", opf1:match("<dc:title>([^<]+)</dc:title>"),
    "Martial Peak Vol. 1 (Ch. 1–5)")
S.check("volume 1 series = title",
    opf1:match('<meta name="calibre:series" content="([^"]+)"/>'), "Martial Peak")
S.check("volume 1 series_index = 1",
    opf1:match('<meta name="calibre:series_index" content="([^"]+)"/>'), "1")
S.check("volume 1 spine count", select(2, opf1:gsub("<itemref", "")), front1 + 5)

-- ── Batch 2: volume 2 appears; volume 1's name and content stay fixed ─────────

print("Running batch 2 (chapters 6–10)…")
local b2 = Downloader.run_batch_inline(state, ext)
S.check("batch 2 downloaded", b2.downloaded, 10)
S.check("state.downloaded after batch 2", state.downloaded, 10)

local vol2 = state.folder .. "/Martial Peak - Vol 02.epub"
f = io.open(vol2, "rb")
S.check_true("volume 2 file exists", f ~= nil)
if f then f:close() end
local key2, v2 = LiveBook.index_lookup_volume(vol2)
S.check("index maps volume 2", key2, state.key)
S.check("index maps volume 2 to vol 2", v2, 2)

local opf2 = epub_entry(vol2, "OEBPS/content.opf")
S.check("volume 2 OPF title", opf2:match("<dc:title>([^<]+)</dc:title>"),
    "Martial Peak Vol. 2 (Ch. 6–10)")
S.check("volume 2 series_index = 2",
    opf2:match('<meta name="calibre:series_index" content="([^"]+)"/>'), "2")
S.check("volume 2 spine count", select(2, opf2:gsub("<itemref", "")), front1 + 5)

-- Volume 1 unchanged by the later batch: same name, same spine.
local opf1b = epub_entry(vol1, "OEBPS/content.opf")
S.check("volume 1 spine unchanged after batch 2",
    select(2, opf1b:gsub("<itemref", "")), front1 + 5)

-- ── A failed chapter stops `downloaded` (contiguous) and is retried ───────────

print("Running batch 3 with chapter 13 failing…")
local fail_path = chapters[13].path
local proxy = setmetatable({}, { __index = ext })
function proxy.parseChapter(self, path)
    if path == fail_path then return nil end  -- forced failure
    return ext.parseChapter(ext, path)
end

local b3 = Downloader.run_batch_inline(state, proxy)
S.check("failed batch stops at 13", b3.failed, 13)
S.check("downloaded stays contiguous (12)", state.downloaded, 12)
S.check_true("chapter 12 stored",
    LiveBook.load_stored_chapter(state.key, 12) ~= nil)
S.check_true("failed chapter 13 NOT stored",
    LiveBook.load_stored_chapter(state.key, 13) == nil)

-- The failed batch still built a partial volume 3 (chapters 11–12).
local vol3 = state.folder .. "/Martial Peak - Vol 03.epub"
f = io.open(vol3, "rb")
S.check_true("volume 3 exists (partial)", f ~= nil)
if f then f:close() end
local opf3p = epub_entry(vol3, "OEBPS/content.opf")
S.check("volume 3 title while partial", opf3p:match("<dc:title>([^<]+)</dc:title>"),
    "Martial Peak Vol. 3 (Ch. 11–12)")
local front3 = state.volumes[3] and state.volumes[3].front or 0

-- ── Appending a batch to a partial volume keeps DocFragment numbers ───────────
-- A sidecar xpointer written in chapter 11 (first chapter of the volume)
-- must still resolve to chapter 11 after the next batch appends 13–15.

local DocSettings = require("docsettings")
local ds3 = DocSettings:open(vol3)
local xp11 = "/body/DocFragment[" .. (front3 + 1) .. "]/body/div/p[2]/text().0"
ds3:saveSetting("last_xpointer", xp11)
ds3:flush()
S.check("chapter_at in the partial volume", Live.volume_chapter_at(xp11,
    front3, 3, 5), 11)

print("Retrying the failed batch (appends 13–15 to volume 3)…")
local b3b = Downloader.run_batch_inline(state, ext)
S.check("retry batch downloaded", b3b.downloaded, 17)
S.check("retry batch no failure", b3b.failed, nil)
S.check_true("chapter 13 stored after retry",
    LiveBook.load_stored_chapter(state.key, 13) ~= nil)

local opf3 = epub_entry(vol3, "OEBPS/content.opf")
S.check("volume 3 OPF title after append", opf3:match("<dc:title>([^<]+)</dc:title>"),
    "Martial Peak Vol. 3 (Ch. 11–15)")
S.check("volume 3 series_index = 3",
    opf3:match('<meta name="calibre:series_index" content="([^"]+)"/>'), "3")
S.check("volume 3 spine grew to front+5",
    select(2, opf3:gsub("<itemref", "")), front3 + 5)

-- The sidecar xpointer still resolves to chapter 11: appending chapters did
-- not renumber the earlier DocFragments.
S.check("appended volume keeps ch 11 numbering",
    Live.volume_chapter_at(xp11, front3, 3, 5), 11)
S.check("chapter 15 sits at the volume end (volume math)",
    Live.volume_chapter_at(
        "/body/DocFragment[" .. (front3 + 5) .. "]", front3, 3, 5), 15)

-- Volume 4 appeared in the same batch as a partial last volume (16–17).
local vol4 = state.folder .. "/Martial Peak - Vol 04.epub"
f = io.open(vol4, "rb")
S.check_true("volume 4 exists (partial last volume)", f ~= nil)
if f then f:close() end
local opf4 = epub_entry(vol4, "OEBPS/content.opf")
S.check("volume 4 title while partial", opf4:match("<dc:title>([^<]+)</dc:title>"),
    "Martial Peak Vol. 4 (Ch. 16–17)")
local front4 = state.volumes[4] and state.volumes[4].front or 0

-- A new chapter 18 arrives in a later batch: volume 4 is appended again.
state.total = 18
LiveBook.save_state(state)
local ds4 = DocSettings:open(vol4)
local xp16 = "/body/DocFragment[" .. (front4 + 1) .. "]/body/div/p[2]/text().0"
ds4:saveSetting("last_xpointer", xp16)
ds4:flush()
local b5 = Downloader.run_batch_inline(state, ext)
S.check("append batch downloaded", b5.downloaded, 18)
local opf4b = epub_entry(vol4, "OEBPS/content.opf")
S.check("volume 4 title after append", opf4b:match("<dc:title>([^<]+)</dc:title>"),
    "Martial Peak Vol. 4 (Ch. 16–18)")
S.check("volume 4 spine grew to front+3",
    select(2, opf4b:gsub("<itemref", "")), front4 + 3)
S.check("appended last volume keeps ch 16 numbering",
    Live.volume_chapter_at(xp16, front4, 4, 5), 16)

-- ── Index format migration: window books keep working ─────────────────────────

LiveBook.index_add(home_dir .. "/Some Book.epub", "window-key-1")
S.check("window index entry: lookup", LiveBook.index_lookup(
    home_dir .. "/Some Book.epub"), "window-key-1")
local wk, wv = LiveBook.index_lookup_volume(home_dir .. "/Some Book.epub")
S.check("window index entry: key", wk, "window-key-1")
S.check("window index entry: no vol", wv, nil)
LiveBook.index_remove(home_dir .. "/Some Book.epub")

-- ── A1: move_live_books updates ReadHistory / ReadCollection ──────────────────

print("Moving live books to another folder…")
local new_dir = tmp_root .. "/moved"
sh("mkdir -p " .. sh_quote(new_dir))
-- Snapshot the old paths before the move: the shared state's folder follows
-- the move, so `state.folder` is the new location right after it.
local vols_before = {}
for i = 1, 4 do
    vols_before[i] = state.folder .. "/Martial Peak - Vol 0" .. i .. ".epub"
end
local moved, skipped = LiveBook.move_live_books(new_dir, nil)
S.check("move_live_books moved 1 novel", #moved, 1)
S.check("move_live_books skipped none", #skipped, 0)

-- Every moved volume must have been updated in history and collections.
S.check("history updated for 4 volumes", #S.history_calls, 4)
S.check("collections updated for 4 volumes", #S.collection_calls, 4)
local history_ok = true
for _, rec in ipairs(S.history_calls) do
    if rec[1] ~= "update" then history_ok = false end
    local found = false
    for _, old_path in ipairs(vols_before) do
        if rec[2] == old_path
           and rec[3] == new_dir .. "/Martial Peak/" .. old_path:match("([^/]+)$") then
            found = true
        end
    end
    if not found then history_ok = false; print("  odd history call:", rec[2], "→", rec[3]) end
end
S.check_true("every history call is updateItem(old, new)", history_ok)

-- The state folder follows the move, so later volumes land in the new place.
local state_after = LiveBook.load_state(state.key)
S.check("state.folder follows the move", state_after.folder,
    new_dir .. "/Martial Peak")

-- Index entries point at the new paths.
local new_vol1 = new_dir .. "/Martial Peak/Martial Peak - Vol 01.epub"
local nk1, nv1 = LiveBook.index_lookup_volume(new_vol1)
S.check("moved volume 1 still indexed", nk1, state.key)
S.check("moved volume 1 still vol 1", nv1, 1)
S.check_true("old volume 1 index entry removed",
    LiveBook.index_lookup(vol1) == nil)

-- ── Finding 1: live state is one shared in-memory table per key ───────────────
-- Two callers obtain the state; the downloader advances `downloaded` and flags
-- a pending rebuild, then the reader records a chapter change and saves. The
-- stale copy must not overwrite the downloader's progress.

print("Checking shared live state (Finding 1)…")
local state_a = LiveBook.load_state(state.key)
local state_b = LiveBook.load_state(state.key)
S.check_true("load_state returns the same table for two callers", state_a == state_b)
local dl_before = state_a.downloaded or 0
state_a.downloaded = dl_before + 1
state_a.pending_volume_rebuild = 1
LiveBook.save_state(state_a)
LiveBook.set_cur(state_b, (state_a.cur or state.win_first or 1))
S.check("downloaded does not regress after the reader saves",
    state_b.downloaded, dl_before + 1)
S.check_true("pending_volume_rebuild visible through the reader reference",
    state_b.pending_volume_rebuild == 1)
S.check("downloaded really persisted", LiveBook.load_state(state.key).downloaded,
    dl_before + 1)

-- ── Finding 2: a permanently broken chapter no longer stalls the novel ────────
-- A stub extension whose parseChapter always fails for one chapter: after
-- Downloader.FAIL_LIMIT failed batches the chapter is replaced by a
-- placeholder, recorded in state.failed_chapters, and the download advances
-- past it. "Retry failed chapters" then replaces the placeholder.

print("Checking permanently broken chapter (Finding 2)…")
local TITLE3  = "Broken Chapter"
local PATH3   = "/broken-chapter.html"
local SOURCE3 = "stub-broken"
local broken_chapters = {}
for i = 1, 10 do
    broken_chapters[i] = { name = "Ch " .. i, path = "/broken/chapter-" .. i }
end
local BROKEN_PATH = "/broken/chapter-3"
local broken_ext = {
    parseChapter = function(self, path)
        if path == BROKEN_PATH then return nil end  -- always fails
        return "<p>content " .. path .. "</p>"
    end,
}
local meta3 = { title = TITLE3, author = "stub", summary = nil, cover_url = nil }
DB.saveChapterCache(SOURCE3, PATH3, broken_chapters, #broken_chapters)
local state3, err3 = LiveBook.new_start_full(broken_ext, meta3, SOURCE3, PATH3,
    broken_chapters)
S.check_true("broken new_start_full ok (err=" .. tostring(err3) .. ")", state3 ~= nil)

-- Run batches until the novel is fully downloaded (chapter 3 is skipped).
local attempts = 0
while (state3.downloaded or 0) < (state3.total or 0) and attempts < 20 do
    Downloader.run_batch_inline(state3, broken_ext)
    attempts = attempts + 1
end
S.check("broken novel fully downloaded", state3.downloaded, state3.total)
S.check_true("broken chapter recorded in failed_chapters",
    state3.failed_chapters and state3.failed_chapters["3"] == true)
local ph = LiveBook.load_stored_chapter(state3.key, 3)
S.check_true("placeholder stored for broken chapter",
    ph ~= nil and ph:find("could not be downloaded", 1, true) ~= nil)
S.check("broken chapter title kept", LiveBook.load_store_titles(state3.key)["3"],
    "Ch 3")
S.check("failed_count reports one chapter", LiveBook.failed_count(state3), 1)

-- Retry failed chapters: the source recovered, so chapter 3 is replaced with
-- real content, removed from failed_chapters, and volume 1 is rebuilt.
local retry_ext = {
    parseChapter = function(self, path)
        if path == BROKEN_PATH then return "<p>recovered " .. path .. "</p>" end
        return "<p>content " .. path .. "</p>"
    end,
}
local ok_retry, retry_res = Downloader.retry_failed(state3, retry_ext)
S.check_true("retry_failed ok", ok_retry == true)
S.check("retry recovered one chapter", retry_res.retried, 1)
S.check("retry none still failed", retry_res.still_failed, 0)
S.check("failed_count back to zero", LiveBook.failed_count(state3), 0)
S.check("placeholder replaced with real content",
    LiveBook.load_stored_chapter(state3.key, 3), "<p>recovered /broken/chapter-3</p>")
local vol1_broken = state3.folder .. "/Broken Chapter - Vol 01.epub"
local opf_broken = epub_entry(vol1_broken, "OEBPS/content.opf")
S.check_true("affected volume rebuilt after retry",
    opf_broken ~= nil and opf_broken:find("Vol. 1", 1, true) ~= nil)

-- ── Cleanup + summary ─────────────────────────────────────────────────────────

sh("rm -rf " .. sh_quote(tmp_root))
S.summarize()
