-- Live reading: pure window/position math, no KOReader requires (unit-testable).
-- A live EPUB is a sliding window over a novel's full chapter list. CREngine
-- maps each EPUB spine item to one DocFragment (1-based), so a chapter at full
-- list index i lives in DocFragment[front + (i - win_first) + 1], where
-- `front` is the number of front-matter spine items before the first chapter
-- (1 when a cover page is included, else 0).

local Live = {}

-- Window shape: chapters kept before/after the current one.
Live.BEHIND = 2
Live.AHEAD  = 8
-- Start a refill when the current chapter is this close to the window's end.
Live.REFILL_MARGIN = 2

-- First and last full-list chapter index (1-based) of a window centred on
-- `center` (1-based). Clamped to [1, total]; clamping one edge does not
-- extend the other.
function Live.plan_window(total, center, behind, ahead)
    -- Clamp each edge to [1, total] independently; no edge extension.
    local first = math.max(1, center - behind)
    local last  = math.min(total, center + ahead)
    return first, last
end

-- DocFragment number N from an xpointer like
-- "/body/DocFragment[5]/body/div/p[3]/text().0", or nil if not in a fragment.
function Live.fragment_of(xp)
    if not xp then return nil end
    local n = xp:match("/body/DocFragment%[(%d+)%]")
    return n and tonumber(n) or nil
end

-- Full-list chapter index for an xpointer, or nil if the xpointer is in
-- front matter (or not a DocFragment at all).
-- Chapter at full index i lives in DocFragment[front + (i - win_first) + 1].
function Live.chapter_at(xp, front, win_first)
    local frag = Live.fragment_of(xp)
    if not frag or frag <= front then return nil end
    return frag - front - 1 + win_first
end

-- Rewrite an xpointer's DocFragment index for a new window.
-- old_front is the front-matter count of the build the xpointer was written
-- for, new_front the count of the new build — they can differ when a rebuild
-- loses (or regains) the cover page. Returns nil when the chapter it points
-- at is not in [new_first, new_last].
function Live.remap_xpointer(xp, old_front, new_front, old_first, new_first, new_last)
    local frag = Live.fragment_of(xp)
    if not frag or frag <= old_front then return nil end
    local idx = frag - old_front - 1 + old_first
    if idx < new_first or idx > new_last then return nil end
    local new_frag = new_front + (idx - new_first) + 1
    return (xp:gsub("/body/DocFragment%[%d+%]",
        "/body/DocFragment[" .. new_frag .. "]", 1))
end

-- Xpointer of the start of the chapter at full-list index idx.
function Live.chapter_start_xpointer(front, win_first, idx)
    return "/body/DocFragment[" .. (front + (idx - win_first) + 1) .. "]"
end

-- True when a refill is needed: the current chapter is within REFILL_MARGIN
-- chapters of the window's last chapter, and the window is not already at
-- the end of the novel.
function Live.needs_refill(cur_idx, win_last, total)
    if win_last >= total then return false end
    return cur_idx >= win_last - Live.REFILL_MARGIN
end

-- ── Backward refill ───────────────────────────────────────────────────────────

-- How close to the window's first chapter the reader must be to refill
-- backwards. Deliberately 1 (only when cur == win_first), NOT the symmetric
-- REFILL_MARGIN: with BEHIND = 2 <= REFILL_MARGIN = 2, a freshly centred
-- window has cur == win_first + BEHIND <= win_first + REFILL_MARGIN, which a
-- symmetric margin would immediately re-trigger, refilling forever.
-- plan_window always keeps BEHIND >= 1 chapters before the centre (except at
-- the novel's start, where win_first == 1 and backward refills are impossible
-- anyway), so a centre is never the window's first chapter and the two
-- conditions cannot ping-pong.
Live.BACK_MARGIN = 1

-- True when a backward refill is needed: the reader is in (or before, for
-- safety) the window's first chapter, and the window does not start at the
-- beginning of the novel.
function Live.needs_refill_back(cur_idx, win_first)
    if win_first <= 1 then return false end
    return cur_idx <= win_first - 1 + Live.BACK_MARGIN
end

-- ── Series index ──────────────────────────────────────────────────────────────

-- Series index stored in the built EPUB: the current chapter's chapter_number
-- (fallback: its full-list index), so cover browser / Simple UI can sort the
-- live book by the chapter it currently holds.
function Live.series_index_for(chapters, cur)
    local ch = chapters and chapters[cur]
    return (ch and ch.chapter_number) or cur
end

-- ── Annotation remapping (bookmarks + highlights survive window changes) ──────
-- KOReader stores both bookmarks and highlights in the sidecar "annotations"
-- list (see readerannotation.lua); each item carries the xpointer fields
-- page/pos0/pos1. A window change renumbers DocFragments, so items in
-- chapters outside the new window are stashed (chapter-relative xpointers,
-- keyed by full chapter index) and merged back when their chapter re-enters
-- the window.

-- Placeholder replacing a DocFragment index in a stashed xpointer. It cannot
-- be confused with a fragment number, and it is not a Lua pattern magic
-- character (xpointers over our generated chapters never contain "@" either).
Live.STASH_PLACEHOLDER = "@"

-- Convert an absolute xpointer to its chapter-relative form (DocFragment
-- index replaced by the placeholder). nil when there is no fragment to
-- replace.
function Live.to_chapter_relative_xpointer(xp)
    if not xp or not Live.fragment_of(xp) then return nil end
    return (xp:gsub("/body/DocFragment%[%d+%]",
        "/body/DocFragment[" .. Live.STASH_PLACEHOLDER .. "]", 1))
end

-- Convert a chapter-relative xpointer back to an absolute one for the chapter
-- at full-list index idx in window [win_first, win_last]. nil when idx is
-- outside the window.
function Live.from_chapter_relative_xpointer(rel_xp, front, win_first, win_last, idx)
    if not rel_xp then return nil end
    if idx < win_first or idx > win_last then return nil end
    local frag = front + (idx - win_first) + 1
    return (rel_xp:gsub("/body/DocFragment%[" .. Live.STASH_PLACEHOLDER .. "%]",
        "/body/DocFragment[" .. frag .. "]", 1))
end

-- Copy an annotation item with its xpointer fields remapped to the new
-- window (the item's chapter is known to be inside). old_front/new_front as
-- in remap_xpointer. pageno/pageref are window-specific page numbers: dropped
-- here and recomputed by KOReader on the next open (the sidecar
-- "annotations_externally_modified" flag).
function Live.remap_annotation(item, old_front, new_front, old_first, new_first, new_last)
    local out = {}
    for k, v in pairs(item) do out[k] = v end
    out.page = Live.remap_xpointer(item.page, old_front, new_front, old_first, new_first, new_last)
        or item.page
    out.pos0 = Live.remap_xpointer(item.pos0, old_front, new_front, old_first, new_first, new_last)
        or item.pos0
    out.pos1 = Live.remap_xpointer(item.pos1, old_front, new_front, old_first, new_first, new_last)
        or item.pos1
    out.pageno  = nil
    out.pageref = nil
    return out
end

-- Copy an annotation item with its xpointer fields converted to the
-- chapter-relative stash form.
function Live.stash_annotation(item)
    local st = {}
    for k, v in pairs(item) do st[k] = v end
    st.page = Live.to_chapter_relative_xpointer(item.page) or item.page
    st.pos0 = Live.to_chapter_relative_xpointer(item.pos0) or item.pos0
    st.pos1 = Live.to_chapter_relative_xpointer(item.pos1) or item.pos1
    st.pageno  = nil
    st.pageref = nil
    return st
end

-- Copy a stashed annotation back into an absolute-xpointer item for chapter
-- idx in window [win_first, win_last] (idx is known to be inside).
function Live.unstash_annotation(st, front, win_first, win_last, idx)
    local out = {}
    for k, v in pairs(st) do out[k] = v end
    out.page = Live.from_chapter_relative_xpointer(st.page, front, win_first, win_last, idx)
        or st.page
    out.pos0 = Live.from_chapter_relative_xpointer(st.pos0, front, win_first, win_last, idx)
        or st.pos0
    out.pos1 = Live.from_chapter_relative_xpointer(st.pos1, front, win_first, win_last, idx)
        or st.pos1
    return out
end

-- Remap an annotation list across a window change. old_front is the front
-- count the xpointers were written under, new_front the new build's (they
-- differ when the cover page changes across a rebuild). Returns kept (items
-- inside the new window, xpointers remapped) and stash (items in chapters
-- outside the new window, chapter-relative xpointers, keyed by tostring(
-- chapter index) so JSON round-trips of state.stash keep the keys stable).
-- Items whose page is not a mappable xpointer are kept unchanged.
function Live.remap_annotations(annotations, old_front, new_front, old_first, new_first, new_last)
    local kept, stash = {}, {}
    for _, item in ipairs(annotations) do
        if type(item) ~= "table" then
            table.insert(kept, item)
        else
            local idx = type(item.page) == "string"
                and Live.chapter_at(item.page, old_front, old_first) or nil
            if idx then
                if idx < new_first or idx > new_last then
                    local key = tostring(idx)
                    stash[key] = stash[key] or {}
                    table.insert(stash[key], Live.stash_annotation(item))
                else
                    table.insert(kept, Live.remap_annotation(item, old_front,
                        new_front, old_first, new_first, new_last))
                end
            else
                table.insert(kept, item)
            end
        end
    end
    return kept, stash
end

-- Merge stashed annotations whose chapter is now inside the window back into
-- the list (as absolute-xpointer items). Consumes the merged entries from
-- stash. Keys are tostring(chapter index) to survive JSON round-trips.
function Live.merge_stashed(annotations, stash, front, win_first, win_last)
    for key, entries in pairs(stash or {}) do
        local idx = tonumber(key)
        if idx and idx >= win_first and idx <= win_last then
            for _, st in ipairs(entries) do
                table.insert(annotations, Live.unstash_annotation(st,
                    front, win_first, win_last, idx))
            end
            stash[key] = nil
        end
    end
    return annotations
end

-- ── Full mode ("Download all"): volume math ───────────────────────────────────
-- Full mode splits the novel into fixed partitions of volume_size chapters:
-- volume v holds full-list chapters (v-1)*V+1 .. min(v*V, downloaded).
-- Partition boundaries never move, so appending downloaded chapters only
-- ever adds items at the end of a volume's spine and the DocFragment numbers
-- of earlier chapters stay stable (last_xpointer, annotations remain valid).

-- Volume number (1-based) containing the chapter at full-list index chapter.
function Live.volume_of(chapter, volume_size)
    return math.ceil(chapter / volume_size)
end

-- First and last full-list chapter of volume v over 1..downloaded.
-- last < first when the volume starts past `downloaded` (nothing to build).
function Live.volume_range(v, volume_size, downloaded)
    local first = (v - 1) * volume_size + 1
    local last  = math.min(v * volume_size, downloaded)
    return first, last
end

-- Full-list chapter index for an xpointer inside volume v, or nil for front
-- matter / non-fragment xpointers. Chapter at full index i lives in the
-- volume's DocFragment[front + (i - (v-1)*V)].
function Live.volume_chapter_at(xp, front, v, volume_size)
    local frag = Live.fragment_of(xp)
    if not frag or frag <= front then return nil end
    return (v - 1) * volume_size + (frag - front)
end

-- Zero-padded volume number for a file name: at least 2 digits, 3 digits
-- from volume 100 on (i.e. once the novel spans more than 99 volumes). The
-- padding depends only on the volume number, so a volume's file name never
-- changes as later volumes appear.
function Live.volume_number_width(v)
    return v > 99 and 3 or 2
end

function Live.volume_file_name(safe_title, v)
    return ("%s - Vol %0" .. Live.volume_number_width(v) .. "d.epub"):format(safe_title, v)
end

-- Resolve the requested download mode from the book_mode setting and an
-- explicit choice (from the "How should … be downloaded?" dialog). An
-- explicit choice wins; otherwise the setting decides. nil when the setting
-- is "ask" and no choice was given (the caller must ask).
function Live.resolve_book_mode(setting, choice)
    if choice then return choice end
    if setting == "window" or setting == "full" then return setting end
    return nil
end

return Live
