-- Shared background-subprocess plumbing: run a child function in a forked
-- subprocess, keep its output pipe drained while it runs, and deliver the
-- decoded JSON result. Used by the refill code (main.lua) and by the
-- full-mode downloader (core/downloader.lua).
local logger  = require("logger")
local ffiutil = require("ffi/util")
local ffi     = require("ffi")
local ok_json, JSON = pcall(require, "rapidjson")
if not ok_json then JSON = require("json") end
-- UIManager drives the polling; absent in stub/spec environments.
local ok_ui, UIManager = pcall(require, "ui/uimanager")

-- Plugin root for the child's package.path (this file lives in <root>/core/).
local plugin_dir = (debug.getinfo(1, "S").source or "")
    :match("^@(.*)/core/bgtask%.lua$") or "."

local BgTask = {}

-- Child side: prepend the plugin dir to package.path and protect the body,
-- writing a JSON result to the pipe.
function BgTask.child(body)
    return function(pid, wfd)
        package.path = plugin_dir .. "/?.lua;"
            .. plugin_dir .. "/?/init.lua;" .. package.path
        local ok, result = pcall(body)
        local json = JSON.encode(ok and result or { ok = false, error = tostring(result) })
        local pos = 1
        while pos <= #json do
            ffiutil.writeToFD(wfd, json:sub(pos, pos + 32767))
            pos = pos + 32768
        end
    end
end

-- Run child_fn (already wrapped in BgTask.child) in a subprocess.
-- poll_fn() is consulted every second and must return false to abort (e.g.
-- the document was closed meanwhile); done_cb(decoded_json_or_nil) runs when
-- the child exits. Returns the task table, or nil when the fork fails.
function BgTask.start(kind, child_fn, done_cb, poll_fn)
    local ok, pid, fd = pcall(ffiutil.runInSubProcess, child_fn, true)
    if not ok or not pid then
        logger.warn("Inkstream/BgTask: runInSubProcess failed:", tostring(pid))
        return nil
    end
    logger.dbg("Inkstream/BgTask: started", kind, "pid=", pid)
    local task = { kind = kind, pid = pid, fd = fd, buf = {}, done_cb = done_cb }

    local function poll()
        if poll_fn and not poll_fn() then
            -- Aborted: kill the child and drop the callback.
            task.done_cb = nil
            pcall(ffiutil.terminateSubProcess, task.pid)
            return
        end

        -- Keep the pipe drained so a large JSON result cannot deadlock the child.
        local n = ffiutil.getNonBlockingReadSize(task.fd)
        if n and n > 0 then
            local buf = ffi.new("char[?]", n)
            local got = ffi.C.read(task.fd, buf, n)
            if got and got > 0 then
                table.insert(task.buf, ffi.string(buf, got))
            end
        end

        if ffiutil.isSubProcessDone(task.pid) then
            -- Child exited: its write end is closed, so this drains the rest.
            local rest = ffiutil.readAllFromFD(task.fd)
            local raw = table.concat(task.buf) .. rest
            local data
            if raw ~= "" then
                local ok_d, decoded = pcall(JSON.decode, raw)
                data = ok_d and decoded or nil
            end
            local cb = task.done_cb
            task.done_cb = nil
            if cb then cb(data) end
        elseif UIManager then
            UIManager:scheduleIn(1, poll)
        end
    end

    if UIManager then UIManager:scheduleIn(1, poll) end
    return task
end

-- Best-effort termination of a running task.
function BgTask.terminate(task)
    if task and task.pid then
        pcall(ffiutil.terminateSubProcess, task.pid)
    end
end

return BgTask
