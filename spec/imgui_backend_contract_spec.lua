-- spec/imgui_backend_contract_spec.lua -- the backend contract (core.imgui.backend.contract).
-- The headless backend must conform, as every platform backend must; the native one is
-- checked in the real executable by scripts/backend_conformance.lua.

local contract = require("core.imgui.backend.contract")
local Null = require("core.imgui.backend.Null")

describe("the ImGui backend contract", function()
	it("finds nothing missing on the headless backend", function()
		local missing = contract.check(Null.new())
		assert.same({}, missing)
	end)

	it("reports the optional capabilities a backend has", function()
		local _, caps = contract.check(Null.new({ dialog_windows = true }))
		assert.is_true(caps.dialog_windows)
		assert.is_true(caps.provider_pixels)
		local _, plain = contract.check(Null.new())
		assert.is_false(plain.dialog_windows)
		assert.is_false(plain.gdi_text)
	end)

	it("names what a backend lacks", function()
		local B = Null.new()
		B.text_size, B.clipboard_get = nil, nil
		local missing = contract.check(B)
		table.sort(missing)
		assert.same({ "clipboard_get", "text_size" }, missing)
	end)

	it("drives the headless backend through the whole contract without a problem", function()
		assert.same({}, contract.exercise(Null.new()))
	end)

	it("reports a misbehaving backend", function()
		local B = Null.new()
		B.text_size = function() return 0, 0 end
		B.frame_begin = function() return { w = 1 } end
		local problems = contract.exercise(B)
		local text = table.concat(problems, "\n")
		assert.truthy(text:find("text_size(abc)", 1, true))
		assert.truthy(text:find("input.h is nil", 1, true))
	end)
end)
