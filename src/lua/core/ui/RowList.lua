--- Thin Lua API for the native virtual row canvas and joined option control.
-- The C controls draw visible rows only. A virtual provider is called as
-- value(row_number, field_name), where field_name is TITLE, SECONDARY, IMAGE,
-- COLUMN1..6, ACTIONTEXT or PROGRESS (0 to 100, a line along the bottom of the row).
-- Row numbers are 1 based; VALUEPOS is 0 based.
--
-- `row_height` is free, 20 to 400; from 44 up a row has a second line. `image_size` is "16"
-- or "WxH". `bits(row, w, h)` gives art rows raw pixels instead of a named image, as in
-- `core.ui.CellGrid`, and reserves the art slot on every row, so a missing image draws a tile
-- and titles stay in line.
--
-- `header` adds a band that stays put when rows scroll: `{ title = "Name", columns = { "Year",
-- "Size" }, sorted = { column = 0, descending = false } }`. A click calls
-- `on_sort(column, descending)`, column 0 being the title, and turns the arrow; re-sort the
-- rows there. Columns draw right to left from the last one with a width.
-- @module core.ui.RowList
local raw = require("iupraw")
local M = {}

local fields = { TITLE = "title", SECONDARY = "secondary", IMAGE = "image",
    COLUMN1 = "column1", COLUMN2 = "column2", COLUMN3 = "column3",
    COLUMN4 = "column4", COLUMN5 = "column5", COLUMN6 = "column6",
    ACTIONTEXT = "action", PROGRESS = "progress" }

--- Create a row canvas.
-- @tparam userdata iup
-- @tparam[opt] table opts `rows` or `value` and `count`, `row_height`, `image_size`, `bits`,
-- `header`, `empty_title`, `empty_hint`, `column_widths`, `role`, and the `on_*` callbacks
-- @treturn table `widget`, `setRows`, `setProvider`, `setEmpty`, `select`, `selected`, `setSort`
function M.new(iup, opts)
    opts = opts or {}
    local raw_api = opts.raw or raw
    local widget = raw_api.flatrows()
    iup.SetAttribute(widget, "THEMEROLE", opts.role or "flatrows")
    iup.SetAttribute(widget, "ROWHEIGHT", tostring(opts.row_height or 32))
    if opts.image_size then iup.SetAttribute(widget, "IMAGESIZE", tostring(opts.image_size)) end
    iup.SetAttribute(widget, "FLATSCROLLBAR", "VERTICAL")
    iup.SetAttribute(widget, "EMPTYTITLE", opts.empty_title or "Nothing here yet")
    iup.SetAttribute(widget, "EMPTYHINT", opts.empty_hint or "")
    for i = 1, 6 do
        iup.SetAttribute(widget, "COLUMN" .. i .. "WIDTH", tostring((opts.column_widths or {})[i] or 0))
    end
    local function set_sort(column, descending)
        iup.SetAttribute(widget, "SORTED", column and "YES" or "NO")
        iup.SetAttribute(widget, "SORTCOLUMN", tostring(column or 0))
        iup.SetAttribute(widget, "SORTDIR", descending and "DESC" or "ASC")
    end
    local sort_column, sort_descending
    if opts.header then
        iup.SetAttribute(widget, "HEADERTITLE", opts.header.title or "")
        for i, label in ipairs(opts.header.columns or {}) do
            iup.SetAttribute(widget, "HEADER" .. i, label)
        end
        local sorted = opts.header.sorted
        if sorted then sort_column, sort_descending = sorted.column or 0, sorted.descending or false end
        set_sort(sort_column, sort_descending)
        iup.SetAttribute(widget, "HEADER", "YES")
    end
    local rows = opts.rows or {}
    local value = opts.value
    raw_api.bindrows(widget, {
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
        bits = opts.bits,
        header = function(column)
            sort_descending = column == sort_column and not sort_descending
            sort_column = column
            set_sort(sort_column, sort_descending)
            if opts.on_sort then opts.on_sort(column, sort_descending) end
        end,
    })
    iup.SetAttribute(widget, "COUNT", tostring(opts.count or #rows))
    local api = { widget = widget }
    --- Show a sort without a click. A nil column clears the arrow.
    function api:setSort(column, descending)
        sort_column, sort_descending = column, descending or false
        set_sort(sort_column, sort_descending)
    end
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

--- Create a joined option control of two to five labels.
-- @tparam userdata iup
-- @tparam[opt] table opts `labels`, `value_pos`, `on_change`, `role`
-- @return the IUP handle
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
