local Fonts = require("core.imgui.Fonts")
local Null = require("core.imgui.backend.Null")

local function backend()
	local b = Null.new()
	Fonts.backend = b
	Fonts.dpi = 96
	Fonts.reset()
	return b
end

local function counted_text_size(b)
	local calls = 0
	local original = b.text_size
	b.text_size = function(...)
		calls = calls + 1
		return original(...)
	end
	return function() return calls end
end

describe("imgui font measurement cache", function()
	it("caches exact empty, wrapped, and UTF-8 measurements per font", function()
		local b = backend()
		local calls = counted_text_size(b)
		local font = Fonts.get("Segoe UI, 9")
		local utf8 = "héllo"

		assert.same({ 0, 15 }, { font:measure("") })
		assert.same({ 0, 15 }, { font:measure("") })
		assert.same({ 25, 30 }, { font:measure(utf8, 25) })
		assert.same({ 25, 30 }, { font:measure(utf8, 25) })
		assert.equal(1, calls())

		local stats = Fonts.measure_cache_stats()
		assert.equal(2, stats.hits)
		assert.equal(2, stats.misses)
	end)

	it("isolates wrapping and font identity", function()
		local b = backend()
		local calls = counted_text_size(b)
		local regular = Fonts.get("Segoe UI, 9")
		local large = Fonts.get("Segoe UI, 12")

		regular:measure("abcdef", 10)
		regular:measure("abcdef", 20)
		large:measure("abcdef", 10)
		regular:measure("abcdef", 10)

		assert.equal(3, calls())
		assert.equal(1, Fonts.measure_cache_stats().hits)
	end)

	it("invalidates on backend, DPI, registration, and reset changes", function()
		local b = backend()
		local calls = counted_text_size(b)
		local font = Fonts.get("Segoe UI, 9")
		font:measure("same")
		font:measure("same")
		assert.equal(1, calls())

		local b2 = Null.new()
		Fonts.backend = b2
		local calls2 = counted_text_size(b2)
		Fonts.get("Segoe UI, 9"):measure("same")
		assert.equal(1, calls2())

		Fonts.dpi = 144
		local dpi_font = Fonts.get("Segoe UI, 9")
		assert.equal(18, dpi_font.px)
		dpi_font:measure("same")
		assert.equal(2, calls2())

		b2.font_name_tables.registered = { [1] = "Registered", [2] = "Regular", [4] = "Registered" }
		assert.is_true(Fonts.register("registered"))
		Fonts.get("Registered, 9"):measure("same")
		assert.equal(3, calls2())

		Fonts.reset()
		assert.equal(0, Fonts.measure_cache_stats().entries)
		Fonts.get("Registered, 9"):measure("same")
		assert.equal(4, calls2())
	end)

	it("evicts old entries within both configured bounds", function()
		local b = backend()
		local font = Fonts.get("Segoe UI, 9")
		for i = 1, 300 do font:measure("entry-" .. i) end

		local stats = Fonts.measure_cache_stats()
		assert.is_true(stats.entries <= stats.max_entries)
		assert.is_true(stats.bytes <= stats.max_bytes)
		assert.is_true(stats.entries > 0)
	end)
	it("updates retained font character metrics and ascent after DPI changes", function()
		backend()
		local old=Fonts.get("Segoe UI, 9")
		local w,h=old:charsize(); local ascent=old:ascent()
		Fonts.dpi=144
		local current=Fonts.get("Segoe UI, 9")
		assert.same({current:charsize()},{old:charsize()})
		assert.equal(current:ascent(),old:ascent())
		assert.is_true(current:ascent()>ascent)
		local nw,nh=old:charsize()
		assert.is_true(nw>w or nh>h)
	end)
end)
