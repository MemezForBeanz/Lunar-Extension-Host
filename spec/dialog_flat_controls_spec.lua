-- spec/dialog_flat_controls_spec.lua — host popups use flat controls only.
--
-- Native Win32 controls paint themselves from the system theme and ignore
-- BGCOLOR, so an IupButton stays light (and flashes the shell's blue on hover)
-- under every dark Lunar theme. Host dialogs therefore use IupFlatButton, and give
-- their text entries BORDER="NO" inside a themed flatframe because IUP has no
-- flat text-entry control.
--
-- Switching to flat buttons has a non-obvious consequence that this spec exists
-- to pin:
--
--   * the callback is FLAT_ACTION, not ACTION — a flatbutton never fires `action`;
--   * DEFAULTENTER / DEFAULTESC stop working. They look supported (iup_key.c
--     explicitly accepts `IupClassMatch(bt, "flatbutton")`) but then call
--     iupdrvActivate, which on Windows posts WM_COMMAND/BN_CLICKED to the parent —
--     how a NATIVE button reports a click. A flatbutton is a canvas raising
--     FLAT_ACTION from its own BUTTON_CB, so the message goes nowhere and Enter
--     and Escape silently do nothing.
--
-- Both failures are silent and invisible in a screenshot, which is what makes
-- them worth a test rather than a code review note.

local RECORDED

-- Records every widget the dialog builds, so the assertions can inspect the tree
-- without a display. Popup is a no-op, so `show` returns as if cancelled.
local function make_iup()
	local iup = {
		DEFAULT = 0, CLOSE = -3, CENTERPARENT = 0xFFFC,
		K_CR = 13, K_ESC = 27,
	}
	RECORDED = { widgets = {}, by_class = {}, closed = 0 }

	local function record(cls, def)
		local w = { cls = cls, attrs = {}, children = {} }
		for k, v in pairs(def or {}) do
			if type(k) == "string" then w.attrs[k] = v else w.children[#w.children + 1] = v end
		end
		RECORDED.widgets[#RECORDED.widgets + 1] = w
		RECORDED.by_class[cls] = RECORDED.by_class[cls] or {}
		table.insert(RECORDED.by_class[cls], w)
		return w
	end

	for _, cls in ipairs({ "text", "label", "button", "flatbutton", "flatframe",
	                       "hbox", "vbox", "fill", "dialog" }) do
		iup[cls] = function(def) return record(cls, def) end
	end

	function iup.GetAttribute(w, name) return w.attrs and w.attrs[name] end
	function iup.SetAttribute(w, name, value) w.attrs[name] = value end
	function iup.Refresh() end
	function iup.Hide() RECORDED.closed = RECORDED.closed + 1 end
	function iup.Popup() end
	function iup.Destroy() end
	return iup
end

local function flat_buttons()
	return RECORDED.by_class.flatbutton or {}
end

local function the_dialog()
	return (RECORDED.by_class.dialog or {})[1]
end

local function check_common(name)
	it(name .. ": builds no native buttons", function()
		assert.is_nil(RECORDED.by_class.button)
		assert.is_true(#flat_buttons() >= 2)
	end)

	it(name .. ": wires flat_action, never action", function()
		for _, btn in ipairs(flat_buttons()) do
			assert.is_function(btn.flat_action)
			assert.is_nil(btn.action)
		end
	end)

	it(name .. ": does not rely on DEFAULTENTER/DEFAULTESC with flat buttons", function()
		local dlg = the_dialog()
		assert.is_nil(dlg.attrs.DEFAULTENTER)
		assert.is_nil(dlg.attrs.DEFAULTESC)
	end)

	it(name .. ": handles Enter and Escape on the dialog instead", function()
		local dlg = the_dialog()
		assert.is_function(dlg.k_any)

		-- "Acted on" means the dialog closed: either by returning IUP_CLOSE or by
		-- calling IupHide. Asserting the return code alone would be wrong -- both
		-- are legitimate ways to dismiss a popup, and the two dialogs differ.
		local function dismisses(key)
			local before = RECORDED.closed
			local ret = dlg:k_any(key)
			return ret == -3 or RECORDED.closed > before
		end

		assert.is_true(dismisses(13))   -- Enter
		assert.is_true(dismisses(27))   -- Escape
		-- An unrelated key must fall through to normal handling.
		assert.are.equal(0, dlg:k_any(65))
	end)

	it(name .. ": drops the native border on text entries and themes them", function()
		for _, entry in ipairs(RECORDED.by_class.text or {}) do
			assert.are.equal("NO", entry.attrs.BORDER)
			assert.is_truthy(entry.attrs.THEMEROLE)
		end
	end)
end

-- Codebase-wide guard. The two behavioural suites below can only cover dialogs
-- that are cheap to instantiate; FolderDialog needs a filesystem and a live
-- widget tree. But the failure mode is a single attribute, so it can be caught by
-- reading the source: every host dialog now uses flat buttons, and DEFAULTENTER /
-- DEFAULTESC cannot work with one. Any occurrence is therefore dead code that
-- looks like working keyboard handling.
describe("no host dialog relies on DEFAULTENTER/DEFAULTESC", function()
	local UI_DIR = "src/lua/core/ui"

	it("finds none in " .. UI_DIR, function()
		local lfs = require("lfs")   -- deliberately not pcall'd; see below

		local offenders, scanned = {}, 0
		for entry in lfs.dir(UI_DIR) do
			if entry:match("%.lua$") then
				local path = UI_DIR .. "/" .. entry
				local f = assert(io.open(path, "r"), "cannot read " .. path)
				local n = 0
				for line in f:lines() do
					n = n + 1
					local sets_default_key = line:match("DEFAULTESC%s*=")
						or line:match("DEFAULTENTER%s*=")
					-- Comments are skipped: these files explain at length why the
					-- attributes are absent, and those mentions are the point.
					if sets_default_key and not line:match("^%s*%-%-") then
						offenders[#offenders + 1] = path .. ":" .. n .. ": " .. line:gsub("^%s+", "")
					end
				end
				f:close()
				scanned = scanned + 1
			end
		end

		-- A guard that can quietly scan nothing is worse than no guard: it reports
		-- success for work it never did. Fail loudly instead if the tree moved or
		-- the suite is run from the wrong directory.
		assert.is_true(scanned > 5, "scanned only " .. scanned .. " files in " .. UI_DIR)
		assert.are.same({}, offenders)
	end)
end)

describe("host popup dialogs use flat controls", function()
	describe("NameDialog", function()
		before_each(function()
			local iup = make_iup()
			require("core.ui.NameDialog").show({ iup = iup, title = "T", label = "L" })
		end)
		check_common("NameDialog")
	end)

	describe("AddressDialog", function()
		before_each(function()
			local iup = make_iup()
			require("core.ui.AddressDialog").show({
				iup = iup,
				host = { dispatchRoute = function() return true end },
				value = "lunar://host/settings",
			})
		end)
		check_common("AddressDialog")
	end)
end)
