-- core/updater.lua — Inkstream OTA updater
-- Checks GitHub releases API, downloads inkstream.koplugin.zip, unzips in-place,
-- deletes the zip, then offers a KOReader restart. autoCheck() runs silently
-- when Inkstream opens and only speaks up when a newer release exists;
-- checkNow() is the manual check from Settings.

local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox  = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local logger      = require("logger")

local Updater = {}

local GITHUB_OWNER = "bitmvk"
local GITHUB_REPO  = "inkstream"
local ASSET_NAME   = "inkstream.koplugin.zip"
local API_URL      = "https://api.github.com/repos/bitmvk/inkstream/releases/latest"

-- core/ directory (where this file lives)
local _core_dir   = (debug.getinfo(1, "S").source or ""):match("^@?(.+)/[^/]+%.lua$") or ""
-- inkstream.koplugin/ — one level up from core/
local _plugin_dir = _core_dir:match("^(.+)/[^/]+$") or _core_dir
-- plugins/ directory — one level up from inkstream.koplugin/; zip extracts here
local _parent_dir = _plugin_dir:match("^(.+)/[^/]+$") or _plugin_dir

-- ── Version helpers ───────────────────────────────────────────────────────────

local function current_version()
    return _G.INKSTREAM_VERSION or "0.0.0"
end

-- Returns true if semver string a is strictly greater than b.
-- Strips "v" prefix and pre-release suffixes before comparing.
local function version_gt(a, b)
    local function parts(v)
        v = (v or ""):match("^v?(.-)[-+]") or (v or ""):match("^v?(.+)$") or ""
        local t = {}
        for n in (v .. "."):gmatch("(%d+)%.") do t[#t + 1] = tonumber(n) or 0 end
        while #t < 3 do t[#t + 1] = 0 end
        return t
    end
    local pa, pb = parts(a), parts(b)
    for i = 1, 3 do
        if pa[i] > pb[i] then return true end
        if pa[i] < pb[i] then return false end
    end
    return false
end

-- ── HTTP ──────────────────────────────────────────────────────────────────────

local function _request(url, sink, extra_headers)
    local https = require("ssl.https")
    local http  = require("socket.http")
    local ltn12 = require("ltn12")
    local req   = url:match("^https") and https or http
    local headers = { ["User-Agent"] = "KOReader-Inkstream-Updater" }
    if extra_headers then
        for k, v in pairs(extra_headers) do headers[k] = v end
    end
    local ok, code, resp_headers = req.request{
        url     = url,
        sink    = sink,
        headers = headers,
        timeout = 20,
    }
    return ok, code, resp_headers
end

local function http_get(url)
    local ltn12 = require("ltn12")
    local sink  = {}
    local ok, code = _request(url, ltn12.sink.table(sink), {
        ["Accept"] = "application/vnd.github.v3+json",
    })
    logger.dbg("Inkstream/Updater: GET", url, "→", tostring(code))
    if not ok or code ~= 200 then return nil, tostring(code) end
    return table.concat(sink)
end

-- GitHub release asset URLs redirect (302) to the CDN. We follow one redirect.
local function http_download(url, dest)
    local ltn12 = require("ltn12")

    -- First request: may return 302 with a Location header. Discard the body:
    -- when the URL answers 200 directly it is the whole zip, and buffering it
    -- in memory would double both the memory and the traffic of the install.
    local ok, code, resp_headers = _request(url, ltn12.sink.null(), nil)
    logger.dbg("Inkstream/Updater: download probe", url, "→", tostring(code))

    local final_url = url
    if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
        local location = resp_headers and (resp_headers["location"] or resp_headers["Location"])
        if not location then
            return nil, "redirect with no Location header"
        end
        logger.dbg("Inkstream/Updater: following redirect →", location)
        final_url = location
    elseif not ok or code ~= 200 then
        return nil, tostring(code)
    end

    -- Second (or only) request: stream directly to disk.
    local fh, err = io.open(dest, "wb")
    if not fh then return nil, "cannot open dest: " .. tostring(err) end
    local ok2, code2 = _request(final_url, ltn12.sink.file(fh), nil)
    -- ltn12.sink.file closes fh automatically
    logger.dbg("Inkstream/Updater: download stream", final_url, "→", tostring(code2))
    if not ok2 or code2 ~= 200 then
        pcall(os.remove, dest)
        return nil, tostring(code2)
    end
    return true
end

-- ── Release parsing ───────────────────────────────────────────────────────────

local function parse_release(body)
    local ok_j, JSON = pcall(require, "rapidjson")
    if not ok_j then ok_j, JSON = pcall(require, "json") end

    if ok_j then
        local ok_d, data = pcall(JSON.decode, body)
        if not ok_d or type(data) ~= "table" then return nil, "JSON parse error" end
        local tag = data.tag_name
        if not tag then return nil, "missing tag_name" end

        local dl_url
        for _, asset in ipairs(data.assets or {}) do
            if asset.name == ASSET_NAME then
                dl_url = asset.browser_download_url
                break
            end
        end

        local notes
        local raw = data.body or ""
        local block = raw:match("<!%-%-hiinkstream%-%->(.-)<!%-%-/hiinkstream%-%->")
        if block and block:match("%S") then
            notes = block:gsub("\r\n", "\n"):gsub("\r", "\n"):match("^%s*(.-)%s*$")
        end

        return {
            version      = tag:match("v?(.*)"),
            download_url = dl_url,
            notes        = (notes and notes ~= "") and notes or nil,
        }
    end

    -- json module unavailable — regex fallback
    logger.warn("Inkstream/Updater: json unavailable, using regex fallback")
    local tag = body:match('"tag_name"%s*:%s*"([^"]*)"')
    if not tag then return nil, "could not parse tag_name" end
    local asset_pat = '"browser_download_url"%s*:%s*"([^"]*'
        .. ASSET_NAME:gsub("%.", "%%.") .. '[^"]*)"'
    local raw_body = body:match('"body"%s*:%s*"(.-[^\\])"') or ""
    raw_body = raw_body:gsub("\\n", "\n"):gsub("\\r", ""):gsub('\\"', '"')
    local fb_notes
    local fb_block = raw_body:match("<!%-%-hiinkstream%-%->(.-)<!%-%-/hiinkstream%-%->")
    if fb_block and fb_block:match("%S") then
        fb_notes = fb_block:match("^%s*(.-)%s*$")
    end
    return {
        version      = tag:match("v?(.*)"),
        download_url = body:match(asset_pat),
        notes        = fb_notes,
    }
end

-- ── Temp zip path ─────────────────────────────────────────────────────────────

local function tmp_zip_path()
    local candidates = {
        DataStorage:getSettingsDir() .. "/inkstream_update.zip",
        "/tmp/inkstream_update.zip",
        _plugin_dir .. "/inkstream_update.zip",
    }
    for _, path in ipairs(candidates) do
        local fh = io.open(path, "wb")
        if fh then fh:close(); os.remove(path); return path end
    end
    return _plugin_dir .. "/inkstream_update.zip"
end

-- ── Install ───────────────────────────────────────────────────────────────────

-- One install at a time: a second one would download over the same temp zip
-- and unzip into the plugin folder while the first is still writing to it.
local _installing = false
local function apply_update(download_url, new_version)
    if _installing then return end
    _installing = true
    local zip = tmp_zip_path()

    local progress = InfoMessage:new{
        text    = "Downloading Inkstream v" .. new_version .. "…",
        timeout = 120,
    }
    UIManager:show(progress)

    UIManager:scheduleIn(0.3, function()
        -- Download and unzip in a subprocess: both block for many seconds (a
        -- stalled socket can block far longer), and doing that on the UI
        -- thread freezes KOReader and any book open behind it.
        local BgTask = require("core.bgtask")
        local task = BgTask.start("update-install", BgTask.child(function()
            local dl_ok, dl_err = http_download(download_url, zip)
            if not dl_ok then
                pcall(os.remove, zip)
                return { ok = false, step = "download", error = tostring(dl_err) }
            end

            logger.dbg("Inkstream/Updater: unzipping", zip, "→", _parent_dir)
            local ret = os.execute(
                string.format("unzip -o -q %q -d %q", zip, _parent_dir)
            )
            os.remove(zip)

            if ret ~= 0 and ret ~= true then
                return { ok = false, step = "extract", error = tostring(ret) }
            end
            return { ok = true }
        end), function(data)
            _installing = false
            UIManager:close(progress)

            if not data or not data.ok then
                local err = (data and data.error) or "subprocess failed"
                logger.err("Inkstream/Updater: update failed:", tostring(err))
                UIManager:show(InfoMessage:new{
                    text    = (data and data.step == "extract")
                        and "Extraction failed. Please update manually."
                        or  ("Download failed: " .. tostring(err)),
                    timeout = 5,
                })
                return
            end

            logger.info("Inkstream/Updater: update to", new_version, "installed")
            UIManager:show(ConfirmBox:new{
                text        = "Inkstream v" .. new_version
                           .. " installed.\n\nRestart KOReader to apply the update?",
                ok_text     = "Restart now",
                cancel_text = "Later",
                ok_callback = function() UIManager:restartKOReader() end,
            })
        end)

        if not task then
            _installing = false
            UIManager:close(progress)
            UIManager:show(InfoMessage:new{
                text    = "Could not start the download. Please try again.",
                timeout = 5,
            })
        end
    end)
end

-- Ask whether to install release ({ version, download_url, notes }).
local function offer_update(release, current)
    local header = "Inkstream v" .. release.version .. " is available!\n"
                .. "You have v" .. current .. "."
    local notes  = release.notes
                and ("\n\nWhat's new:\n" .. release.notes)
                or  ""
    UIManager:show(ConfirmBox:new{
        text        = header .. notes .. "\n\nDownload and install now?",
        ok_text     = "Install",
        cancel_text = "Later",
        ok_callback = function()
            apply_update(release.download_url, release.version)
        end,
    })
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- Installed extensions whose repo index lists a different version.
-- Runs in the update-check subprocess (network); returns plain metadata.
local function find_extension_updates()
    local ExtMgr = require("core.extmgr")
    ExtMgr.fetchIndex()
    local list = {}
    for _, inst in ipairs(ExtMgr.installed()) do
        if ExtMgr.hasUpdate(inst.id) then
            for _, meta in ipairs(ExtMgr.available()) do
                if meta.id == inst.id then
                    list[#list + 1] = { meta = meta, from = inst.version }
                end
            end
        end
    end
    return list
end

-- Ask whether to update the listed extensions, then install them all.
local function offer_extension_updates(list)
    local lines = {}
    for _, u in ipairs(list) do
        lines[#lines + 1] = "• " .. (u.meta.name or u.meta.id) .. ": v"
            .. tostring(u.from) .. " → v" .. tostring(u.meta.version)
    end
    UIManager:show(ConfirmBox:new{
        text        = "Source updates available:\n\n"
                   .. table.concat(lines, "\n") .. "\n\nUpdate now?",
        ok_text     = "Update all",
        cancel_text = "Later",
        ok_callback = function()
            local msg = InfoMessage:new{ text = "Updating sources…" }
            UIManager:show(msg)
            UIManager:scheduleIn(0.3, function()
                local ExtMgr, failed = require("core.extmgr"), {}
                for _, u in ipairs(list) do
                    local ok = ExtMgr.install(u.meta)
                    if not ok then failed[#failed + 1] = u.meta.name or u.meta.id end
                end
                UIManager:close(msg)
                UIManager:show(InfoMessage:new{
                    text = #failed == 0 and "Sources updated."
                        or ("Could not update: " .. table.concat(failed, ", ")),
                    timeout = 3,
                })
            end)
        end,
    })
end

-- Runs the update check in a subprocess (so a slow network cannot freeze the
-- UI): Inkstream's latest GitHub release plus the installed source extensions.
-- on_done(data) gets nil on failure, else { found, version, download_url,
-- notes, extensions } where found = the GitHub release was read.
-- Returns true when the check was started; nil, "busy" when one is already
-- running, or nil, "fork" when the subprocess could not be forked (on_done
-- then never runs).
local _checking = false
local function run_check(on_done)
    if _checking then return nil, "busy" end
    _checking = true
    local BgTask = require("core.bgtask")
    local task = BgTask.start("update-check", BgTask.child(function()
        local result = { ok = true }
        local body = http_get(API_URL)
        local release = body and parse_release(body)
        if release then
            result.found        = true
            result.version      = release.version
            result.download_url = release.download_url
            result.notes        = release.notes
        end
        local ok_ext, ext_updates = pcall(find_extension_updates)
        result.extensions = ok_ext and ext_updates or {}
        return result
    end), function(data)
        _checking = false
        on_done(data and data.ok and data or nil)
    end)
    if not task then
        -- No callback will ever run, so the flag must not stay set: it would
        -- disable every later check for the rest of the session.
        _checking = false
        return nil, "fork"
    end
    return true
end

-- Offers whatever the check found. Returns true if anything was offered.
local function offer_found(data)
    local offered = false
    if data.extensions and #data.extensions > 0 then
        offer_extension_updates(data.extensions)
        offered = true
    end
    local current = current_version()
    if data.download_url and version_gt(data.version, current) then
        offer_update(data, current)
        offered = true
    end
    return offered
end

-- Silent check, run when Inkstream opens and online (open_inkstream turns
-- Wi-Fi on first). Shows nothing unless something newer exists. Once a check
-- reaches GitHub it is not repeated this KOReader session; a failed check is
-- retried the next time Inkstream opens.
local _auto_checked = false
function Updater.autoCheck()
    if _auto_checked then return end
    if not require("ui/network/manager"):isConnected() then return end
    run_check(function(data)
        if not data then return end
        if data.found then _auto_checked = true end
        offer_found(data)
    end)
end

-- Manual check from Settings: always says what it found.
function Updater.checkNow()
    -- runWhenConnected, not runWhenOnline: the latter never runs its callback
    -- when Wi-Fi is connected but the connection is not verified online, so
    -- the button would silently do nothing.
    require("ui/network/manager"):runWhenConnected(function()
        local msg = InfoMessage:new{ text = "Checking for updates…" }
        UIManager:show(msg)
        local started, why = run_check(function(data)
            UIManager:close(msg)
            if data and data.found then _auto_checked = true end
            if data and offer_found(data) then return end
            UIManager:show(InfoMessage:new{
                text = (data and data.found)
                    and ("Inkstream " .. current_version() .. " is up to date.")
                    or  "Could not reach GitHub. Try again later.",
                timeout = 3,
            })
        end)
        if not started then
            -- Nothing will ever call back (another check owns the subprocess,
            -- or the fork failed), so "Checking…" must not stay on screen.
            UIManager:close(msg)
            UIManager:show(InfoMessage:new{
                text    = why == "busy" and "Update check already running."
                    or  "Could not start the update check.",
                timeout = 3,
            })
        end
    end)
end

return Updater
