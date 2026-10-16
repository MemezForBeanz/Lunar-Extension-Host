--- Thin, defensive wrapper around the `tableshape` schema library.
-- Provides a single, safe place to validate the shape of data that crosses
-- a trust boundary: JSON decoded from disk (settings, presets, run index)
-- or received from the network (backend responses). Validating at the
-- boundary produces early, descriptive errors instead of mysterious failures
-- deep in the UI or run store.
--
-- **Defensive loading**: if tableshape cannot be loaded this module
-- degrades to permissive no-ops (`available == false`) so validation
-- never becomes a hard dependency that breaks a context. Callers can
-- check `validate.available` when they need to know whether checks are real.
-- @module core.lib.validate

local ok_ts, tableshape = pcall(require, "tableshape")

local M = {
	--- `true` when tableshape is loaded and validation is actually enforced.
	available = ok_ts and true or false,
	--- The tableshape `types` table, or `nil` when unavailable.
	-- Use this to build shape descriptors, e.g.
	-- `validate.types.shape{ name = validate.types.string }`.
	types = ok_ts and tableshape.types or nil,
}

--- Validate a value against a tableshape shape descriptor.
-- When validation is unavailable (tableshape missing) or no shape is
-- supplied, the call passes permissively so the caller's normal path is
-- never blocked.
-- @param shape a tableshape shape object (from `validate.types`), or `nil` to skip.
-- @param value the value to validate.
-- @treturn[1] boolean `true` on success.
-- @treturn[2] boolean `false` on failure.
-- @treturn[2] string human-readable error message describing the mismatch.
function M.check(shape, value)
	if not M.available or shape == nil then
		return true, nil
	end
	local ok, err = shape(value)
	if ok then
		return true, nil
	end
	return false, err
end

--- Validate a value and raise a Lua error if it does not conform.
-- Intended for internal invariants where a violation is a programming bug.
-- For untrusted input use `check` and handle the error rather than raising.
-- @param shape a tableshape shape object (from `validate.types`), or `nil` to skip.
-- @param value the value to validate.
-- @tparam[opt="validation failed"] string label prefix for the error message.
-- @return the original `value` unchanged (for use in assignments).
-- @raise formatted Lua error when validation fails.
function M.assert_valid(shape, value, label)
	local ok, err = M.check(shape, value)
	if not ok then
		error(string.format("%s: %s", label or "validation failed", tostring(err)), 2)
	end
	return value
end

return M
