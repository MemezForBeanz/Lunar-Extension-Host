--- The Sources tab: where a library comes from. Your sources on the left with their health, and
-- the provider database on the right. Choosing a provider opens its few fields underneath, so
-- adding a source never leaves the page.
-- @module ui.sources

local L = require("core.lib.CarbonLayout")
local Kit = require("core.ui.Kit")
local RowList = require("core.ui.RowList")
local FlatField = require("core.ui.FlatField")

local M = {}

local ROW = 56
local INSET = 12
local MAX_FIELDS = 3

--- A source's state in words, and the tone to show it in.
-- @tparam table source `status`, `error`
-- @treturn string kind for `Kit.setStatus`
-- @treturn string words
function M.health(source)
	if source.status == "ok" then return "ok", "Reachable" end
	if source.status == "failed" then return "error", source.error or "Unreachable" end
	return "idle", "Not synced yet"
end

--- Build the tab.
-- @tparam table ctx host context
-- @tparam table opts `sources`, `providers`, `on_add(provider, config, name, accepted)`, `on_sync(source)`,
--   `on_remove(source)`
-- @treturn table `widget`, `setData(sources, providers)`
function M.new(ctx, opts)
	local iup = ctx.iup
	local api = {}
	local sources, providers = opts.sources or {}, opts.providers or {}
	local chosen_source, chosen_provider

	local function source_value(pos, field)
		local source = sources[pos]
		if not source then return nil end
		if field == "TITLE" then return source.name end
		if field == "SECONDARY" then return source.provider_name or "" end
		if field == "COLUMN1" then return tostring(source.items or 0) end
		if field == "COLUMN2" then
			local _, words = M.health(source)
			return words
		end
	end
	local source_list = RowList.new(iup, { value = source_value, count = #sources, row_height = ROW,
		column_widths = { 72, 200 }, role = "flatrows_plain",
		header = { title = "Source", columns = { "Items", "Health" } },
		empty_title = "Only this server so far", empty_hint = "Add a provider to bring in another library.",
		on_select = function(pos) chosen_source = sources[pos] end })
	iup.SetAttribute(source_list.widget, "EXPAND", "YES")

	local sync = Kit.button(iup, { title = "Sync now", icon = "renew", role = "actionbutton", action = function()
		if chosen_source then opts.on_sync(chosen_source) end
	end })
	local remove = Kit.button(iup, { title = "Remove", role = "actionbutton", action = function()
		if chosen_source then opts.on_remove(chosen_source) end
	end })
	iup.SetAttribute(sync, "RASTERSIZE", "x32")
	iup.SetAttribute(remove, "RASTERSIZE", "x32")

	local function provider_value(pos, field)
		local provider = providers[pos]
		if not provider then return nil end
		if field == "TITLE" then return provider.name end
		if field == "SECONDARY" then return provider.summary or "" end
	end

	local form_title = L.sectionTitle(iup, "")
	local summary = iup.flatlabel({ TITLE = "", THEMEROLE = "reading_muted", TEXTWRAP = "YES", EXPAND = "HORIZONTAL",
		ALIGNMENT = "ALEFT:ATOP", RASTERSIZE = "x44" })
	local fields = {}
	local field_box = iup.vbox({ GAP = L.gap(2), MARGIN = "0x0", EXPAND = "HORIZONTAL" })
	for i = 1, MAX_FIELDS do
		local label = iup.flatlabel({ TITLE = "", THEMEROLE = "reading_muted" })
		local field = FlatField.new(iup, {})
		fields[i] = { label = label, field = field, box = iup.vbox({ label, field.widget, GAP = L.gap(1), MARGIN = "0x0", EXPAND = "HORIZONTAL" }) }
		iup.Append(field_box, fields[i].box)
	end
	local notice = iup.flattoggle({ TITLE = "I understand, and only add what I have the right to share",
		THEMEROLE = "flattoggle", VALUE = "OFF" })
	local add = Kit.button(iup, { title = "Add source", icon = "add", role = "primary_btn", action = function()
		if not chosen_provider then return end
		local config = {}
		for i, spec in ipairs(chosen_provider.fields or {}) do config[spec.id] = fields[i].field:value() end
		opts.on_add(chosen_provider, config, nil, iup.GetAttribute(notice, "VALUE") == "ON")
		for i = 1, MAX_FIELDS do fields[i].field:setValue("") end
		iup.SetAttribute(notice, "VALUE", "OFF")
	end })
	iup.SetAttribute(add, "RASTERSIZE", "x36")
	local form = L.stack(iup, { form_title, summary, field_box, notice, iup.hbox({ add, MARGIN = "0x0" }) }, 2)
	iup.SetAttribute(form, "EXPAND", "HORIZONTAL")

	local function choose_provider(provider)
		chosen_provider = provider
		if not provider then return end
		iup.SetAttribute(form_title, "TITLE", provider.name)
		iup.SetAttribute(summary, "TITLE", provider.summary or "")
		for i = 1, MAX_FIELDS do
			local spec = (provider.fields or {})[i]
			Kit.show(iup, fields[i].box, spec ~= nil, form_title)
			if spec then
				iup.SetAttribute(fields[i].label, "TITLE", spec.label)
				fields[i].field._cue = spec.cue or ""
				fields[i].field:setValue("")
			end
		end
		Kit.show(iup, notice, provider.off_by_default == true, form_title)
		iup.Refresh(api.widget)
	end

	local provider_list = RowList.new(iup, { value = provider_value, count = #providers, row_height = ROW,
		column_widths = {}, role = "flatrows_plain",
		header = { title = "Provider", columns = {} },
		on_select = function(pos) choose_provider(providers[pos]) end })
	iup.SetAttribute(provider_list.widget, "EXPAND", "YES")

	local left = L.stack(iup, {
		iup.hbox({ L.sectionTitle(iup, "Your sources"), iup.fill({}), sync, remove, GAP = L.gap(2), ALIGNMENT = "ACENTER",
			MARGIN = INSET .. "x0", EXPAND = "HORIZONTAL" }),
		source_list.widget,
	}, 3)
	local right = L.stack(iup, {
		iup.hbox({ L.sectionTitle(iup, "Provider database"), MARGIN = INSET .. "x0" }),
		provider_list.widget,
		iup.hbox({ form, MARGIN = INSET .. "x0", EXPAND = "HORIZONTAL" }),
	}, 3)
	iup.SetAttribute(left, "EXPAND", "YES")
	iup.SetAttribute(right, "EXPAND", "YES")

	api.widget = iup.vbox({
		iup.hbox({ iup.vbox({ iup.flatlabel({ TITLE = "Sources", THEMEROLE = "pagetitle" }),
			L.hint(iup, "Every library here joins one view, with one card for each title."), GAP = L.gap(1), MARGIN = "0x0" }),
			MARGIN = INSET .. "x0" }),
		iup.hbox({ left, right, GAP = L.gap(8), MARGIN = "0x0", EXPAND = "YES", HOMOGENEOUS = "YES" }),
		GAP = L.gap(6), MARGIN = L.margin(5), EXPAND = "YES",
	})

	--- Show what the server says.
	function api.setData(next_sources, next_providers)
		sources = next_sources or sources
		providers = next_providers or providers
		source_list:setProvider(#sources, source_value)
		provider_list:setProvider(#providers, provider_value)
		if providers[1] then
			provider_list:select(1)
			choose_provider(providers[1])
		end
	end

	api.setData(sources, providers)
	return api
end

return M
