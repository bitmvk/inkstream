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

-- Read everything the pipe holds right now, without blocking. Never use
-- ffiutil.readAllFromFD here: it blocks until every copy of the write end is
-- closed, and a process the child spawned (e.g. the updater's unzip shell)
-- inherits that end and keeps the UI process blocked until it exits.
local function read_available(fd)
    local chunks = {}
    while true do
        local n = ffiutil.getNonBlockingReadSize(fd)
        if not n or n <= 0 then break end
        local buf = ffi.new("char[?]", n)
        local got = ffi.C.read(fd, buf, n)
        if not got or got <= 0 then break end
        table.insert(chunks, ffi.string(buf, got))
    end
    return table.concat(chunks)
end

-- Cancel a task: never deliver its result, close our read end, kill the
-- child, and keep collecting it until waitpid reaps it (a killed child that
-- is never collected stays a zombie for the life of the process).
local function cancel(task)
    if task.cancelled then return end
    task.cancelled = true
    task.done_cb = nil
    pcall(ffiutil.terminateSubProcess, task.pid)
    if task.fd then
        ffi.C.close(task.fd)
        task.fd = nil
    end
    local function reap()
        if ffiutil.isSubProcessDone(task.pid) then return end
        if UIManager then UIManager:scheduleIn(1, reap) end
    end
    reap()
end

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
        -- Cancelled by BgTask.terminate(): cancel() already killed the child
        -- and closed the pipe, so this task must not touch either again.
        if task.cancelled then return end

        if poll_fn and not poll_fn() then
            -- Aborted (e.g. the document closed): no result is wanted.
            cancel(task)
            return
        end

        -- Keep the pipe drained so a large JSON result cannot deadlock the child.
        local chunk = read_available(task.fd)
        if chunk ~= "" then table.insert(task.buf, chunk) end

        if ffiutil.isSubProcessDone(task.pid) then
            -- Child exited: everything it wrote is already in the pipe (a
            -- process it spawned may still hold the write end, hence the
            -- non-blocking drain rather than readAllFromFD's read-to-EOF).
            local raw = table.concat(task.buf) .. read_available(task.fd)
            ffi.C.close(task.fd)
            task.fd = nil
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

-- Cancel a running task: its done callback is dropped, so a result can never
-- be delivered after the task was abandoned (e.g. when the document closed).
function BgTask.terminate(task)
    if task then cancel(task) end
end

return BgTask
