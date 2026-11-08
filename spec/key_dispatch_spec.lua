local Keys = require("core.classes.host.Keys")

describe("shortcut dispatch lifecycle", function()
	it("continues dispatch when a handler unregisters itself", function()
		local owner = {}
		local host = { iup = { IGNORE = -1 }, _shortcuts = {}, _owners = {} }
		function host:_activeOwner() return owner end
		function host:_record(key)
			self._owners[key] = self._owners[key] or { shortcuts = {}, tabs = {} }
			return self._owners[key]
		end
		local seen, once = {}, nil
		once = Keys.registerShortcut(host, 27, function()
			seen[#seen + 1] = "once"
			assert.is_true(Keys.unregisterShortcut(host, once))
		end, owner)
		Keys.registerShortcut(host, 27, function() seen[#seen + 1] = "persistent" end, owner)
		assert.equals(-1, Keys._dispatchKey(host, 27))
		assert.same({ "once", "persistent" }, seen)
		Keys._dispatchKey(host, 27)
		assert.same({ "once", "persistent", "persistent" }, seen)
	end)
end)
