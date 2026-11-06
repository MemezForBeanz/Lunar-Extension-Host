describe("CodeView plain scrolling", function()
	local windows = package.config:sub(1, 1) == "\\"
	local loaded, preload, CodeView
	before_each(function()
		loaded, preload = package.loaded.sci, package.preload.sci
		package.loaded.sci = nil
		package.preload.sci = function() error("Scintilla unavailable") end
		CodeView = assert(loadfile("src/lua/core/ui/CodeView.lua"))()
	end)
	after_each(function() package.loaded.sci, package.preload.sci = loaded, preload end)

	local function fixture()
		local calls = {}
		local iup = { DEFAULT = 0, CONTINUE = -4, IGNORE = -1 }
		for _, kind in ipairs({ "text", "flatscrollbox" }) do
			iup[kind] = function(attrs)
				attrs.kind = kind
				calls[#calls + 1] = { "create", kind }
				return attrs
			end
		end
		function iup.SetAttribute(widget, name, value)
			widget[name] = value
			calls[#calls + 1] = { "set", name, value }
		end
		function iup.GetAttribute(widget, name) return widget[name] end
		function iup.Refresh(widget) calls[#calls + 1] = { "refresh", widget.kind } end
		return iup, calls
	end

	it("turns off native bars after text construction and uses the fork's scroll host", function()
		local iup, calls = fixture()
		local view = CodeView.new(iup, { framed = false })
		assert.same({ "create", "text" }, calls[1])
		assert.same({ "set", "SCROLLBAR", "NO" }, calls[2])
		local scroll = view:widget()
		assert.equal("flatscrollbox", scroll.kind)
		assert.equal("VERTICAL", scroll.FLATSCROLLBAR)
		assert.equal(windows and "YES" or "NO", scroll.NATIVETEXTSCROLL)
		assert.equal("outputlog_scroll", scroll.THEMEROLE)
		assert.equal(view:control(), scroll[1])
	end)
	it("refreshes the themed thumb when text changes or jumps to the end", function()
		local iup = fixture()
		local view = CodeView.new(iup, { framed = false })
		view:setText("one\ntwo\n")
		if windows then assert.equal("1", view:widget().SYNCFROMCHILD)
		else assert.equal("3", view:control().VISIBLELINES) end
		view:widget().YMAX = "400"
		view:scrollToEnd()
		assert.equal("400", view:widget().POSY)
		assert.equal("NO", view:control().SCROLLBAR)
	end)

	it("keeps the prompt single-line with no native scrollbar", function()
		local iup = fixture()
		local view = CodeView.new(iup, { framed = false, single_line = true, read_only = false })
		assert.equal("text", view:widget().kind)
		assert.equal("NO", view:control().MULTILINE)
		assert.equal("NO", view:control().SCROLLBAR)
	end)
end)
