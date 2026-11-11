--- Lunar UI: components, hooks and a reconciler over the `iup` API.
--
-- ```lua
-- local ui = require("core.lui")
--
-- local function Counter(props)
--   local n, setN = ui.useState(props.start or 0)
--   return ui.HBox{ gap = 8, align = "center",
--     ui.Text{ "Clicked " .. n .. " times" },
--     ui.Button{ "Add", variant = "primary", onClick = function() setN(n + 1) end },
--   }
-- end
--
-- local root = ui.mount(Counter, { props = { start = 1 } })
-- iup.Append(some_box, root:widget())   -- an ordinary iup handle
-- ```
--
-- See `docs/lunar-ui.md` for the guide: primitives and their props, hooks, interop with
-- existing iup code, and testing with `core.lui.test`.
--
-- @module core.lui
local vnode = require("core.lui.vnode")
local hooks = require("core.lui.hooks")
local store = require("core.lui.store")
local props = require("core.lui.props")
local prim = require("core.lui.primitives")
local R = require("core.lui.reconciler")
local S = require("core.lui.scheduler")

local ui = {}

-- Elements
ui.h = vnode.h
ui.Fragment = vnode.callable(vnode.Fragment)
ui.isElement = vnode.isElement

-- Primitives
for _, name in ipairs({
	"VBox", "HBox", "ZBox", "Spacer", "Frame", "Scroll", "Tabs", "Split", "Text", "Label",
	"Image", "Button", "Toggle", "Input", "Separator", "List", "Canvas", "Dialog", "Dropdown",
}) do
	ui[name] = assert(prim[name], name)
end
ui.host = prim.host
ui.definePrimitive = prim.define

-- Special elements
ui.Native = R.Native
ui.ErrorBoundary = R.ErrorBoundary
ui.createContext = R.createContext
ui.component = R.component
ui.memo = R.memo

-- Hooks
ui.useState = hooks.useState
ui.useReducer = hooks.useReducer
ui.useEffect = hooks.useEffect
ui.useLayoutEffect = hooks.useLayoutEffect
ui.useMemo = hooks.useMemo
ui.useCallback = hooks.useCallback
ui.useRef = hooks.useRef
ui.useContext = hooks.useContext
ui.useStore = hooks.useStore

-- Stores
ui.createStore = store.createStore

-- Colours
ui.token = props.token

-- Roots and scheduling
ui.mount = R.mount

--- Run `fn` with updates batched, then render and commit everything pending before
-- returning. `ui.flushSync()` with no function just flushes.
function ui.flushSync(fn, ...)
	if fn == nil then return S.flushAll() end
	return S.batch(fn, ...)
end

--- Batch updates without forcing a flush when the batch is nested in another.
ui.batch = S.batch

return ui
