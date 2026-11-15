-- spec/live_build_check.lua — end-to-end live build check without the GUI.
--
-- Stubs only the KOReader modules core/epub.lua + core/livebook.lua need
-- (logger, datastorage, lfs, ffi/sha2, JSON, G_reader_settings, and the HTTP
-- stack via io.popen("curl ...")), loads the REAL NovelFull extension,
-- builds a live window for https://novelfull.com/martial-peak.html centred on
-- chapter 5, shifts the window to centre 12 through the refill path's build
-- function, and checks the EPUB structure + xpointer remapping (a chapter
-- that falls out of the window maps to nil; one inside both windows keeps
-- its position in the new fragment numbering). It also rebuilds across a
-- front-matter change (cover lost/regained, A2) and checks that positions
-- stay in the right chapter.
--
-- Run from the repo root:  luajit spec/live_build_check.lua
-- Requires: luajit, curl, unzip, network access to novelfull.com + GitHub.

local spec_path = debug.getinfo(1, "S").source:sub(2)
local repo_root = spec_path:match("^(.*)/spec/[^/]+%.lua$") or "."
package.path = repo_root .. "/inkstream.koplugin/?.lua;"
    .. repo_root .. "/inkstream.koplugin/?/init.lua;" .. package.path

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
local function check_true(name, cond)
    check(name, cond == true, true)
end

local tmp_root = "/tmp/inkstream_livebuild_" .. tostring(os.time())
local check_dir = tmp_root .. "/check"
local home_dir  = tmp_root .. "/home"

local function sh_quote(s) return '"' .. tostring(s):gsub('"', '\\"') .. '"' end
-- Note: in sandboxed shells io.popen's exit status can be unreliable, so
-- callers must inspect command OUTPUT (or resulting files), not just the
-- status. That is what the helpers below do.
local function sh(cmd)
    local f = io.popen(cmd .. " 2>&1")
    local out = f:read("*a")
    f:close()
    return out
end

-- ── KOReader module stubs ─────────────────────────────────────────────────────

package.loaded["logger"] = {
    dbg  = function() end,
    info = function() end,
    warn = function(...) print("WARN", ...) end,
    err  = function(...) print("ERROR", ...) end,
}

local function is_dir(p)
    p = p:gsub("/+$", "")
    if p == "" then return true end
    local f = io.popen("if [ -d " .. sh_quote(p) .. " ]; then echo YES; fi")
    local out = f:read("*a")
    f:close()
    return out:match("YES") ~= nil
end

local lfs_stub = {}
-- Non-recursive, like the real lfs.mkdir (a recursive stub hid a bug).
function lfs_stub.mkdir(p) sh("mkdir " .. sh_quote(p) .. " 2>/dev/null") end
function lfs_stub.attributes(path, key)
    if not path then return nil end
    path = path:gsub("/+$", "")
    if path == "" then path = "/" end
    if key == "mode" then
        if is_dir(path) then return "directory" end
        local f = io.open(path, "rb")
        if f then f:close(); return "file" end
        return nil
    elseif key == "size" then
        local f = io.open(path, "rb")
        if f then local sz = f:seek("end"); f:close(); return sz end
        return nil
    elseif key == "modification" then
        local f = io.popen("stat -c %Y " .. sh_quote(path) .. " 2>/dev/null")
        local out = f:read("*a")
        f:close()
        return tonumber(out)
    end
    if is_dir(path) then return {} end
    local f = io.open(path, "rb")
    if f then f:close(); return {} end
    return nil
end
function lfs_stub.touch(path, atime, mtime)
    sh("touch -a -d @" .. tostring(atime) .. " " .. sh_quote(path)
        .. " && touch -m -d @" .. tostring(mtime) .. " " .. sh_quote(path))
end
package.loaded["lfs"] = lfs_stub

package.loaded["datastorage"] = {
    getSettingsDir = function() return tmp_root .. "/settings" end,
    getFullDataDir = function() return tmp_root .. "/data" end,
    getDataDir     = function() return tmp_root .. "/data" end,
}

_G.G_reader_settings = {
    readSetting = function(self, key)
        if key == "home_dir" then return home_dir end
        return nil
    end,
}

-- Filesystem-safe stand-in for ffi/sha2.md5.
package.loaded["ffi/sha2"] = {
    md5 = function(s)
        local h = 5381
        for i = 1, #s do h = (h * 33 + s:byte(i)) % 2^31 end
        return string.format("%08x", h)
    end,
}

-- Minimal dependency-free JSON codec (values, arrays, string-keyed objects).
local json = {}
local function encode(v)
    local t = type(v)
    if t == "nil" then return "null" end
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then return tostring(v) end
    if t == "string" then
        return '"' .. v:gsub('[%z\1-\31\\"]', function(c)
            if c == '"' then return '\\"' end
            if c == '\\' then return '\\\\' end
            if c == '\n' then return '\\n' end
            if c == '\r' then return '\\r' end
            if c == '\t' then return '\\t' end
            if c == '\b' then return '\\b' end
            if c == '\f' then return '\\f' end
            return string.format("\\u%04x", c:byte())
        end) .. '"'
    end
    local count, is_arr = 0, true
    for k in pairs(v) do
        count = count + 1
        if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then is_arr = false end
    end
    if count == 0 then return "{}" end
    if is_arr and count == #v then
        local parts = {}
        for i = 1, #v do parts[i] = encode(v[i]) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local parts = {}
    for k, val in pairs(v) do
        table.insert(parts, encode(tostring(k)) .. ":" .. encode(val))
    end
    return "{" .. table.concat(parts, ",") .. "}"
end
local function decode(s)
    local pos = 1
    local function fail(msg) error("json decode: " .. msg .. " at " .. pos, 2) end
    local function ws() while s:sub(pos, pos):match("[ \t\r\n]") do pos = pos + 1 end end
    local function value()
        ws()
        local c = s:sub(pos, pos)
        if c == '{' then
            pos = pos + 1
            local obj = {}
            ws()
            if s:sub(pos, pos) == '}' then pos = pos + 1; return obj end
            while true do
                ws()
                local key = value()
                ws()
                if s:sub(pos, pos) ~= ':' then fail("expected :") end
                pos = pos + 1
                obj[key] = value()
                ws()
                local d = s:sub(pos, pos); pos = pos + 1
                if d == '}' then return obj end
                if d ~= ',' then fail("expected , or }") end
            end
        elseif c == '[' then
            pos = pos + 1
            local arr = {}
            ws()
            if s:sub(pos, pos) == ']' then pos = pos + 1; return arr end
            while true do
                arr[#arr + 1] = value()
                ws()
                local d = s:sub(pos, pos); pos = pos + 1
                if d == ']' then return arr end
                if d ~= ',' then fail("expected , or ]") end
            end
        elseif c == '"' then
            pos = pos + 1
            local out = {}
            while true do
                local ch = s:sub(pos, pos)
                if ch == '' then fail("unterminated string") end
                if ch == '"' then pos = pos + 1; return table.concat(out) end
                if ch == '\\' then
                    pos = pos + 1
                    local e = s:sub(pos, pos); pos = pos + 1
                    if e == 'n' then out[#out + 1] = '\n'
                    elseif e == 'r' then out[#out + 1] = '\r'
                    elseif e == 't' then out[#out + 1] = '\t'
                    elseif e == 'b' then out[#out + 1] = '\b'
                    elseif e == 'f' then out[#out + 1] = '\f'
                    elseif e == '/' then out[#out + 1] = '/'
                    elseif e == '\\' then out[#out + 1] = '\\'
                    elseif e == '"' then out[#out + 1] = '"'
                    elseif e == 'u' then
                        out[#out + 1] = string.char(tonumber(s:sub(pos, pos + 3), 16))
                        pos = pos + 4
                    else fail("bad escape") end
                else
                    out[#out + 1] = ch
                    pos = pos + 1
                end
            end
        elseif c == 't' then
            pos = pos + 4; return true
        elseif c == 'f' then
            pos = pos + 5; return false
        elseif c == 'n' then
            pos = pos + 4; return nil
        else
            local num = s:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
            if not num or num == "" then fail("unexpected char") end
            pos = pos + #num
            return tonumber(num)
        end
    end
    local v = value()
    ws()
    if pos <= #s then fail("trailing data") end
    return v
end
json.encode = encode
json.decode = decode
package.loaded["json"] = json

-- HTTP via curl (the real extension does ssl.https/socket.http + ltn12).
local function curl(url)
    local f = io.popen("curl -sS -L --max-time 45 "
        .. '-A "Mozilla/5.0 (Linux; Android 9; KOReader)" '
        .. sh_quote(url) .. " 2>/dev/null")
    if not f then return nil end
    local body = f:read("*a")
    local ok = f:close()
    if not ok or body == "" then return nil end
    return body
end
local function http_request(params)
    local body = curl(params.url)
    if not body then return nil, "fetch_failed" end
    if params.sink then params.sink(body) end
    return 1, 200
end
package.loaded["socket.http"] = { request = http_request }
package.loaded["ssl.https"]   = { request = http_request }
package.loaded["ltn12"] = {
    sink = {
        table = function(t)
            return function(chunk, err)
                if chunk and chunk ~= "" then table.insert(t, chunk) end
                return 1
            end
        end,
    },
}

-- ── LuaSettings stub ──────────────────────────────────────────────────────────
-- Same open/readSetting/saveSetting/flush surface the plugin's settings.lua
-- uses, backed by a JSON file.

local luasettings = {}
function luasettings:open(path)
    local data = {}
    local f = io.open(path, "r")
    if f then
        local raw = f:read("*a"); f:close()
        local ok, d = pcall(json.decode, raw)
        if ok and type(d) == "table" then data = d end
    end
    return {
        readSetting = function(_, key) return data[key] end,
        saveSetting = function(_, key, value) data[key] = value end,
        flush = function(_)
            local f2 = io.open(path, "w")
            if f2 then f2:write(json.encode(data)); f2:close() end
        end,
    }
end
package.loaded["luasettings"] = luasettings

-- ── DocSettings stub ──────────────────────────────────────────────────────────
-- Same API surface the plugin uses (open / readSetting / saveSetting / flush /
-- updateLocation), storing JSON in the usual "<file>.sdr/metadata.epub.lua"
-- location. The REAL frontend/docsettings.lua cannot load here: it needs most
-- of KOReader (device, ffiutil, util, gettext, …), so the spec says so and
-- uses this stub instead.

local docsettings_stub = {}
local function sidecar_file(doc_path)
    local base   = doc_path:match("^(.*)%.[^/\\]+$") or doc_path
    local suffix = doc_path:match("%.([^%.]+)$") or "_"
    return base .. ".sdr/metadata." .. suffix .. ".lua"
end
function docsettings_stub:open(doc_path)
    local path = sidecar_file(doc_path)
    local data = {}
    local f = io.open(path, "r")
    if f then
        local raw = f:read("*a"); f:close()
        local ok, d = pcall(json.decode, raw)
        if ok and type(d) == "table" then data = d end
    end
    return {
        readSetting = function(_, key) return data[key] end,
        saveSetting = function(_, key, value) data[key] = value end,
        flush = function(_)
            sh("mkdir -p " .. sh_quote(path:match("^(.*)/[^/]+$") or "."))
            local f2 = io.open(path, "w")
            if f2 then f2:write(json.encode(data)); f2:close() end
        end,
    }
end
function docsettings_stub.updateLocation(doc_path, new_doc_path)
    local src = sidecar_file(doc_path)
    local dst = sidecar_file(new_doc_path)
    local dir = dst:match("^(.*)/[^/]+$")
    if dir then sh("mkdir -p " .. sh_quote(dir)) end
    sh("cp -f " .. sh_quote(src) .. " " .. sh_quote(dst) .. " 2>/dev/null")
    local src_dir = src:match("^(.*)/[^/]+$")
    if src_dir then sh("rm -rf " .. sh_quote(src_dir)) end
end
package.loaded["docsettings"] = docsettings_stub

-- ── Load the real extension ───────────────────────────────────────────────────

sh("mkdir -p " .. sh_quote(check_dir))
check_true("check dir created", is_dir(check_dir))

local ext_path = check_dir .. "/novelfull.lua"
sh("curl -sS -L --max-time 60 -o " .. sh_quote(ext_path)
    .. " https://raw.githubusercontent.com/bitmvk/mythosext/refs/heads/main/extensions/novelfull.lua")
local f_ext = io.open(ext_path, "rb")
check_true("extension downloaded", f_ext ~= nil)
if f_ext then f_ext:close() end
local ext = dofile(ext_path)
check_true("extension loaded", type(ext) == "table" and type(ext.parseChapter) == "function"
    and type(ext.parseNovel) == "function")

-- Now load the real core modules under test (they pick up the stubs above).
local LiveBook = require("core.livebook")
local Live     = require("core.live")
local DB       = require("core.db")

-- ── live_books_dir setting is respected by epub_path_for ──────────────────────

local Settings = require("settings")
local live_dir_custom = tmp_root .. "/livebooks"
Settings:set("live_books_dir", live_dir_custom)
check("epub_path_for uses live_books_dir",
    LiveBook.epub_path_for("Test Book"), live_dir_custom .. "/Test Book.epub")
Settings:set("live_books_dir", nil)
check("epub_path_for falls back to home dir",
    LiveBook.epub_path_for("Test Book"), home_dir .. "/Test Book.epub")
check_true("epub_path_for sanitises the title",
    LiveBook.epub_path_for('A/B:C'):match("^" .. home_dir .. "/A_B_C%.epub$") ~= nil)

local NOVEL_PATH = "/martial-peak.html"
local SOURCE_ID  = "novelfull"

-- ── Build the first live window (centred on chapter 5) ───────────────────────

print("Fetching novel metadata + chapter list (2 HTTP requests)…")
local novel = ext:parseNovel(NOVEL_PATH)
check_true("parseNovel ok", novel ~= nil and novel.chapters and #novel.chapters > 20)
if not novel or not novel.chapters or #novel.chapters == 0 then
    print("ABORT: could not fetch the chapter list")
    os.exit(1)
end
local chapters = novel.chapters
DB.saveChapterCache(SOURCE_ID, NOVEL_PATH, chapters, #chapters)
check_true("chapter cache saved + reloadable",
    #(LiveBook.chapter_list(SOURCE_ID, NOVEL_PATH) or {}) == #chapters)

local meta = {
    title     = novel.name or "Martial Peak",
    author    = novel.author,
    summary   = novel.summary,
    cover_url = novel.cover,
}
print("Building live window centred on chapter 5…")
local state, err = LiveBook.new_start(ext, meta, SOURCE_ID, NOVEL_PATH, 5, chapters)
check_true("new_start ok (err=" .. tostring(err) .. ")", state ~= nil)
if not state then
    print("ABORT: new_start failed")
    sh("rm -rf " .. sh_quote(tmp_root))
    os.exit(1)
end

check("window first", state.win_first, 3)
check("window last", state.win_last, 13)
check("window cur", state.cur, 5)
check("window total", state.total, #chapters)
check("window furthest starts at cur", state.furthest, 5)
check_true("created_at recorded at first build",
    type(state.created_at) == "number")

local epub = state.epub_path
print("EPUB path: " .. epub)

local f = io.open(epub, "rb")
check_true("epub exists", f ~= nil)
if f then f:close() end

-- Stable file date: the fresh build's mtime is created_at.
check("epub mtime equals created_at after first build",
    lfs_stub.attributes(epub, "modification"), state.created_at)

local function epub_entry(name)
    local p = io.popen("unzip -p " .. sh_quote(epub) .. " " .. sh_quote(name))
    local data = p:read("*a")
    p:close()
    return data
end

-- "unzip -t" validity is judged from its output (exit status is unreliable
-- in sandboxed shells).
local function unzip_ok(epub)
    local f = io.popen("unzip -t " .. sh_quote(epub) .. " 2>&1")
    local out = f:read("*a")
    f:close()
    return out:match("No errors detected") ~= nil, out
end

local ok_zip, zip_out = unzip_ok(epub)
check_true("epub is a valid zip", ok_zip)
if not ok_zip then print(zip_out) end

local mimetype = epub_entry("mimetype")
check("mimetype entry", mimetype, "application/epub+zip")

local front = state.front or 0
check_true("front is 0 or 1", front == 0 or front == 1)

local opf = epub_entry("OEBPS/content.opf")
local spine_count = select(2, opf:gsub("<itemref", ""))
check("opf spine count = front + window",
    spine_count, front + (state.win_last - state.win_first + 1))
check_true("opf has no synopsis item", not opf:match("synopsis"))
check_true("opf has no toc-page item", not opf:match("toc%-page"))

-- Series index = the current chapter's chapter_number at build time.
local want_series5 = tostring(chapters[5].chapter_number or 5)
check("opf series_index is the current chapter (build at ch 5)",
    opf:match('<meta name="calibre:series_index" content="([^"]+)"/>'),
    want_series5)

-- NCX: chapter navPoints (ids n1..) match the window titles.
local ncx = epub_entry("OEBPS/toc.ncx")
local xml_esc = function(s)
    return (s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
end
local ncx_ok = true
for i = state.win_first, state.win_last do
    local k = i - state.win_first + 1
    local block = ncx:match('<navPoint id="n' .. k .. '"(.-)</navPoint>')
    local want = "<text>" .. xml_esc(chapters[i].name or ("Chapter " .. i)) .. "</text>"
    if not block or not block:find(want, 1, true) then
        ncx_ok = false
        print("  ncx mismatch at window pos " .. k
            .. " (chapter " .. i .. "): " .. tostring(chapters[i].name))
    end
end
check_true("ncx chapter titles match window", ncx_ok)

-- ── Shift the window to centre 12 via the central rebuild path ────────────────
-- The sidecar gets a fake annotation list (a highlight in chapter 4, which
-- leaves the window, and one in chapter 12, which stays), so the rebuild must
-- remap one and stash the other. KOReader's real docsettings.lua cannot load
-- in this stub environment, so the stub installed above stands in (same API).

print("Shifting window to centre on chapter 12…")
-- Finding 3: goto_chapter calls plan_and_fetch via pcall with exactly
-- (ext, state, chapters, idx) — no leading LiveBook argument.
local ok_shift, first12, last12, items12 = pcall(LiveBook.plan_and_fetch,
    ext, state, chapters, 12)
check_true("plan_and_fetch via pcall (goto_chapter form)", ok_shift)
check("shift window first", first12, 10)
check("shift window last", last12, 20)
check("shift item count", #items12, last12 - first12 + 1)

local function old_frag(idx) return front + (idx - 3) + 1 end
local function old_xp(idx)
    return "/body/DocFragment[" .. old_frag(idx) .. "]/body/div/p[3]/text().0"
end

-- Fake sidecar: one annotation in chapter 4 (leaves on the shift, returns on
-- the way back), one in chapter 16 (stays on the shift, leaves on the way
-- back). Chapter 16's fragment in the old window [3,13] is front+14.
local DocSettings = require("docsettings")
local ds0 = DocSettings:open(epub)
ds0:saveSetting("annotations", {
    { page = old_xp(4),  pos0 = old_xp(4),  pos1 = old_xp(4) .. ".2",
      chapter = chapters[4] and chapters[4].name,  text = "first",
      datetime = "2026-01-01T00:00:00", pageno = 4 },
    { page = old_xp(16), pos0 = old_xp(16), pos1 = old_xp(16) .. ".1",
      chapter = chapters[16] and chapters[16].name, text = "second",
      datetime = "2026-01-01T00:00:01", pageno = 16 },
})
ds0:flush()

-- Force an old creation date so the rebuild must touch the mtime back to it.
state.created_at = os.time() - 3600
LiveBook.save_state(state)

local cover_data, cover_ext = LiveBook.load_cover(state)
local ok_central = LiveBook.rebuild_window_sidecar(state, chapters, 12,
    first12, last12, items12, cover_data, cover_ext, old_xp(16))
check_true("central rebuild ok", ok_central == true)
check("state.win_first updated", state.win_first, 10)
check("state.win_last updated", state.win_last, 20)
check("state.cur updated to centre", state.cur, 12)
check("state.furthest extends to centre", state.furthest, 12)

-- Stable file date: mtime is back to created_at after the rebuild.
check("epub mtime equals created_at after rebuild",
    lfs_stub.attributes(epub, "modification"), state.created_at)

-- Rebuilt EPUB: still a valid zip with the new spine.
local ok_zip2, zip_out2 = unzip_ok(epub)
check_true("rebuilt epub is a valid zip", ok_zip2)
if not ok_zip2 then print(zip_out2) end
local opf2 = epub_entry("OEBPS/content.opf")
local spine_count2 = select(2, opf2:gsub("<itemref", ""))
check("rebuilt spine count", spine_count2, front + (20 - 10 + 1))

-- Series index now reflects the new current chapter.
local want_series12 = tostring(chapters[12].chapter_number or 12)
check("opf series_index is the current chapter (recentre to ch 12)",
    opf2:match('<meta name="calibre:series_index" content="([^"]+)"/>'),
    want_series12)

-- Sidecar: last_xpointer remapped to the captured position in chapter 16
-- (old fragment front+14 → new fragment front+7).
local ds1 = DocSettings:open(epub)
check("last_xpointer remapped to ch 16 position",
    ds1:readSetting("last_xpointer"),
    "/body/DocFragment[" .. (front + 7) .. "]/body/div/p[3]/text().0")
check("annotations_externally_modified flag set",
    ds1:readSetting("annotations_externally_modified"), true)

-- Annotations: chapter 16's stays (remapped); chapter 4's is stashed.
local ann1 = ds1:readSetting("annotations")
check("annotations kept in window", #ann1, 1)
check("kept annotation remapped", ann1[1].page,
    "/body/DocFragment[" .. (front + 7) .. "]/body/div/p[3]/text().0")
check("kept annotation pos1 remapped", ann1[1].pos1,
    "/body/DocFragment[" .. (front + 7) .. "]/body/div/p[3]/text().0.1")
check("kept annotation text untouched", ann1[1].text, "second")
check_true("chapter 4 annotation stashed", state.stash["4"] ~= nil)
check("stashed xpointer is chapter-relative", state.stash["4"][1].page,
    "/body/DocFragment[" .. Live.STASH_PLACEHOLDER
    .. "]/body/div/p[3]/text().0")

-- ── Xpointer remapping across the shift (old window [3,13] → new [10,20]) ─────

-- Chapter 6 was readable in the old window, but lies outside the new one.
check("remap chapter 6 across shift (outside → nil)",
    Live.remap_xpointer(old_xp(6), front, front, 3, 10, 20), nil)

-- Chapter 12 is inside both windows: fragment front+10 → front+3.
check("chapter_at ch12 in old window", Live.chapter_at(old_xp(12), front, 3), 12)
check("remap chapter 12 across shift",
    Live.remap_xpointer(old_xp(12), front, front, 3, 10, 20),
    "/body/DocFragment[" .. (front + 3) .. "]/body/div/p[3]/text().0")

-- And the new window's chapter start xpointer for the shifted centre.
check("chapter start xpointer after shift",
    Live.chapter_start_xpointer(front, 10, 12),
    "/body/DocFragment[" .. (front + 3) .. "]")

-- ── Shift back to chapter 5: the stashed annotation returns unchanged ────────

print("Shifting window back to centre on chapter 5…")
local ok_back, first5, last5, items5 = pcall(LiveBook.plan_and_fetch,
    ext, state, chapters, 5)
check_true("plan_and_fetch back via pcall", ok_back)
check("back window first", first5, 3)
check("back window last", last5, 13)

local ok_central2 = LiveBook.rebuild_window_sidecar(state, chapters, 5,
    first5, last5, items5, cover_data, cover_ext, nil)
check_true("back central rebuild ok", ok_central2 == true)
check("back state.win_first", state.win_first, 3)
check("back state.cur", state.cur, 5)
check("back state.furthest kept", state.furthest, 12)

local ds2 = DocSettings:open(epub)
check("back last_xpointer is ch 5 start",
    ds2:readSetting("last_xpointer"),
    "/body/DocFragment[" .. (front + 3) .. "]")

-- The chapter-4 annotation comes back with its ORIGINAL xpointers; the
-- chapter-16 one (now outside [3,13]) is stashed in its place.
local ann2 = ds2:readSetting("annotations")
check("back annotations count", #ann2, 1)
check("returned annotation page round trip", ann2[1].page, old_xp(4))
check("returned annotation pos0 round trip", ann2[1].pos0, old_xp(4))
check("returned annotation pos1 round trip", ann2[1].pos1, old_xp(4) .. ".2")
check("returned annotation text untouched", ann2[1].text, "first")
check_true("chapter 16 annotation stashed on the way back",
    state.stash["16"] ~= nil)
check("chapter 16 stashed xpointer is chapter-relative",
    state.stash["16"][1].page,
    "/body/DocFragment[" .. Live.STASH_PLACEHOLDER
    .. "]/body/div/p[3]/text().0")
check("chapter 4 stash consumed", state.stash["4"], nil)

-- Series index follows the new centre on the way back too.
local opf3 = epub_entry("OEBPS/content.opf")
local want_series5b = tostring(chapters[5].chapter_number or 5)
check("opf series_index is the current chapter (recentre back to ch 5)",
    opf3:match('<meta name="calibre:series_index" content="([^"]+)"/>'),
    want_series5b)

-- ── A2: front changes across a rebuild (cover lost or regained) ───────────────
-- rebuild_window_sidecar must read saved xpointers with the OLD front and
-- write them with the NEW one, so positions stay in the right chapter when
-- the cover page appears/disappears across a rebuild.

print("Rebuilding across a front change (A2)…")
local old_front_a2 = state.front or 0
local new_front_want = old_front_a2 == 1 and 0 or 1
local ok_a2
if old_front_a2 == 1 then
    -- Simulate "the cover fetch failed once": unreachable URL, no cached
    -- bytes passed to the rebuild.
    local real_cover = state.cover_url
    state.cover_url = "http://127.0.0.1:1/no-cover.jpg"
    LiveBook.save_state(state)
    ok_a2 = LiveBook.rebuild_window_sidecar(state, chapters, 12,
        first12, last12, items12, nil, nil, old_xp(16))
    state.cover_url = real_cover
    LiveBook.save_state(state)
else
    -- The cover became available again: pre-fetched (fake) bytes.
    ok_a2 = LiveBook.rebuild_window_sidecar(state, chapters, 12,
        first12, last12, items12, "\255\216fakejpeg", "jpg", old_xp(16))
end
check_true("A2 rebuild ok", ok_a2 == true)
check("A2 front changed across the rebuild", state.front or 0, new_front_want)

-- last_xpointer: captured in chapter 16 under the old front, written under
-- the new one — the chapter must not shift by one.
local ds_a2 = DocSettings:open(epub)
check("A2 last_xpointer lands in ch 16 under the new front",
    ds_a2:readSetting("last_xpointer"),
    "/body/DocFragment[" .. (new_front_want + 7) .. "]/body/div/p[3]/text().0")
check_true("A2 no position drift (chapter_at under the new front)",
    Live.chapter_at(ds_a2:readSetting("last_xpointer"),
        new_front_want, 10) == 16)

-- Annotations: the chapter-4 item (written under the old front) is stashed
-- again; the stashed chapter-16 item returns under the NEW front.
local ann_a2 = ds_a2:readSetting("annotations")
check("A2 annotations kept in window", #ann_a2, 1)
check("A2 kept annotation is ch 16 under the new front", ann_a2[1].page,
    "/body/DocFragment[" .. (new_front_want + 7) .. "]/body/div/p[3]/text().0")
check_true("A2 ch4 annotation stashed again", state.stash["4"] ~= nil)
check("A2 ch16 stash consumed", state.stash["16"], nil)

-- Rebuilt spine uses the new front.
local opf_a2 = epub_entry("OEBPS/content.opf")
local spine_a2 = select(2, opf_a2:gsub("<itemref", ""))
check("A2 spine count under the new front", spine_a2, new_front_want + 11)

-- ── Finding 2 + 4: failures are never cached; the cache stays window-bounded ──
-- Use a stub extension with a deterministic chapter list (no network) so one
-- chapter can be forced to fail.

local TITLE2  = "Cache Check"
local PATH2   = "/cache-check.html"
local SOURCE2 = "stub"

local chlist = {}
for i = 1, 40 do
    chlist[i] = { name = "Ch " .. i, path = "/cache-check/chapter-" .. i }
end

local FAIL_PATH = "/cache-check/chapter-5"
local fetch_log = {}
local stub_ext = {
    parseChapter = function(self, path)
        table.insert(fetch_log, path)
        if path == FAIL_PATH then return nil end  -- forced failure
        return "<p>content " .. path .. "</p>"
    end,
}

local meta2 = { title = TITLE2, author = "stub", summary = nil, cover_url = nil }
local state2, err2 = LiveBook.new_start(stub_ext, meta2, SOURCE2, PATH2, 5, chlist)
check_true("stub build ok (err=" .. tostring(err2) .. ")", state2 ~= nil)
if not state2 then
    print("ABORT: stub build failed")
    sh("rm -rf " .. sh_quote(tmp_root))
    os.exit(1)
end

local function window_paths(first, last)
    local out = {}
    for i = first, last do out[#out + 1] = "/cache-check/chapter-" .. i end
    return out
end
local function keys_equal(map, want_paths)
    local n = 0
    for _ in pairs(map) do n = n + 1 end
    if n ~= #want_paths then return false end
    for _, p in ipairs(want_paths) do
        if map[p] == nil then return false end
    end
    return true
end

-- Chapter 5 lies in the first window [3,13] but its fetch failed, so it must
-- be absent from the cache while the other window chapters are present.
local map2 = LiveBook.load_window_chapters(state2.key)
check("failed chapter not cached", map2[FAIL_PATH], nil)
check_true("successful chapter cached", map2["/cache-check/chapter-3"] ~= nil)
local want1 = {}
for i = 3, 13 do
    if i ~= 5 then want1[#want1 + 1] = "/cache-check/chapter-" .. i end
end
check_true("cache is exactly the window's successful chapters",
    keys_equal(map2, want1))

-- A later plan_and_fetch must refetch the failed chapter (and only it: the
-- other chapters are still cached).
fetch_log = {}
local rf, rl, ritems = LiveBook.plan_and_fetch(stub_ext, state2, chlist, 5)
check("refetch window first", rf, 3)
check("refetch window last", rl, 13)
local refetched = false
for _, p in ipairs(fetch_log) do
    if p == FAIL_PATH then refetched = true end
end
check_true("failed chapter refetched on later plan_and_fetch", refetched)

-- Shifting the window prunes the cache to exactly the new window's paths.
local sf, sl, sitems = LiveBook.plan_and_fetch(stub_ext, state2, chlist, 12)
local ok_sb = LiveBook.build_window(state2, chlist, sf, sl, sitems, nil, nil)
check_true("stub shift build ok", ok_sb == true)
check_true("cache keys are exactly the new window",
    keys_equal(LiveBook.load_window_chapters(state2.key), window_paths(sf, sl)))

-- ── Cleanup + summary ─────────────────────────────────────────────────────────

sh("rm -rf " .. sh_quote(tmp_root))
print(("---- %d passed, %d failed ----"):format(n_pass, n_fail))
if n_fail > 0 then os.exit(1) end
os.exit(0)
