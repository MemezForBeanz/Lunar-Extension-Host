--- Tasks: named commands the command bar can run, like a code editor's.
--
-- A task is a label and a command line. They come from two places:
--
--   * `tasks.json` in the user's config folder, for the user's own commands
--   * `HostAPI:addTask`, for an extension's
--
-- `tasks.json` is `{ "tasks": [ { "label": "Build", "command": ["make", "all"],
-- "cwd": "C:\\src" } ] }`. `command` is an argv array, never a shell string: there is
-- no quoting to get wrong, and nothing in a task's text is interpreted by a shell.
--
-- Typing `task ` in the bar lists them; running one reports through the status line and
-- Activity, and a second run of a task still going is refused rather than started twice.
--
-- @classmod core.classes.TaskRunner

local class = require("middleclass")

local TaskRunner = class("TaskRunner")

--- Read and validate a tasks.json document.
-- @tparam string text the file's contents
-- @tparam function decode a JSON decoder
-- @treturn {table,...} the valid tasks
-- @treturn {string,...} one message per task that was skipped
function TaskRunner.parse(text, decode)
	local tasks, problems = {}, {}
	local ok, doc = pcall(decode, text)
	if not ok or type(doc) ~= "table" or type(doc.tasks) ~= "table" then
		return tasks, { "tasks.json is not a { \"tasks\": [...] } document" }
	end
	for i, entry in ipairs(doc.tasks) do
		local argv = type(entry) == "table" and entry.command
		if type(entry) ~= "table" or type(entry.label) ~= "string" or entry.label == "" then
			problems[#problems + 1] = "task " .. i .. " has no label"
		elseif type(argv) ~= "table" or type(argv[1]) ~= "string" then
			problems[#problems + 1] = entry.label .. ": command must be an array of arguments"
		else
			tasks[#tasks + 1] = { label = entry.label, argv = argv, cwd = entry.cwd }
		end
	end
	return tasks, problems
end

--- @tparam table opts
-- @tparam function opts.spawn `fn({ argv, cwd }) -> process | nil, message`
-- @tparam function opts.status `fn(message)`: reports progress and results
-- @tparam function opts.after `fn(ms, fn)`: runs `fn` once, later
-- @tparam[opt] function opts.load `fn() -> { task, ... }`: the user's tasks
-- @tparam[opt] function opts.activity `fn(spec, owner) -> handle`: records a running task
--   (`HostAPI:activity`)
function TaskRunner:initialize(opts)
	self._spawn, self._status, self._after = opts.spawn, opts.status, opts.after
	self._load = opts.load
	self._activity = opts.activity
	self._extension = {}   -- tasks added by extensions
	self._running = {}     -- label -> true
end

--- Add a task on behalf of an extension.
-- @tparam table spec `label`, `argv`, optional `cwd`
-- @param[opt] owner who to remove it with
-- @treturn table|nil the stored task
function TaskRunner:add(spec, owner)
	if type(spec) ~= "table" or type(spec.label) ~= "string" or type(spec.argv) ~= "table" then
		return nil
	end
	local task = { label = spec.label, argv = spec.argv, cwd = spec.cwd, owner = owner }
	self._extension[#self._extension + 1] = task
	return task
end

--- Remove what an extension added.
function TaskRunner:removeOwned(owner)
	for i = #self._extension, 1, -1 do
		if self._extension[i].owner == owner then table.remove(self._extension, i) end
	end
end

--- Every task, the user's first. tasks.json is read each time, so an edit shows at once.
-- @treturn {table,...}
function TaskRunner:list()
	local out = {}
	if self._load then
		local ok, tasks = pcall(self._load)
		if ok and type(tasks) == "table" then
			for _, task in ipairs(tasks) do out[#out + 1] = task end
		end
	end
	for _, task in ipairs(self._extension) do out[#out + 1] = task end
	return out
end

--- Is this task running?
function TaskRunner:isRunning(label)
	return self._running[label] == true
end

--- Start a task.
-- @tparam table task
-- @treturn boolean started
-- @treturn[opt] string why not
function TaskRunner:run(task)
	local label = task.label
	if self._running[label] then
		return false, label .. " is already running"
	end
	local proc, err = self._spawn({ argv = task.argv, cwd = task.cwd })
	if not proc then
		return false, label .. ": " .. tostring(err)
	end
	self._running[label] = true
	self._status(label .. ": running")

	-- A task is the user's own command, so ending it is theirs to ask for. The kill
	-- takes the whole process tree, and the tick below finds it gone.
	local cancelled = false
	local activity = self._activity and self._activity({
		title = label,
		tool = "Tasks",
		cancel = function()
			cancelled = true
			proc:kill()
		end,
	}, task.owner or false)

	local runner = self
	local function tick()
		-- The pipes have to be drained or a chatty task blocks on a full one.
		pcall(proc.read, proc, "stdout", 65536)
		pcall(proc.read, proc, "stderr", 65536)
		local ok, code = pcall(proc.poll, proc)
		if ok and code == nil then
			runner._after(200, tick)
			return
		end
		runner._running[label] = nil
		pcall(proc.close, proc)
		if cancelled then
			runner._status(label .. ": cancelled")
			if activity then activity:finish("cancelled") end
		elseif ok and code == 0 then
			runner._status(label .. ": finished")
			if activity then activity:finish(true) end
		else
			local why = "failed (exit " .. tostring(code) .. ")"
			runner._status(label .. ": " .. why)
			if activity then activity:finish(false, "Exited with code " .. tostring(code)) end
		end
	end
	self._after(200, tick)
	return true
end

return TaskRunner
