--- Thin Lua API for the native virtual row canvas and joined option control.
-- The C controls draw visible rows only. A virtual provider is called as
-- value(row_number, field_name), where field_name is TITLE, SECONDARY, IMAGE,
-- COLUMN1..3 or ACTIONTEXT. Row numbers are 1 based; VALUEPOS is 0 based.
local raw = require("iupraw")
local M = {}

local fields = { TITLE = "title", SECONDARY = "secondary", IMAGE = "image",
    COLUMN1 = "column1", COLUMN2 = "column2", COLUMN3 = "column3",
    ACTIONTEXT = "action" }

function M.new(iup, opts)
    opts = opts or {}
    local widget = raw.flatrows()
    iup.SetAttribute(widget, "THEMEROLE", opts.role or "flatrows")
    iup.SetAttribute(widget, "ROWHEIGHT", tostring(opts.row_height == 44 and 44 or 32))
    iup.SetAttribute(widget, "FLATSCROLLBAR", "YES")
    iup.SetAttribute(widget, "EMPTYTITLE", opts.empty_title or "Nothing here yet")
    iup.SetAttribute(widget, "EMPTYHINT", opts.empty_hint or "")
    for i = 1, 3 do
        iup.SetAttribute(widget, "COLUMN" .. i .. "WIDTH", tostring((opts.column_widths or {})[i] or 0))
    end
    local rows = opts.rows or {}
    local value = opts.value
    raw.bindrows(widget, {
        value = function(pos, field)
            if value then return value(pos, field) end
            local row = rows[pos]
            return row and row[fields[field]] or nil
        end,
        action = opts.on_select,
        part = opts.on_part,
        activate = opts.on_activate,
        context = opts.on_context,
        changed = opts.on_change,
    })
    iup.SetAttribute(widget, "COUNT", tostring(opts.count or #rows))
    local api = { widget = widget }
    function api:setRows(next_rows)
        rows = next_rows or {}
        value = nil
        iup.SetAttribute(widget, "COUNT", tostring(#rows))
        iup.Update(widget)
    end
    function api:setProvider(count, fn)
        value = fn
        rows = {}
        iup.SetAttribute(widget, "COUNT", tostring(count or 0))
        iup.Update(widget)
    end
    function api:setEmpty(title, hint)
        iup.SetAttribute(widget, "EMPTYTITLE", title or "")
        iup.SetAttribute(widget, "EMPTYHINT", hint or "")
        iup.Update(widget)
    end
    function api:select(pos) iup.SetAttribute(widget, "VALUE", tostring(pos or 0)) end
    function api:selected() return tonumber(iup.GetAttribute(widget, "VALUE")) or 0 end
    return api
end

function M.segmented(iup, opts)
    opts = opts or {}
    local labels = opts.labels or { "First", "Second" }
    assert(#labels >= 2 and #labels <= 5, "segmented needs 2 to 5 labels")
    local widget = raw.flatsegmented()
    iup.SetAttribute(widget, "THEMEROLE", opts.role or "flatsegmented")
    iup.SetAttribute(widget, "COUNT", tostring(#labels))
    for i, label in ipairs(labels) do iup.SetAttributeId(widget, "TITLE", i-1, label) end
    iup.SetAttribute(widget, "VALUEPOS", tostring(opts.value_pos or 0))
    raw.bindsegmented(widget, { changed = opts.on_change })
    return widget
end

return M
