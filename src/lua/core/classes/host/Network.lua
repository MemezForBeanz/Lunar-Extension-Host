--- Internal network service for core.classes.HostAPI.
-- @module core.classes.host.Network
-- @local

local M = {}
local ProcessJob = require("core.lib.ProcessJob")

function M.runAsync(self, fn, cb)
    local async = self:async()
    local scheduled = async.run(fn, cb)
    if scheduled then
        self:_ensureAsyncPump()
    end
    return scheduled
end

function M.async(self)
    if not self._async then
        self._async = require("core.lib.async")
    end
    return self._async
end

function M.http(self, request, callback, owner)
    local request_handle = { cancelled = false }
    function request_handle.cancel() request_handle.cancelled = true end
    local requests = self:_record(owner).requests
    requests[request_handle] = true

    local host = self
    local function finish(res, err)
        requests[request_handle] = nil
        if request_handle.cancelled or type(callback) ~= "function" then return end
        local ok, cb_err = xpcall(function() callback(res, err) end, debug.traceback)
        if not ok and host._status_fn then
            pcall(host._status_fn, "HTTP callback error: " .. tostring(cb_err))
        end
    end
    self:runAsync(function()
        return require("core.lib.http").request(request)
    end, function(ok, res, err)
        if not ok then return finish(nil, tostring(res)) end
        finish(res, err)
    end)
    return request_handle
end

function M.startJob(self, opts, owner)
    assert(type(opts) == "table", "startJob: opts table required")
    local jobs = self:_record(owner).jobs
    local entry = { alive = true }
    local function guard(fn)
        if type(fn) ~= "function" then return nil end
        return function(...) if entry.alive then return fn(...) end end
    end
    local wrapped = setmetatable({
        on_event = guard(opts.on_event),
        on_stderr = guard(opts.on_stderr),
        on_protocol_error = guard(opts.on_protocol_error),
        on_exit = function(res)
            jobs[entry] = nil
            if entry.alive and type(opts.on_exit) == "function" then return opts.on_exit(res) end
        end,
    }, { __index = opts })
    local job, err = ProcessJob.start(wrapped)
    if not job then return nil, err end
    entry.job = job
    jobs[entry] = true
    if self.iup then job:attach_timer(self.iup) end
    return job
end

function M.spawn(self, opts, owner)
    local ok, process = pcall(require, "process")
    if not ok then return nil, "the process module is unavailable" end
    local proc, err = process.spawn(opts)
    if not proc then return nil, err end
    self:_record(owner).processes[proc] = true
    return proc
end


-- Wrap the legacy native `subprocess` module so the handles `start` and
-- `start_argv` return can be recorded against an owner (an optional trailing
-- table argument). Everything else passes straight through; `start_detached` is
-- deliberately never owned (it exists to outlive the host).
function M._ownedSubprocess(self, module)
    local host = self
    local proxy = setmetatable({}, { __index = module })
    local function owned(fn)
        return function(...)
            local args = { ... }
            local n = select("#", ...)
            local owner
            if n > 0 and type(args[n]) == "table" then
                owner = args[n]
                args[n] = nil
                n = n - 1
            end
            local proc, err = fn(unpack(args, 1, n))
            if proc and owner then
                local rec = host:_record(owner)
                rec.subprocesses[proc] = true
                host._subprocess_owner[proc] = rec
            end
            return proc, err
        end
    end
    proxy.start = owned(module.start)
    proxy.start_argv = owned(module.start_argv)
    function proxy.destroy(proc, ...)
        local rec = host._subprocess_owner[proc]
        if rec then rec.subprocesses[proc] = nil end
        host._subprocess_owner[proc] = nil
        return module.destroy(proc, ...)
    end
    proxy.raw = module
    return proxy
end

function M.networkLogin(self, server, user, password, remember, check_path)
    if type(server) ~= "string" or type(user) ~= "string" or type(password) ~= "string"
        or server == "" or user == "" then
        return nil, "server, user name and password are required"
    end
    return self:_secretStore().network_login(server, user, password, remember ~= false, check_path)
end

function M.networkLogout(self, server)
    return self:_secretStore().network_logout(server)
end


-- Start (or restart) the single shared pump timer. It stops itself as soon as
-- every task has drained, so an idle app pays nothing.
function M._ensureAsyncPump(self)
    local iup = self.iup
    local async = self:async()
    if not async.available then return end
    if not self._async_timer then
        local timer = iup.timer({ TIME = 15, RUN = "NO" })
        local host = self
        function timer:action_cb()
            -- Re-entrancy guard. A task may open a modal (iup.Alarm/Message),
            -- which runs a NESTED message loop -- so this timer can fire again
            -- while we are still inside copas.step. copas is not re-entrant, and
            -- stepping it from within itself corrupts its task list.
            if host._async_in_pump then return iup.DEFAULT end
            host._async_in_pump = true
            local ok, more = pcall(async.pump)
            host._async_in_pump = false
            if not ok or not more then
                pcall(iup.SetAttribute, timer, "RUN", "NO")
                host._async_pumping = false
            end
            return iup.DEFAULT
        end
        self._async_timer = timer
    end
    if not self._async_pumping then
        self._async_pumping = true
        pcall(iup.SetAttribute, self._async_timer, "RUN", "YES")
    end
end

return M
