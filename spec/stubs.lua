-- spec/stubs.lua — KOReader module stubs shared by the spec build checks.
-- Requires nothing but plain Lua + the shell (curl, unzip, stat). Call
-- setup(tmp_root, home_dir) BEFORE requiring any inkstream module.
--
-- Provided: logger, lfs (incl. dir/rmdir), datastorage, G_reader_settings,
-- ffi + ffi/util (no-ops), ffi/sha2, a minimal JSON codec, the HTTP stack
-- via curl (socket.http/ssl.https/ltn12), luasettings, docsettings
-- (sidecar JSON files), and recording readhistory/readcollection stubs with
-- the same updateItem/removeItems/fileDeleted API the real modules expose.

local M = {}

M.n_pass, M.n_fail = 0, 0

function M.check(name, got, want)
    if got == want then
        M.n_pass = M.n_pass + 1
        print("PASS  " .. name)
    else
        M.n_fail = M.n_fail + 1
        print("FAIL  " .. name .. "  (got " .. tostring(got)
            .. ", want " .. tostring(want) .. ")")
    end
end

function M.check_true(name, cond)
    M.check(name, cond == true, true)
end

function M.summarize()
    print(("---- %d passed, %d failed ----"):format(M.n_pass, M.n_fail))
    if M.n_fail > 0 then os.exit(1) end
    os.exit(0)
end

function M.sh_quote(s)
    return '"' .. tostring(s):gsub('"', '\\"') .. '"'
end

-- Note: in sandboxed shells io.popen's exit status can be unreliable, so
-- callers must inspect command OUTPUT (or resulting files), not just the
-- status. That is what the helpers below do.
function M.sh(cmd)
    local f = io.popen(cmd .. " 2>&1")
    local out = f:read("*a")
    f:close()
    return out
end

function M.is_dir(p)
    p = p:gsub("/+$", "")
    if p == "" then return true end
    local f = io.popen("if [ -d " .. M.sh_quote(p) .. " ]; then echo YES; fi")
    local out = f:read("*a")
    f:close()
    return out:match("YES") ~= nil
end

function M.setup(tmp_root, home_dir)
    package.loaded["logger"] = {
        dbg  = function() end,
        info = function() end,
        warn = function(...) print("WARN", ...) end,
        err  = function(...) print("ERROR", ...) end,
    }

    -- ── lfs ────────────────────────────────────────────────────────────────────

    local lfs_stub = {}
    -- Non-recursive, like the real lfs.mkdir (a recursive stub hid a bug).
    function lfs_stub.mkdir(p) M.sh("mkdir " .. M.sh_quote(p) .. " 2>/dev/null") end
    function lfs_stub.rmdir(p) M.sh("rmdir " .. M.sh_quote(p) .. " 2>/dev/null") end
    function lfs_stub.dir(path)
        -- Returns the entries of a directory as the standard lfs.dir iterator.
        local out = M.sh("ls -a " .. M.sh_quote(path))
        local entries = {}
        for entry in out:gmatch("%S+") do table.insert(entries, entry) end
        local i = 0
        return function()
            i = i + 1
            return entries[i]
        end
    end
    function lfs_stub.attributes(path, key)
        if not path then return nil end
        path = path:gsub("/+$", "")
        if path == "" then path = "/" end
        if key == "mode" then
            if M.is_dir(path) then return "directory" end
            local f = io.open(path, "rb")
            if f then f:close(); return "file" end
            return nil
        elseif key == "size" then
            local f = io.open(path, "rb")
            if f then local sz = f:seek("end"); f:close(); return sz end
            return nil
        elseif key == "modification" then
            local f = io.popen("stat -c %Y " .. M.sh_quote(path) .. " 2>/dev/null")
            local out = f:read("*a")
            f:close()
            return tonumber(out)
        end
        if M.is_dir(path) then return {} end
        local f = io.open(path, "rb")
        if f then f:close(); return {} end
        return nil
    end
    function lfs_stub.touch(path, atime, mtime)
        M.sh("touch -a -d @" .. tostring(atime) .. " " .. M.sh_quote(path)
            .. " && touch -m -d @" .. tostring(mtime) .. " " .. M.sh_quote(path))
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

    -- ffi + ffi/util no-ops (core/bgtask.lua loads them; the specs never
    -- start a real subprocess — downloader.run_batch_inline is synchronous).
    package.loaded["ffi"] = {
        new    = function() return {} end,
        C      = { read = function() return 0 end },
        string = function() return "" end,
    }
    package.loaded["ffi/util"] = {
        runInSubProcess      = function() return nil, nil end,
        getNonBlockingReadSize = function() return 0 end,
        isSubProcessDone     = function() return true end,
        readAllFromFD        = function() return "" end,
        terminateSubProcess  = function() end,
        writeToFD            = function() end,
    }

    -- ── Minimal dependency-free JSON codec ─────────────────────────────────────

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

    -- ── HTTP via curl ──────────────────────────────────────────────────────────

    local function curl(url)
        local f = io.popen("curl -sS -L --max-time 45 "
            .. '-A "Mozilla/5.0 (Linux; Android 9; KOReader)" '
            .. M.sh_quote(url) .. " 2>/dev/null")
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

    -- ── LuaSettings ────────────────────────────────────────────────────────────

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

    -- ── DocSettings (sidecar JSON files) ───────────────────────────────────────

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
                M.sh("mkdir -p " .. M.sh_quote(path:match("^(.*)/[^/]+$") or "."))
                local f2 = io.open(path, "w")
                if f2 then f2:write(json.encode(data)); f2:close() end
            end,
        }
    end
    function docsettings_stub.purge(doc_path)
        -- Instance-style purge used via DocSettings:open(path):purge(): the
        -- stub's open() returns a plain table, so also accept direct calls.
        local path = sidecar_file(doc_path)
        local dir  = path:match("^(.*)/[^/]+$")
        if dir then M.sh("rm -rf " .. M.sh_quote(dir)) end
    end
    function docsettings_stub.updateLocation(doc_path, new_doc_path)
        local src = sidecar_file(doc_path)
        local dst = sidecar_file(new_doc_path)
        local dir = dst:match("^(.*)/[^/]+$")
        if dir then M.sh("mkdir -p " .. M.sh_quote(dir)) end
        M.sh("cp -f " .. M.sh_quote(src) .. " " .. M.sh_quote(dst) .. " 2>/dev/null")
        local src_dir = src:match("^(.*)/[^/]+$")
        if src_dir then M.sh("rm -rf " .. M.sh_quote(src_dir)) end
    end
    package.loaded["docsettings"] = docsettings_stub

    -- ── Recording readhistory / readcollection stubs ───────────────────────────
    -- Same updateItem / fileDeleted / removeItems API the real modules expose;
    -- every call is recorded in M.history_calls / M.collection_calls.

    M.history_calls    = {}
    M.collection_calls = {}
    package.loaded["readhistory"] = {
        updateItem  = function(_, old, new)
            table.insert(M.history_calls, { "update", old, new }) end,
        fileDeleted = function(_, path)
            table.insert(M.history_calls, { "delete", path }) end,
    }
    package.loaded["readcollection"] = {
        updateItem  = function(_, old, new)
            table.insert(M.collection_calls, { "update", old, new }) end,
        removeItems = function(_, files)
            for path in pairs(files or {}) do
                table.insert(M.collection_calls, { "delete", path })
            end
        end,
    }

    -- Give open()'d DocSettings tables a purge method (the real DocSettings
    -- instance has one; livebook calls DocSettings:open(path):purge()).
    local orig_open = docsettings_stub.open
    function docsettings_stub:open(doc_path)
        local ds = orig_open(self, doc_path)
        ds.purge = function()
            docsettings_stub.purge(doc_path)
        end
        return ds
    end
end

return M
