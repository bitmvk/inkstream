-- Thin HTTP/HTTPS client for Inkstream extensions.
-- Returns body string on success, nil+code on failure.
local https   = require("ssl.https")
local http    = require("socket.http")
local ltn12   = require("ltn12")
local ok_json, JSON = pcall(require, "rapidjson")
if not ok_json then JSON = require("json") end
-- luasocket ignores a `timeout` field on the request table.  KOReader's
-- socketutil applies a real per-poll timeout and (via its sinks) a total cap;
-- fall back to plain luasocket in stub environments where it is unavailable.
local ok_su, socketutil = pcall(require, "socketutil")

local UA = "Mozilla/5.0 (Linux; Android 9; KOReader) AppleWebKit/537.36"

local HttpClient = {}

local function do_request(url, headers, timeout)
    local t = timeout or 30
    if ok_su then socketutil:set_timeout(t, t) end
    local sink = {}
    local sink_fn = ok_su and socketutil.table_sink(sink) or ltn12.sink.table(sink)
    local req_h = {
        ["User-Agent"]      = UA,
        ["Accept"]          = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ["Accept-Language"] = "en-US,en;q=0.5",
    }
    if headers then
        for k, v in pairs(headers) do req_h[k] = v end
    end
    local requester = url:match("^https") and https or http
    local ok, code, resp_h = requester.request {
        url     = url,
        sink    = sink_fn,
        headers = req_h,
    }
    if ok_su then socketutil:reset_timeout() end
    if not ok then return nil, tostring(code) end
    if code ~= 200 then return nil, code end
    return table.concat(sink), code, resp_h
end

function HttpClient.get(url, headers, timeout)
    return do_request(url, headers, timeout)
end

function HttpClient.getJson(url, headers)
    local body, code = do_request(url, headers)
    if not body then return nil, code end
    local ok2, data = pcall(JSON.decode, body)
    if not ok2 then return nil, "json_parse_error" end
    return data
end

-- Download url to a local file path; returns true/false, code
function HttpClient.download(url, dest_path, timeout)
    -- Download beside the destination and rename on success: an interrupted
    -- download must not truncate the file that is already there (e.g. a
    -- working extension being updated).
    local tmp_path = dest_path .. ".part"
    local f = io.open(tmp_path, "wb")
    if not f then return false, "open_error" end
    local t = timeout or 60
    if ok_su then socketutil:set_timeout(t, t) end
    local sink_fn = ok_su and socketutil.file_sink(f) or ltn12.sink.file(f)
    local requester = url:match("^https") and https or http
    local ok, code = requester.request {
        url     = url,
        sink    = sink_fn,
    }
    if ok_su then socketutil:reset_timeout() end
    -- ltn12.sink.file (and socketutil's wrapper) closes f automatically;
    -- calling f:close() again crashes.
    if not (ok and code == 200) then
        os.remove(tmp_path)
        return false, code
    end
    if not os.rename(tmp_path, dest_path) then
        os.remove(tmp_path)
        return false, "rename_error"
    end
    return true, code
end

return HttpClient
