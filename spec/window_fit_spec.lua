-- spec/window_fit_spec.lua — desktop.windowFit and desktop.rectEq.
--
-- `windowFit` is pure arithmetic: given a monitor work-area rect it returns the
-- IUP MAXSIZE/MINSIZE strings that keep the main dialog within that monitor.
-- That arithmetic is the core of the monitor-tracking fix and it can regress
-- silently (wrong slack, inverted clamp) without this suite catching it.
--
-- `rectEq` is the MOVE_CB guard: it must return true for an identical rect so
-- that IupSetAttribute is NOT called on every mouse-move sample during a drag,
-- and false when the monitor boundary is crossed.
--
-- Neither function touches FFI or IUP, so both run cleanly under busted.

local desktop = require("core.lib.desktop")

-- ---- windowFit -------------------------------------------------------------

describe("desktop.windowFit", function()
	it("caps MAXSIZE height at work_h + 40 (resize-border slack)", function()
		-- The +40 is required: a maximised window on Win10/11 extends beyond the
		-- work area by the invisible resize border.  Capping at exactly work_h
		-- forbids that and leaves a visible strip of desktop at the bottom.
		local fit = desktop.windowFit({ left = 0, top = 0, right = 1920, bottom = 1080 })
		assert.are.equal("65535x1120", fit.maxsize)
	end)

	it("uses the uncapped horizontal sentinel (65535) for width", function()
		-- Capping width would shrink the window on a multi-monitor setup where
		-- the secondary is wider than the primary used at startup.
		local fit = desktop.windowFit({ left = 0, top = 0, right = 1920, bottom = 1080 })
		assert.are.equal("65535", fit.maxsize:match("^(%d+)x"))
	end)

	it("computes correct MAXSIZE for a smaller secondary monitor (1366x768)", function()
		local fit = desktop.windowFit({ left = 1920, top = 0, right = 3286, bottom = 768 })
		-- height cap = 768 + 40 = 808
		assert.are.equal("65535x808", fit.maxsize)
	end)

	it("computes correct MAXSIZE for a larger monitor (2560x1440)", function()
		local fit = desktop.windowFit({ left = 0, top = 0, right = 2560, bottom = 1440 })
		assert.are.equal("65535x1480", fit.maxsize)
	end)

	it("clamps MINSIZE height to 500 on a tall monitor", function()
		-- MIN_H = min(500, max(320, work_h - 80))
		-- For 1080: min(500, max(320, 1000)) = min(500, 1000) = 500
		local fit = desktop.windowFit({ left = 0, top = 0, right = 1920, bottom = 1080 })
		local _, min_h = fit.minsize:match("^(%d+)x(%d+)")
		assert.are.equal(500, tonumber(min_h))
	end)

	it("does not let MINSIZE height exceed the work area on a short monitor", function()
		-- A monitor that is only 400 px tall: min(500, max(320, 320)) = 320.
		-- Without this clamp MINSIZE would be unsatisfiable: the window can't
		-- shrink to fit and the bottom is forced off screen regardless of MAXSIZE.
		local fit = desktop.windowFit({ left = 0, top = 0, right = 1024, bottom = 400 })
		local _, min_h = fit.minsize:match("^(%d+)x(%d+)")
		assert.are.equal(320, tonumber(min_h))
		-- And it must be strictly less than the work area height.
		assert.is_true(tonumber(min_h) < 400)
	end)

	it("floors MINSIZE height at 320 when work_h is tiny", function()
		-- work_h = 200 → work_h - 80 = 120, but floor is 320.
		local fit = desktop.windowFit({ left = 0, top = 0, right = 800, bottom = 200 })
		local _, min_h = fit.minsize:match("^(%d+)x(%d+)")
		assert.are.equal(320, tonumber(min_h))
	end)

	it("clamps MINSIZE width to 700 on a wide monitor", function()
		local fit = desktop.windowFit({ left = 0, top = 0, right = 2560, bottom = 1440 })
		local min_w = fit.minsize:match("^(%d+)x")
		assert.are.equal(700, tonumber(min_w))
	end)

	it("floors MINSIZE width at 400 on a very narrow monitor", function()
		-- work_w = 300 → work_w - 80 = 220, but floor is 400.
		local fit = desktop.windowFit({ left = 0, top = 0, right = 300, bottom = 768 })
		local min_w = fit.minsize:match("^(%d+)x")
		assert.are.equal(400, tonumber(min_w))
	end)

	it("exposes work_w and work_h in the returned table", function()
		local fit = desktop.windowFit({ left = 100, top = 50, right = 1820, bottom = 830 })
		-- The rect has a non-zero origin (secondary monitor at offset (100,50)).
		-- work dimensions must be derived from the rect, not just right/bottom.
		assert.are.equal(1720, fit.work_w)
		assert.are.equal(780,  fit.work_h)
	end)

	it("produces an identical result for two calls with the same rect (pure / idempotent)", function()
		local r = { left = 0, top = 0, right = 1920, bottom = 1080 }
		local a = desktop.windowFit(r)
		local b = desktop.windowFit(r)
		assert.are.equal(a.maxsize, b.maxsize)
		assert.are.equal(a.minsize, b.minsize)
	end)
end)

-- ---- rectEq ----------------------------------------------------------------

describe("desktop.rectEq", function()
	it("returns true for two identical rects", function()
		local r = { left = 0, top = 0, right = 1920, bottom = 1080 }
		assert.is_true(desktop.rectEq(r, { left = 0, top = 0, right = 1920, bottom = 1080 }))
	end)

	it("returns true for the same table reference", function()
		local r = { left = 0, top = 0, right = 1920, bottom = 1080 }
		assert.is_true(desktop.rectEq(r, r))
	end)

	it("returns false when width changes (right differs)", function()
		local a = { left = 0, top = 0, right = 1920, bottom = 1080 }
		local b = { left = 0, top = 0, right = 2560, bottom = 1080 }
		assert.is_false(desktop.rectEq(a, b))
	end)

	it("returns false when height changes (bottom differs)", function()
		local a = { left = 0, top = 0, right = 1920, bottom = 1080 }
		local b = { left = 0, top = 0, right = 1920, bottom = 768 }
		assert.is_false(desktop.rectEq(a, b))
	end)

	it("returns false when the monitor origin changes (window moved to offset monitor)", function()
		-- Crossing a monitor boundary may shift the origin even when width/height
		-- are the same; the guard must notice so MAXSIZE is re-applied.
		local a = { left = 0,    top = 0, right = 1920, bottom = 1080 }
		local b = { left = 1920, top = 0, right = 3840, bottom = 1080 }
		assert.is_false(desktop.rectEq(a, b))
	end)

	it("returns true for two nils", function()
		assert.is_true(desktop.rectEq(nil, nil))
	end)

	it("returns false when one side is nil", function()
		local r = { left = 0, top = 0, right = 1920, bottom = 1080 }
		assert.is_false(desktop.rectEq(r, nil))
		assert.is_false(desktop.rectEq(nil, r))
	end)
end)
