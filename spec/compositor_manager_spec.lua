local Compositor = require("core.lib.Compositor")

local function fake()
	local backend = { calls = {}, queue = {} }
	function backend:geometry() return { w = 10, h = 10, scale = 1.5 } end
	function backend:present(scene, regions, generation)
		self.calls[#self.calls + 1] = { "present", scene, regions, generation }
	end
	function backend:hide() self.calls[#self.calls + 1] = { "hide" } end
	function backend:events()
		local events = self.queue
		self.queue = {}
		return events
	end
	return backend
end

local function group(color, z)
	return { z = z, sprites = { { kind = "fill", x = 0, y = 0, w = 2, h = 2,
		color = color, alpha = 1 } }, regions = {} }
end

describe("Compositor manager", function()
	it("retains independent groups and coalesces commits", function()
		local backend = fake()
		local comp = Compositor.new(backend)
		comp:set("tab", group(2, Compositor.Z_TAB))
		comp:set("toast", group(3, Compositor.Z_TOASTS))
		comp:set("tab", group(4, Compositor.Z_TAB))
		assert.is_true(comp:commit())
		assert.equals(1, #backend.calls)
		assert.equals(4, backend.calls[1][2][1].color)
		assert.equals(3, backend.calls[1][2][2].color)
		assert.is_false(comp:commit())
		comp:remove("tab")
		comp:commit()
		assert.equals(3, backend.calls[2][2][1].color)
		assert.equals(1, #backend.calls[2][2])
		comp:remove("toast")
		comp:commit()
		assert.equals("hide", backend.calls[3][1])
		assert.same({ w = 10, h = 10, scale = 1.5 }, comp:geometry())
	end)

	it("delivers actions while their region is live, across unrelated frames", function()
		local backend = fake()
		local comp = Compositor.new(backend)
		local actions = {}
		comp:on("action", function(e) actions[#actions + 1] = e.id end)
		local toast = group(1, Compositor.Z_TOASTS)
		toast.regions = { { x = 0, y = 0, w = 4, h = 4, mode = "action", id = "close:1" } }
		comp:set("toast", toast)
		comp:commit()
		-- A scrim fading underneath advances the generation every frame.
		for i = 1, 5 do
			comp:set("scrim", group(i, Compositor.Z_SCRIM))
			comp:commit()
		end
		backend.queue = { { type = "action", id = "close:1", generation = 1 } }
		comp:poll()
		assert.same({ "close:1" }, actions)
	end)

	it("drops actions for regions that are gone", function()
		local backend = fake()
		local comp = Compositor.new(backend)
		local actions = {}
		comp:on("action", function(e) actions[#actions + 1] = e.id end)
		local toast = group(1, Compositor.Z_TOASTS)
		toast.regions = { { x = 0, y = 0, w = 4, h = 4, mode = "action", id = "close:1" } }
		comp:set("toast", toast)
		comp:commit()
		comp:remove("toast")
		comp:commit()
		backend.queue = { { type = "action", id = "close:1", generation = 1 } }
		comp:poll()
		assert.same({}, actions)
	end)

	it("presents a fresh frame after a resize or DPI change with no group changes", function()
		local backend = fake()
		local comp = Compositor.new(backend)
		local resize = 0
		comp:on("resize", function() resize = resize + 1 end)
		comp:set("one", group(1, 10))
		comp:commit()
		assert.is_false(comp:commit())
		backend.queue = { { type = "resize" } }
		assert.is_true(comp:commit())
		assert.equals(1, resize)
		backend.queue = { { type = "dpi" } }
		assert.is_true(comp:commit())
		assert.equals(3, #backend.calls)
	end)

	describe("opacity", function()
		local function fading()
			local backend = fake()
			backend.fades = {}
			function backend:fade(o) self.fades[#self.fades + 1] = o end
			function backend:present(scene, regions, opacity)
				self.calls[#self.calls + 1] = { "present", scene, regions, opacity }
			end
			return backend
		end

		it("fades a group on screen alone as a layer, without re-rendering", function()
			local backend = fading()
			local comp = Compositor.new(backend)
			comp:set("scrim", { z = Compositor.Z_SCRIM, opacity = 0, sprites = group(0).sprites, regions = {} })
			comp:commit()
			assert.equals(0, backend.calls[1][4])
			assert.equals(1, backend.calls[1][2][1].alpha)     -- full strength in the frame
			local gen = comp.generation
			comp:setOpacity("scrim", 0.25)
			assert.is_true(comp:commit())
			comp:setOpacity("scrim", 0.25)
			assert.is_false(comp:commit())                     -- unchanged
			assert.same({ 0.25 }, backend.fades)
			assert.equals(1, #backend.calls)
			assert.equals(gen, comp.generation)
		end)

		it("bakes opacity into the frame when groups share the screen", function()
			local backend = fading()
			local comp = Compositor.new(backend)
			comp:set("scrim", { z = Compositor.Z_SCRIM, opacity = 0.5, sprites = group(0).sprites, regions = {} })
			comp:set("toast", group(3, Compositor.Z_TOASTS))
			comp:commit()
			local frame = backend.calls[1]
			assert.equals(1, frame[4])
			assert.equals(0.5, frame[2][1].alpha)
			assert.equals(1, frame[2][2].alpha)
			comp:setOpacity("scrim", 0.25)
			comp:commit()
			assert.same({}, backend.fades)
			assert.equals(0.25, backend.calls[2][2][1].alpha)
			-- The caller's sprite tables are never modified.
			assert.equals(1, comp.groups.scrim.sprites[1].alpha)
		end)

		it("keeps a group's opacity across a content update, and re-renders after a toast leaves", function()
			local backend = fading()
			local comp = Compositor.new(backend)
			comp:set("scrim", { z = Compositor.Z_SCRIM, opacity = 0.5, sprites = group(0).sprites, regions = {} })
			comp:set("toast", group(3, Compositor.Z_TOASTS))
			comp:commit()
			comp:remove("toast")
			comp:commit()
			assert.equals(0.5, backend.calls[2][4])
			comp:set("scrim", { z = Compositor.Z_SCRIM, sprites = group(1).sprites, regions = {} })
			comp:commit()
			assert.equals(0.5, backend.calls[3][4])
		end)

		it("without a backend fade, always bakes", function()
			local backend = fake()
			local comp = Compositor.new(backend)
			comp:set("scrim", { z = Compositor.Z_SCRIM, opacity = 0.5, sprites = group(0).sprites, regions = {} })
			comp:commit()
			comp:setOpacity("scrim", 0.75)
			assert.is_true(comp:commit())
			assert.equals(0.75, backend.calls[2][2][1].alpha)
		end)
	end)

	it("forDialog fails closed where the platform has no backend, and caches per dialog", function()
		local none = { supported = function() return false, "no backend" end }
		local comp, why = Compositor.forDialog({}, {}, none)
		assert.is_nil(comp)
		assert.equals("no backend", why)
		local made = 0
		local native = { supported = function() return true end,
			overlay = function() made = made + 1; return fake() end }
		local dlg = {}
		local a = Compositor.forDialog({}, dlg, native)
		local b = Compositor.forDialog({}, dlg, native)
		assert.equals(a, b)
		assert.equals(1, made)
	end)

	describe("review fixes", function()
		it("accepts a native userdata backend", function()
			local calls = {}
			local ud = newproxy(true)
			local methods = {
				geometry = function() return { w = 4, h = 4, scale = 1 } end,
				present = function(_, scene) calls[#calls + 1] = scene; return true end,
				hide = function() end,
			}
			getmetatable(ud).__index = function(_, k)
				if methods[k] then return methods[k] end
				error("no such method " .. tostring(k))   -- like a strict native __index
			end
			local comp = Compositor.new(ud)
			comp:set("a", group(1, 10))
			assert.is_true(comp:commit())
			assert.equals(1, #calls)
			assert.is_nil(comp:rect({}))                         -- no rect method: nil, no error
		end)

		it("keeps the work pending when presenting fails", function()
			local backend = fake()
			local fail = true
			function backend:present(scene, regions)
				self.calls[#self.calls + 1] = { "present", scene, regions }
				if fail then return false, "UpdateLayeredWindow failed" end
				return true
			end
			local comp = Compositor.new(backend)
			local toast = group(1, Compositor.Z_TOASTS)
			toast.regions = { { x = 0, y = 0, w = 2, h = 2, mode = "action", id = "x" } }
			comp:set("toast", toast)
			assert.is_false(comp:commit())
			assert.equals(0, comp.generation)
			assert.equals("UpdateLayeredWindow failed", comp.last_error)
			assert.is_nil(comp.live_actions.x)
			fail = false
			assert.is_true(comp:commit())                        -- retried, not lost
			assert.equals(1, comp.generation)
			assert.equals(1, comp.live_actions.x)
		end)

		it("does nothing (and keeps the work) when the dialog has no geometry", function()
			local backend = fake()
			function backend:geometry() return nil end
			local comp = Compositor.new(backend)
			comp:set("a", group(1, 10))
			assert.is_false(comp:commit())
			assert.equals(0, #backend.calls)
			assert.is_true(comp.dirty)
		end)

		it("drops a click on an old region when a new one reuses its id", function()
			local backend = fake()
			local comp = Compositor.new(backend)
			local actions = {}
			comp:on("action", function(e) actions[#actions + 1] = e.generation end)
			local function toast()
				local t = group(1, Compositor.Z_TOASTS)
				t.regions = { { x = 0, y = 0, w = 4, h = 4, mode = "action", id = "close:1" } }
				return t
			end
			comp:set("toast", toast()); comp:commit()           -- gen 1
			comp:remove("toast"); comp:commit()                 -- gen 2
			comp:set("toast", toast()); comp:commit()           -- gen 3: a new toast, same id
			backend.queue = { { type = "action", id = "close:1", generation = 1 },
				{ type = "action", id = "close:1", generation = 3 } }
			comp:poll()
			assert.same({ 3 }, actions)
		end)

		it("renders again when the backend can't fade a stale frame", function()
			local backend = fake()
			backend.fade = function() return false end
			local comp = Compositor.new(backend)
			comp:set("scrim", { z = Compositor.Z_SCRIM, opacity = 0.5, sprites = group(0).sprites, regions = {} })
			comp:commit()
			comp:setOpacity("scrim", 0.25)
			assert.is_true(comp:commit())
			assert.equals(2, #backend.calls)
			assert.equals(0.25, backend.calls[2][4])
		end)
	end)

	it("schedule() presents one frame per director tick for every effect on the dialog", function()
		local MotionDirector = require("core.classes.MotionDirector")
		local iup = { DEFAULT = -2 }
		function iup.timer(t) return t end
		function iup.SetAttribute() end
		local clock = { t = 0 }
		local dir = MotionDirector:new({ iup = iup, clock = function() return clock.t end })
		local backend = fake()
		local comp = Compositor.new(backend)
		for _, name in ipairs({ "a", "b" }) do
			dir:animate({ role = "scrim_in", target = name, from = 0, to = 1, on_frame = function(v)
				comp:set(name, group(math.floor(v * 100), 10))
				comp:schedule(dir)
			end })
		end
		clock.t = 0.1
		dir:tick()
		assert.equals(1, #backend.calls)                     -- two effects, one present
		assert.equals(2, #backend.calls[1][2])
		comp:set("a", group(7, 10))
		comp:schedule(nil)                                   -- no director: right away
		assert.equals(2, #backend.calls)
	end)

	describe("follow-up fixes", function()
		local function toast_group()
			local t = group(1, Compositor.Z_TOASTS)
			t.regions = { { x = 0, y = 0, w = 4, h = 4, mode = "action", id = "close:1" } }
			return t
		end

		it("a group removed and set again in one commit is a new owner of its ids", function()
			local backend = fake()
			local comp = Compositor.new(backend)
			local got = {}
			comp:on("action", function(e) got[#got + 1] = e.generation end)
			comp:set("toast", toast_group()); comp:commit()            -- gen 1
			comp:remove("toast"); comp:set("toast", toast_group()); comp:commit()   -- gen 2
			backend.queue = { { type = "action", id = "close:1", generation = 1 },
				{ type = "action", id = "close:1", generation = 2 } }
			comp:poll()
			assert.same({ 2 }, got)
			-- Re-setting without a remove (an animating toast) keeps the id live.
			comp:set("toast", toast_group()); comp:commit()            -- gen 3
			backend.queue = { { type = "action", id = "close:1", generation = 2 } }
			comp:poll()
			assert.same({ 2, 2 }, got)
		end)

		it("keeps the layer up for input-only content", function()
			local backend = fake()
			local comp = Compositor.new(backend)
			comp:set("blocker", { z = 50, sprites = {}, regions = { { x = 0, y = 0, w = 5, h = 5, mode = "block" } } })
			comp:commit()
			assert.equals("present", backend.calls[1][1])
			comp:set("blocker", { z = 50, sprites = {}, regions = { { x = 0, y = 0, w = 5, h = 5, mode = "pass" } } })
			comp:commit()
			assert.equals("hide", backend.calls[2][1])
		end)

		it("destroys its pump timer, stops it when the dialog is gone, and re-stacks while idle", function()
			local made, destroyed = {}, {}
			local iup = { DEFAULT = -2 }
			function iup.timer(t) made[#made + 1] = t; return t end
			function iup.Destroy(t) destroyed[#destroyed + 1] = t end
			local backend = fake()
			local raised = 0
			function backend:raise() raised = raised + 1 end
			local comp = Compositor.new(backend)
			comp.iup = iup
			for _ = 1, 3 do
				comp:set("scrim", group(1, Compositor.Z_SCRIM)); comp:commit()
				comp:remove("scrim"); comp:commit()
			end
			assert.equals(3, #made)
			assert.equals(3, #destroyed)
			comp:set("scrim", group(1, Compositor.Z_SCRIM)); comp:commit()
			made[4].action_cb()                                       -- idle tick: nothing changed
			assert.equals(1, raised)
			function backend:geometry() return nil end              -- the dialog went away
			comp:set("scrim", group(2, Compositor.Z_SCRIM))
			assert.is_false(comp:commit())
			assert.is_nil(comp.pump)
			assert.equals(4, #destroyed)
		end)
	end)
end)
