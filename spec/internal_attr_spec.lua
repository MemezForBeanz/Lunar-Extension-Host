-- spec/internal_attr_spec.lua — core.lib.attr and the identity it underpins.
--
-- IUP treats any attribute whose name starts with `_IUP` as internal, and the
-- host relies on that: internal attributes are local to a widget, while ordinary
-- ones are inherited by every descendant. A tab's layout key showing up on every
-- widget inside the page makes the tree unreadable, so the prefix is deliberate.
--
-- The trap is that the Lua binding will not hand those attributes BACK:
--
--     /* srclua5/iuplua_api.c, iuplua_pushvalue */
--     if (!value || iupATTRIB_ISINTERNAL(name))
--       lua_pushnil(L);
--
-- So `iup.GetAttribute(w, "_IUPLUNAR_TABKEY")` answers nil no matter what was
-- stored — silently, with no error. Everything built on those attributes then
-- behaved as though nothing had ever been written:
--
--   * `handle.id` minted a fresh id per call, so `handle.same()` never recognised
--     a widget it had already seen, defeating every identity check in the tab code
--   * `TabGroups:serialize` found no key on any tab and dropped them all, so the
--     saved arrangement kept the groups and lost their contents — and every launch
--     re-appended the user's grouped tabs at the root
--
-- These tests pin the contract that fixed it. They cannot exercise the real
-- binding (there is no IUP under busted), so they verify the behaviour `attr`
-- guarantees and, critically, that `handle` is stable when reads work — which is
-- what actually broke.

local attr = require("core.lib.attr")
local handle = require("core.lib.handle")

-- A fake IUP whose attribute store behaves like the C side: writes always land,
-- and reads return what was written.
local function fake_iup()
	local iup = {}
	function iup.SetAttribute(w, name, value) w.attrs[name] = value end
	function iup.GetAttribute(w, name) return w.attrs[name] end
	return iup
end

local function widget()
	return { attrs = {} }
end

describe("core.lib.attr", function()
	it("reads back an internal attribute that was written", function()
		local iup, w = fake_iup(), widget()
		attr.set(iup, w, "_IUPLUNAR_TABKEY", "ext.demo/1")
		assert.are.equal("ext.demo/1", attr.get(iup, w, "_IUPLUNAR_TABKEY"))
	end)

	it("reads back an ordinary attribute too", function()
		local iup, w = fake_iup(), widget()
		attr.set(iup, w, "TABTITLE", "Demo")
		assert.are.equal("Demo", attr.get(iup, w, "TABTITLE"))
	end)

	it("returns nil for an attribute that was never set", function()
		local iup, w = fake_iup(), widget()
		assert.is_nil(attr.get(iup, w, "_IUPLUNAR_TABKEY"))
	end)

	it("tolerates a nil widget or a non-string name", function()
		local iup = fake_iup()
		assert.is_nil(attr.get(iup, nil, "_IUPLUNAR_TABKEY"))
		assert.is_nil(attr.get(iup, widget(), nil))
		assert.has_no.errors(function() attr.set(iup, nil, "X", "1") end)
	end)

	it("survives a binding whose GetAttribute throws", function()
		local iup = fake_iup()
		iup.GetAttribute = function() error("no such handle") end
		assert.is_nil(attr.get(iup, widget(), "_IUPLUNAR_TABKEY"))
	end)
end)

describe("core.lib.handle identity", function()
	it("returns the SAME id for repeated calls on one widget", function()
		-- The regression that broke everything downstream: when the read came back
		-- nil, every call minted a new id.
		local iup, w = fake_iup(), widget()
		local first = handle.id(iup, w)
		assert.are.equal(first, handle.id(iup, w))
		assert.are.equal(first, handle.id(iup, w))
	end)

	it("recognises two different handles to the same widget", function()
		-- The binding allocates a fresh userdata per push, so this is the ONLY way
		-- to answer "same widget?" — and it is what the tab drag/drop guards use.
		local iup = fake_iup()
		local real = widget()
		local a = setmetatable({}, { __index = real })
		local b = setmetatable({}, { __index = real })
		-- Both proxies read and write through to the same attribute store.
		a.attrs, b.attrs = real.attrs, real.attrs
		assert.is_true(handle.same(iup, a, b))
	end)

	it("distinguishes genuinely different widgets", function()
		local iup = fake_iup()
		assert.is_false(handle.same(iup, widget(), widget()))
	end)

	it("treats a widget as the same as itself", function()
		local iup, w = fake_iup(), widget()
		assert.is_true(handle.same(iup, w, w))
	end)

	it("answers false when either handle is nil", function()
		local iup = fake_iup()
		assert.is_false(handle.same(iup, nil, widget()))
		assert.is_false(handle.same(iup, widget(), nil))
		assert.is_false(handle.same(iup, nil, nil))
	end)
end)
