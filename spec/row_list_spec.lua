describe("RowList", function()
	local RowList, attrs, bound, iup, raw

	before_each(function()
		attrs, bound = {}, nil
		iup = {
			SetAttribute = function(_, k, v) attrs[k] = v end,
			GetAttribute = function(_, k) return attrs[k] end,
			Update = function() end,
		}
		raw = {
			flatrows = function() return {} end,
			bindrows = function(_, callbacks) bound = callbacks end,
		}
		package.preload["iupraw"] = function() return raw end
		package.loaded["iupraw"] = nil
		package.loaded["core.ui.RowList"] = nil
		RowList = require("core.ui.RowList")
	end)
	after_each(function()
		package.preload["iupraw"] = nil
		package.loaded["iupraw"] = nil
		package.loaded["core.ui.RowList"] = nil
	end)

	it("takes any row height and an art size", function()
		RowList.new(iup, { row_height = 72, image_size = "48x72" })
		assert.equals("72", attrs.ROWHEIGHT)
		assert.equals("48x72", attrs.IMAGESIZE)
		RowList.new(iup, {})
		assert.equals("32", attrs.ROWHEIGHT)
	end)

	it("names six columns and a progress field", function()
		RowList.new(iup, { column_widths = { 1, 2, 3, 4, 5, 6 }, rows = { { column6 = "x", progress = 30 } } })
		assert.equals("6", attrs.COLUMN6WIDTH)
		assert.equals("x", bound.value(1, "COLUMN6"))
		assert.equals(30, bound.value(1, "PROGRESS"))
	end)

	it("bounds content without imposing a minimum on narrow layouts", function()
		local list = RowList.new(iup, {title_width=280,column_widths={112,80}})
		assert.equals("472x", attrs.MAXSIZE)
		assert.is_nil(attrs.MINSIZE)
		list:setContentWidth(320)
		assert.equals("512x", attrs.MAXSIZE)
	end)

	it("turns the sort round on a second click of the same column", function()
		local sorts = {}
		RowList.new(iup, {
			header = { title = "Name", columns = { "Year" }, sorted = { column = 0 } },
			on_sort = function(column, descending) sorts[#sorts + 1] = { column, descending } end,
		})
		assert.equals("YES", attrs.HEADER)
		assert.equals("Name", attrs.HEADERTITLE)
		assert.equals("Year", attrs.HEADER1)
		assert.equals("0", attrs.SORTCOLUMN)
		bound.header(0)
		assert.same({ 0, true }, sorts[1])
		assert.equals("DESC", attrs.SORTDIR)
		bound.header(0)
		assert.same({ 0, false }, sorts[2])
		assert.equals("ASC", attrs.SORTDIR)
		bound.header(2)
		assert.same({ 2, false }, sorts[3])
		assert.equals("2", attrs.SORTCOLUMN)
	end)

	it("clears the arrow when told there is no sort", function()
		local rows = RowList.new(iup, { header = { title = "Name" } })
		assert.equals("NO", attrs.SORTED)
		rows:setSort(1, true)
		assert.equals("YES", attrs.SORTED)
		assert.equals("DESC", attrs.SORTDIR)
		rows:setSort(nil)
		assert.equals("NO", attrs.SORTED)
	end)

	it("offers no bits to rows that did not ask for art", function()
		RowList.new(iup, {})
		assert.is_nil(bound.bits)
		RowList.new(iup, { bits = function() end })
		assert.is_function(bound.bits)
	end)

	it("retains state controllers on queue refresh and disposes removed rows", function()
		local StateIcon = require("core.ui.StateIcon")
		local original, made, destroyed = StateIcon.new, 0, 0
		StateIcon.new = function()
			made = made + 1
			return {set=function() end, destroy=function() destroyed=destroyed+1 end}
		end
		local ok, err = pcall(function()
			local list = RowList.new(iup, {rows={{title="One"},{title="Two"}}})
			list:setState(1,"running"); list:setState(2,"queued")
			list:setRows({{title="One"},{title="Two"}}, true)
			list:setState(1,"running"); list:setState(2,"queued")
			assert.equals(2, made)
			assert.equals(0, destroyed)
			list:setRows({{title="One"}}, true)
			assert.equals(1, destroyed)
			list:setRows({})
			assert.equals(2, destroyed)
		end)
		StateIcon.new = original
		assert.is_true(ok, tostring(err))
	end)
end)
