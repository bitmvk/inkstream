-- spec/live_spec.lua — dependency-free unit tests for core/live.lua.
-- Run from the repo root:  luajit spec/live_spec.lua
-- Exits non-zero on failure.

-- Locate the repo root and let require() find inkstream.koplugin/core/live.lua.
local spec_path = debug.getinfo(1, "S").source:sub(2)
local repo_root = spec_path:match("^(.*)/spec/live_spec%.lua$") or "."
package.path = repo_root .. "/inkstream.koplugin/?.lua;"
    .. repo_root .. "/inkstream.koplugin/?/init.lua;" .. package.path

local Live = require("core.live")

local n_pass, n_fail = 0, 0

local function check(name, got, want)
    if got == want then
        n_pass = n_pass + 1
        print("PASS  " .. name)
    else
        n_fail = n_fail + 1
        print("FAIL  " .. name .. "  (got " .. tostring(got)
            .. ", want " .. tostring(want) .. ")")
    end
end

local function count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end


-- ── plan_window ───────────────────────────────────────────────────────────────

local f1, l1 = Live.plan_window(50, 5, 2, 8)
check("plan_window middle", f1 .. "," .. l1, "3,13")

local f2, l2 = Live.plan_window(50, 1, 2, 8)
check("plan_window clamped at start", f2 .. "," .. l2, "1,9")

local f3, l3 = Live.plan_window(50, 50, 2, 8)
check("plan_window clamped at end", f3 .. "," .. l3, "48,50")

local f4, l4 = Live.plan_window(50, 49, 2, 8)
check("plan_window near end", f4 .. "," .. l4, "47,50")

local f5, l5 = Live.plan_window(5, 3, 2, 8)
check("plan_window small novel (total < window)",
    f5 .. "," .. l5, "1,5")

local f6, l6 = Live.plan_window(3, 2, 2, 8)
check("plan_window tiny novel", f6 .. "," .. l6, "1,3")

local f7, l7 = Live.plan_window(1, 1, 2, 8)
check("plan_window single chapter", f7 .. "," .. l7, "1,1")

-- ── fragment_of ───────────────────────────────────────────────────────────────

check("fragment_of normal", Live.fragment_of(
    "/body/DocFragment[5]/body/div/p[3]/text().0"), 5)
check("fragment_of two digits", Live.fragment_of(
    "/body/DocFragment[12]/body/div/p[1]/text().0"), 12)
check("fragment_of no fragment", Live.fragment_of(
    "/body/div/p[3]/text().0"), nil)
check("fragment_of nil xp", Live.fragment_of(nil), nil)
check("fragment_of empty xp", Live.fragment_of(""), nil)

-- ── chapter_at / chapter_start_xpointer (front = 0) ───────────────────────────

check("start_xpointer front=0", Live.chapter_start_xpointer(0, 3, 6),
    "/body/DocFragment[4]")
check("start_xpointer front=0 first", Live.chapter_start_xpointer(0, 1, 1),
    "/body/DocFragment[1]")
check("chapter_at front=0", Live.chapter_at(
    "/body/DocFragment[4]/body/div/p[3]/text().0", 0, 3), 6)
check("chapter_at front=0 win start", Live.chapter_at(
    "/body/DocFragment[1]/body/div/p[3]/text().0", 0, 1), 1)

-- ── chapter_at / chapter_start_xpointer (front = 1, cover page) ───────────────

check("start_xpointer front=1", Live.chapter_start_xpointer(1, 3, 6),
    "/body/DocFragment[5]")
check("chapter_at front=1", Live.chapter_at(
    "/body/DocFragment[5]/body/div/p[3]/text().0", 1, 3), 6)
check("chapter_at front matter is nil", Live.chapter_at(
    "/body/DocFragment[1]/body/div/p[3]/text().0", 1, 3), nil)
check("chapter_at front=0 no front matter", Live.chapter_at(
    "/body/DocFragment[1]/body/div/p[3]/text().0", 0, 3), 3)
check("chapter_at not a fragment", Live.chapter_at(
    "/body/div/p[3]/text().0", 0, 3), nil)

-- ── remap_xpointer ────────────────────────────────────────────────────────────

-- Chapter 6, old window [3,13], front=1 → new window [10,17]: outside → nil.
check("remap outside window", Live.remap_xpointer(
    "/body/DocFragment[5]/body/div/p[3]/text().0", 1, 1, 3, 10, 17), nil)

-- Chapter 12, old window [3,13], front=1 → new window [10,17]: inside.
check("remap inside window (front=1)", Live.remap_xpointer(
    "/body/DocFragment[11]/body/div/p[3]/text().0", 1, 1, 3, 10, 17),
    "/body/DocFragment[4]/body/div/p[3]/text().0")

-- Chapter 6, front=0, old [3,13] → new [1,17].
check("remap inside window (front=0)", Live.remap_xpointer(
    "/body/DocFragment[4]/body/div/p[3]/text().0", 0, 0, 3, 1, 17),
    "/body/DocFragment[6]/body/div/p[3]/text().0")

-- Same window: unchanged fragment index.
check("remap identity", Live.remap_xpointer(
    "/body/DocFragment[5]/body/div/p[3]/text().0", 1, 1, 3, 3, 13),
    "/body/DocFragment[5]/body/div/p[3]/text().0")

-- Front matter xpointer: nil.
check("remap front matter nil", Live.remap_xpointer(
    "/body/DocFragment[1]/body/div/p[3]/text().0", 1, 1, 3, 3, 13), nil)

-- ── A2: front changes across a rebuild ────────────────────────────────────────
-- Xpointers written under the OLD front count must land in the right chapter
-- when the new build's front count differs (e.g. the cover fetch failed on
-- the rebuild, 1 → 0, or succeeded again, 0 → 1).

-- Chapter 8, old window [3,13] front=1 (fragment 7) → new window [6,16]
-- front=0 (fragment 3).
check("A2 chapter_at uses old front", Live.chapter_at(
    "/body/DocFragment[7]/body/div/p[3]/text().0", 1, 3), 8)
check("A2 remap front 1→0", Live.remap_xpointer(
    "/body/DocFragment[7]/body/div/p[3]/text().0", 1, 0, 3, 6, 16),
    "/body/DocFragment[3]/body/div/p[3]/text().0")
check("A2 remap front 0→1", Live.remap_xpointer(
    "/body/DocFragment[3]/body/div/p[3]/text().0", 0, 1, 6, 3, 13),
    "/body/DocFragment[7]/body/div/p[3]/text().0")
check("A2 same chapter stays in right chapter (front 1→0, chapter_at on new build)",
    Live.chapter_at(Live.remap_xpointer(
        "/body/DocFragment[7]/body/div/p[3]/text().0", 1, 0, 3, 6, 16), 0, 6), 8)

local a2_anns = { {
    page    = "/body/DocFragment[7]/body/div/p[1]/text().0",
    pos0    = "/body/DocFragment[7]/body/div/p[1]/text().0",
    pos1    = "/body/DocFragment[7]/body/div/p[1]/text().2",
    chapter = "Ch 8", text = "a2", pageno = 42,
} }
local a2_kept, a2_stash = Live.remap_annotations(a2_anns, 1, 0, 3, 6, 16)
check("A2 remap_annotations keeps item", #a2_kept, 1)
check("A2 kept remapped to new front", a2_kept[1].page,
    "/body/DocFragment[3]/body/div/p[1]/text().0")
check("A2 kept pos1 remapped", a2_kept[1].pos1,
    "/body/DocFragment[3]/body/div/p[1]/text().2")
check("A2 nothing stashed", count(a2_stash), 0)

-- ── needs_refill ──────────────────────────────────────────────────────────────

check("needs_refill middle", Live.needs_refill(5, 13, 50), false)
check("needs_refill at margin", Live.needs_refill(11, 13, 50), true)
check("needs_refill inside margin", Live.needs_refill(12, 13, 50), true)
check("needs_refill at end of novel", Live.needs_refill(48, 50, 50), false)
check("needs_refill window at total", Live.needs_refill(50, 50, 50), false)
check("needs_refill beyond total", Live.needs_refill(49, 48, 50), true)

-- ── needs_refill_back ─────────────────────────────────────────────────────────

check("refill_back in first chapter", Live.needs_refill_back(5, 5), true)
check("refill_back before first chapter", Live.needs_refill_back(4, 5), true)
check("refill_back mid window", Live.needs_refill_back(6, 5), false)
check("refill_back deep in window", Live.needs_refill_back(9, 5), false)
check("refill_back window at novel start", Live.needs_refill_back(1, 1), false)

-- No ping-pong: a freshly centred window (cur == win_first + BEHIND) must not
-- immediately satisfy either refill condition.
local pc, pT = 10, 60
local pwf, pwl = Live.plan_window(pT, pc, Live.BEHIND, Live.AHEAD)
check("fresh window shape", pwf .. "," .. pwl, "8,18")
check("fresh window: no forward refill", Live.needs_refill(pc, pwl, pT), false)
check("fresh window: no backward refill", Live.needs_refill_back(pc, pwf), false)

-- A backward refill centred on the old window's first chapter must not
-- re-trigger either condition.
local rwf, rwl = Live.plan_window(pT, pwf, Live.BEHIND, Live.AHEAD)
check("back refill keeps centre inside", pwf >= rwf and pwf <= rwl, true)
check("back refill: no forward re-trigger", Live.needs_refill(pwf, rwl, pT), false)
check("back refill: no backward re-trigger", Live.needs_refill_back(pwf, rwf), false)

-- Property over every possible centre: freshly centred windows never
-- ping-pong (BEHIND=2 >= 1 keeps the centre out of the first window slot;
-- BACK_MARGIN=1 only fires when cur == win_first).
local pingpong_ok = true
for center = 1, 40 do
    local wf, wl = Live.plan_window(40, center, Live.BEHIND, Live.AHEAD)
    if Live.needs_refill(center, wl, 40)
       or Live.needs_refill_back(center, wf) then
        pingpong_ok = false
        print("  ping-pong at center " .. center .. " window " .. wf .. "-" .. wl)
    end
end
check("no ping-pong for any fresh centre", pingpong_ok, true)

-- Small novel whose window covers everything: no refill either way.
local swf, swl = Live.plan_window(6, 3, Live.BEHIND, Live.AHEAD)
check("small novel window covers all", swf .. "," .. swl, "1,6")
check("small novel: no forward refill", Live.needs_refill(3, swl, 6), false)
check("small novel: no backward refill", Live.needs_refill_back(3, swf), false)

-- ── series_index_for ──────────────────────────────────────────────────────────

local sch = { { chapter_number = 1 }, { chapter_number = 7 }, {} }
check("series index uses chapter_number", Live.series_index_for(sch, 2), 7)
check("series index falls back to index", Live.series_index_for(sch, 3), 3)
check("series index nil list", Live.series_index_for(nil, 2), 2)
check("series index string number", Live.series_index_for(
    { { chapter_number = "12" } }, 1), "12")

-- ── annotation remap / stash / unstash round trip ─────────────────────────────
-- Old window [3,13], front=1. Chapters 4, 8 leave on a shift to [10,17];
-- chapter 12 stays and is remapped; a shift back to [3,13] must restore the
-- stashed items with their original xpointers.

local ann_ch4 = {
    page     = "/body/DocFragment[3]/body/div/p[1]/text().0",
    pos0     = "/body/DocFragment[3]/body/div/p[1]/text().0",
    pos1     = "/body/DocFragment[3]/body/div/p[1]/text().2",
    chapter  = "Ch 4", text = "hi", pageno = 42, pageref = "42",
    datetime = "2026-01-01",
}
local ann_ch8 = {
    page     = "/body/DocFragment[7]/body/div/p[2]/text().0",
    pos0     = "/body/DocFragment[7]/body/div/p[2]/text().0",
    pos1     = "/body/DocFragment[7]/body/div/p[2]/text().1",
    chapter  = "Ch 8", text = "yo", pageno = 77,
}
local ann_ch12 = {
    page     = "/body/DocFragment[11]/body/div/p[3]/text().0",
    pos0     = "/body/DocFragment[11]/body/div/p[3]/text().0",
    pos1     = "/body/DocFragment[11]/body/div/p[3]/text().1",
    chapter  = "Ch 12", text = "last", pageno = 99,
}
local annotations = { ann_ch4, ann_ch8, ann_ch12 }

local kept, stash = Live.remap_annotations(annotations, 1, 1, 3, 10, 17)
check("remap keeps in-window items", #kept, 1)
check("remap stashes two chapters", count(stash), 2)
check("remap stashed chapter 4", stash["4"] and #stash["4"], 1)
check("remap stashed chapter 8", stash["8"] and #stash["8"], 1)
check("remap kept item chapter 12 remapped", kept[1].page,
    "/body/DocFragment[4]/body/div/p[3]/text().0")
check("remap kept item pos1 remapped", kept[1].pos1,
    "/body/DocFragment[4]/body/div/p[3]/text().1")
check("remap non-xpointer fields kept", kept[1].text .. "/" .. kept[1].chapter,
    "last/Ch 12")
check("remap drops page numbers", kept[1].pageno, nil)

local rel_page = "/body/DocFragment[" .. Live.STASH_PLACEHOLDER
    .. "]/body/div/p[1]/text().0"
check("stashed page is chapter-relative", stash["4"][1].page, rel_page)
check("stashed pos1 is chapter-relative", stash["4"][1].pos1,
    "/body/DocFragment[" .. Live.STASH_PLACEHOLDER .. "]/body/div/p[1]/text().2")
check("stashed non-xpointer fields kept", stash["4"][1].text .. "/"
    .. stash["4"][1].chapter, "hi/Ch 4")

-- Round trip: shift back to [3,13]; chapters 4 and 8 return with their
-- original xpointers and the stash is emptied.
Live.merge_stashed(kept, stash, 1, 3, 13)
check("merge consumes stashed chapter 4", stash["4"], nil)
check("merge consumes stashed chapter 8", stash["8"], nil)
check("merge appends the restored items", #kept, 3)
local function find_kept(text)
    for _, k in ipairs(kept) do
        if k.text == text then return k end
    end
    return nil
end
local back4 = find_kept("hi")
local back8 = find_kept("yo")
check("round trip page", back4 and back4.page, ann_ch4.page)
check("round trip pos0", back4 and back4.pos0, ann_ch4.pos0)
check("round trip pos1", back4 and back4.pos1, ann_ch4.pos1)
check("round trip text untouched", back4 and back4.text, "hi")
check("round trip second item", back8 and back8.page, ann_ch8.page)

-- Merging with a window that does not contain the stashed chapter leaves it
-- stashed.
local stash2 = { ["8"] = { Live.stash_annotation(ann_ch8) } }
Live.merge_stashed({}, stash2, 1, 10, 17)
check("merge leaves outside chapter stashed", stash2["8"] and #stash2["8"], 1)

-- Items without a mappable xpointer are kept unchanged.
local odd = { { page = "/body/div/p[1]/text().0", text = "odd" },
              "not a table" }
local kept_odd, stash_odd = Live.remap_annotations(odd, 1, 1, 3, 10, 17)
check("unmappable item kept as-is", kept_odd[1].page, "/body/div/p[1]/text().0")
check("non-table item kept", kept_odd[2], "not a table")
check("unmappable items not stashed", count(stash_odd), 0)

-- ── Full mode: volume math ────────────────────────────────────────────────────

check("volume_of first chapter", Live.volume_of(1, 5), 1)
check("volume_of at boundary V", Live.volume_of(5, 5), 1)
check("volume_of V+1", Live.volume_of(6, 5), 2)
check("volume_of at boundary 2V", Live.volume_of(10, 5), 2)
check("volume_of 2V+1", Live.volume_of(11, 5), 3)
check("volume_of deep", Live.volume_of(1234, 200), 7)

local vr1, vr2 = Live.volume_range(2, 5, 10)
check("volume_range full volume", vr1 .. "," .. vr2, "6,10")
local vrf1, vrf2 = Live.volume_range(1, 5, 3)
check("volume_range first volume", vrf1 .. "," .. vrf2, "1,3")
local vrp1, vrp2 = Live.volume_range(4, 5, 17)
check("volume_range last partial volume", vrp1 .. "," .. vrp2, "16,17")
-- Volume starting past `downloaded`: empty (last < first).
local vf, vl = Live.volume_range(5, 5, 17)
check("volume_range past downloaded is empty", vl < vf, true)
check("volume_range empty first", vf, 21)

check("volume_chapter_at front=1", Live.volume_chapter_at(
    "/body/DocFragment[3]/body/div/p[3]/text().0", 1, 2, 5), 7)
check("volume_chapter_at first chapter of volume", Live.volume_chapter_at(
    "/body/DocFragment[2]/body/div/p[3]/text().0", 1, 2, 5), 6)
check("volume_chapter_at front matter is nil", Live.volume_chapter_at(
    "/body/DocFragment[1]/body/div/p[3]/text().0", 1, 2, 5), nil)
check("volume_chapter_at front=0", Live.volume_chapter_at(
    "/body/DocFragment[1]/body/div/p[3]/text().0", 0, 3, 5), 11)
check("volume_chapter_at not a fragment", Live.volume_chapter_at(
    "/body/div/p[3]/text().0", 0, 3, 5), nil)

-- File naming: at least 2 digits, 3 digits from volume 100 on. The padding
-- depends only on the volume number, so names never change as volumes grow.
check("volume_file_name 2 digits", Live.volume_file_name("Martial Peak", 1),
    "Martial Peak - Vol 01.epub")
check("volume_file_name volume 12", Live.volume_file_name("X", 12),
    "X - Vol 12.epub")
check("volume_file_name volume 99", Live.volume_file_name("X", 99),
    "X - Vol 99.epub")
check("volume_file_name volume 100 (3 digits)", Live.volume_file_name("X", 100),
    "X - Vol 100.epub")
check("volume_file_name volume 999", Live.volume_file_name("X", 999),
    "X - Vol 999.epub")

-- ── Mode choice helper ────────────────────────────────────────────────────────

check("resolve ask without choice", Live.resolve_book_mode("ask", nil), nil)
check("resolve ask with choice", Live.resolve_book_mode("ask", "full"), "full")
check("resolve window setting", Live.resolve_book_mode("window", nil), "window")
check("resolve full setting", Live.resolve_book_mode("full", nil), "full")
check("resolve choice overrides setting", Live.resolve_book_mode("full", "window"), "window")
check("resolve unknown setting", Live.resolve_book_mode(nil, nil), nil)

-- ── Summary ───────────────────────────────────────────────────────────────────

print(("---- %d passed, %d failed ----"):format(n_pass, n_fail))
if n_fail > 0 then os.exit(1) end
os.exit(0)
