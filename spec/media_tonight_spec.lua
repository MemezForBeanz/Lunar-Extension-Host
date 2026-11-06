package.path = "./extensions/media/?.lua;" .. package.path
local tonight = require("libs.tonight")

local NOW = 1800000000

local function film(title, minutes, progress)
	return { title = title, minutes = minutes, progress = progress or 0 }
end

local function total(picks)
	local sum = 0
	for i, pick in ipairs(picks) do sum = sum + pick.minutes + (i > 1 and tonight.BREAK_MINUTES or 0) end
	return sum
end

describe("fits tonight", function()
	it("never runs over the time you have", function()
		local items = {}
		for i = 1, 30 do items[i] = film("F" .. i, 80 + i * 3) end
		for seed = 1, 20 do
			for _, limit in ipairs({ 45, 90, 120, 180, 240 }) do
				assert.is_true(total(tonight.plan(items, limit, NOW, seed)) <= limit)
			end
		end
	end)

	it("finishes what you started first", function()
		local picks = tonight.plan({ film("New", 90), film("Started", 120, 0.5) }, 180, NOW)
		assert.equal("Started", picks[1].item.title)
		assert.equal(60, picks[1].minutes)
		assert.equal("Finish what you started", picks[1].why)
	end)

	it("leaves out a film it can't finish", function()
		local picks = tonight.plan({ film("Long", 200, 0.1), film("Short", 80) }, 90, NOW)
		assert.equal(1, #picks)
		assert.equal("Short", picks[1].item.title)
	end)

	it("skips what's been watched, and shows", function()
		local picks = tonight.plan({ film("Done", 90, 1), { title = "Show", kind = "show", minutes = 40, progress = 0 } }, 120, NOW)
		assert.equal(0, #picks)
	end)

	it("adds a break between titles", function()
		local picks = tonight.plan({ film("A", 60), film("B", 60) }, 130, NOW)
		assert.equal(2, #picks)
		assert.equal(NOW, picks[1].starts)
		assert.equal(NOW + 60 * 60, picks[1].ends)
		assert.equal(picks[1].ends + tonight.BREAK_MINUTES * 60, picks[2].starts)
	end)

	it("keeps to three titles", function()
		local items = {}
		for i = 1, 8 do items[i] = film("F" .. i, 30) end
		assert.is_true(#tonight.plan(items, 240, NOW) <= tonight.MAX_PICKS)
	end)

	it("gives the same plan for a seed, and another idea for another", function()
		local items = {}
		for i = 1, 30 do items[i] = film("F" .. i, 85 + i) end
		local function titles(seed)
			local out = {}
			for i, pick in ipairs(tonight.plan(items, 120, NOW, seed)) do out[i] = pick.item.title end
			return table.concat(out, ",")
		end
		assert.equal(titles(1), titles(1))
		local differs = false
		for seed = 2, 6 do differs = differs or titles(seed) ~= titles(1) end
		assert.is_true(differs)
	end)

	it("says when nothing fits", function()
		assert.equal("Nothing fits that yet", tonight.summary({}))
	end)
end)
