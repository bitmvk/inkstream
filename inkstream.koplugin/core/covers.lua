-- Cover thumbnail cache and rendering.
--
-- Raw cover bytes are downloaded by a BgTask child into
-- <settings>/inkstream/covers/<md5(url)>.img, then decoded in the UI process
-- by RenderImage directly at the requested thumbnail size, so a full-size
-- image is never held in RAM on the small Kobo. Every BlitBuffer this module
-- hands out is tracked and freed together (free_all) when a screen is rebuilt
-- or Inkstream closes.
local Blitbuffer  = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Geom        = require("ui/geometry")
local Widget      = require("ui/widget/widget")
local logger      = require("logger")

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then lfs = require("lfs") end
local ok_ri, RenderImage = pcall(require, "ui/renderimage")
local ok_img, ImageWidget = pcall(require, "ui/widget/imagewidget")
local ok_sha2, sha2 = pcall(require, "ffi/sha2")

local Covers = {}

local covers_dir = DataStorage:getSettingsDir() .. "/inkstream/covers"
local _bbs = {}  -- decoded BlitBuffers, freed on rebuild/close

local function ensure_dir()
    require("core.epub").mkdirp(covers_dir)
end

local function md5(text)
    if ok_sha2 and sha2.md5 then return sha2.md5(text) end
    -- Last-resort fallback (sha2 is always present in KOReader).
    return (tostring(text):gsub("%W", "_")):sub(1, 32)
end

function Covers.key(url)
    return md5(url)
end

function Covers.path(url)
    return covers_dir .. "/" .. md5(url) .. ".img"
end

function Covers.has(url)
    if not url or url == "" then return false end
    return lfs.attributes(covers_dir .. "/" .. md5(url) .. ".img", "mode") == "file"
end

-- Decode image bytes at w×h and wrap them in an ImageWidget. The BlitBuffer
-- stays owned by this module (image_disposable=false) so free_all can release
-- it without double-freeing inside ImageWidget.
local function widget_from_data(data, w, h)
    if not (ok_ri and ok_img and data and data ~= "") then return nil end
    local ok, bb = pcall(RenderImage.renderImageData, RenderImage,
        data, #data, false, w, h)
    if not ok or not bb then return nil end
    _bbs[#_bbs + 1] = bb
    return ImageWidget:new{
        image             = bb,
        width             = w,
        height            = h,
        image_disposable  = false,
    }
end

-- Thumbnail for a cover already on disk, or nil when it is missing/corrupt.
function Covers.thumb_widget(url, w, h)
    if not url or url == "" then return nil end
    local f = io.open(covers_dir .. "/" .. md5(url) .. ".img", "rb")
    if not f then return nil end
    local data = f:read("*all")
    f:close()
    return widget_from_data(data, w, h)
end

-- Thumbnail from in-memory bytes (the DB.loadCoverCache fallback for older
-- tracked novels whose cover URL was never stored).
function Covers.thumb_widget_from_data(data, w, h)
    return widget_from_data(data, w, h)
end

-- ── Placeholder ───────────────────────────────────────────────────────────────

local Placeholder = Widget:extend{}

function Placeholder:init()
    self.dimen = self.dimen or Geom:new{ w = 10, h = 10 }
end

function Placeholder:paintTo(bb, x, y)
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_LIGHT_GRAY)
end

-- A light-grey box shown while a cover is still downloading.
function Covers.placeholder(w, h)
    return Placeholder:new{ dimen = Geom:new{ w = w, h = h } }
end

-- ── Download (BgTask child) ───────────────────────────────────────────────────

local function fetch_bytes(url)
    if not url or url == "" then return nil end
    local ok_h, https = pcall(require, "ssl.https")
    local ok_p, http  = pcall(require, "socket.http")
    if not ok_h and not ok_p then return nil end
    local ltn12 = require("ltn12")
    local sink = {}
    local req  = (ok_h and url:match("^https")) and https or http
    if not req then return nil end
    local ok, code = req.request{
        url     = url,
        sink    = ltn12.sink.table(sink),
        headers = { ["User-Agent"] = "Mozilla/5.0 (Linux; Android 9; KOReader)" },
        timeout = 15,
    }
    if not ok or code ~= 200 then
        logger.warn("Inkstream/Covers: fetch failed", url, tostring(code))
        return nil
    end
    local data = table.concat(sink)
    return data ~= "" and data or nil
end

-- Child-side body: write each {key, url} that is not already on disk.
function Covers.download_all(items)
    ensure_dir()
    local failed = {}
    for _, it in ipairs(items or {}) do
        local p = covers_dir .. "/" .. it.key .. ".img"
        if lfs.attributes(p, "mode") ~= "file" then
            local data = fetch_bytes(it.url)
            if data then
                local f = io.open(p, "wb")
                if f then
                    f:write(data)
                    f:close()
                else
                    failed[#failed + 1] = it.key
                end
            else
                failed[#failed + 1] = it.key
            end
        end
    end
    return { failed = failed }
end

-- {key, url} list for the covers in `items` (each item may be a URL string or
-- a {url=...} table) that are not yet on disk.
function Covers.missing(items)
    local out = {}
    for _, it in ipairs(items or {}) do
        local url = type(it) == "table" and it.url or it
        if url and url ~= "" and not Covers.has(url) then
            out[#out + 1] = { key = Covers.key(url), url = url }
        end
    end
    return out
end

-- Download any missing covers in a BgTask child and call done_cb once the
-- child finishes (done_cb is not called when nothing needs downloading).
function Covers.request(items, done_cb)
    local missing = Covers.missing(items)
    if #missing == 0 then return end
    local BgTask = require("core.bgtask")
    BgTask.start("covers", BgTask.child(function()
        local C = require("core.covers")
        return C.download_all(missing)
    end), done_cb)
end

-- ── Memory ────────────────────────────────────────────────────────────────────

function Covers.free_all()
    for _, bb in ipairs(_bbs) do
        pcall(bb.free, bb)
    end
    _bbs = {}
end

return Covers
