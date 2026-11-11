--- Elements: the plain-table description of what a component wants on screen.
--
-- `ui.VBox{ gap = 8, ui.Text{ "Hi" } }` and `ui.h(ui.VBox, { gap = 8 }, ui.Text{ "Hi" })`
-- both build the same element. The array part of the table holds the children; the
-- string keys are props. Two names are reserved: `key` (identity among siblings) and
-- `ref` (a `{ current = ... }` table or a function receiving the host handle).
--
-- Children may be elements, strings and numbers (text content), nested plain arrays
-- (flattened, so `ui.VBox{ header, rows }` works with `rows` a list of elements), and
-- `nil`/`false` holes, which are skipped so `cond and ui.X{}` reads naturally.
--
-- @module core.lui.vnode
local M = {}

--- Metatable marking a table as an element (so a list of elements and an element
-- with no props can be told apart).
local ELEMENT = { __name = "lui.element" }
M.ELEMENT = ELEMENT

--- The fragment type: children without a host widget of their own.
M.Fragment = setmetatable({ kind = "fragment", name = "Fragment" }, { __tostring = function() return "lui.Fragment" end })

function M.isElement(v)
	return type(v) == "table" and getmetatable(v) == ELEMENT
end

-- Append the children found in `list[1..n]` to `out`, flattening plain arrays.
local function collect(out, list, n)
	for i = 1, n do
		local c = list[i]
		if c == nil or c == false or c == true then
			-- a hole: `cond and ui.X{}` with cond false, or nil
		elseif type(c) == "table" and getmetatable(c) == nil then
			-- a plain list of children (an iup handle on the emulator is a table too, but
			-- has a metatable, so it is kept and later embedded as a Native)
			collect(out, c, table.maxn(c))
		else
			out[#out + 1] = c
		end
	end
	return out
end
M.collect = collect

--- Build an element.
-- @param type a primitive (from `core.lui.primitives`), a function component,
--   `Fragment`, or a special type (`Native`, a context Provider, `ErrorBoundary`)
-- @tparam[opt] table props props; its array part is taken as children
-- @param ... more children, after the array part
-- @treturn table the element `{ type, props, key, ref }`; `props.children` is the list
function M.h(type_, props, ...)
	if type_ == nil then error("lui.h: element type is nil (a misspelt primitive?)", 2) end
	local p, children = {}, {}
	local key, ref
	if props ~= nil then
		if type(props) ~= "table" or getmetatable(props) == ELEMENT then
			error("lui.h: props must be a plain table, got " .. type(props), 2)
		end
		for k, v in pairs(props) do
			if type(k) ~= "number" then
				if k == "key" then key = v
				elseif k == "ref" then ref = v
				elseif k ~= "children" then p[k] = v end
			end
		end
		collect(children, props, table.maxn(props))
		if props.children ~= nil then collect(children, props.children, table.maxn(props.children)) end
	end
	local n = select("#", ...)
	if n > 0 then collect(children, { ... }, n) end
	p.children = children
	return setmetatable({ type = type_, props = p, key = key, ref = ref }, ELEMENT)
end

--- A callable type: `T{ ... }` builds `h(T, { ... })`. Used for primitives and for
-- components wrapped with `ui.component`.
function M.callable(t)
	local mt = getmetatable(t) or {}
	mt.__call = function(self, props, ...) return M.h(self, props, ...) end
	return setmetatable(t, mt)
end

return M
