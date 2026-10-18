--- Windows backend for `core.platform`. Use `core.platform`, not this module.
--
-- Every Win32 call is made through LuaJIT FFI and guarded: if a call or a DLL is
-- unavailable the function falls back to a safe answer rather than raising.
--
-- Strings are UTF-8 on both sides of this module. Calls that take or return a
-- path use the wide (*W) API and convert with CP_UTF8, and the exe manifest sets
-- the process code page to UTF-8 so io.open, lfs and IUP read the same strings.
--
-- @module core.platform.win32

local M = {}

local ok_ffi, ffi = pcall(require, "ffi")
if not ok_ffi then ffi = nil end

-- Declarations may already exist in other modules' cdefs; declare one at a time
-- and ignore "attempt to redefine".
local function cdef(decls)
	if not ffi then return end
	for _, d in ipairs(decls) do pcall(ffi.cdef, d) end
end

cdef({
	"typedef struct { unsigned long Data1; unsigned short Data2, Data3; unsigned char Data4[8]; } LUNAR_GUID;",
	"long SHGetKnownFolderPath(const LUNAR_GUID* rfid, unsigned long flags, void* token, wchar_t** path);",
	"void CoTaskMemFree(void* pv);",
	"int WideCharToMultiByte(unsigned int cp, unsigned long flags, const wchar_t* w, int wl, char* mb, int mbl, const char* def, int* used);",
	"int GetComputerNameExW(int type, wchar_t* buf, unsigned long* size);",
	"int MoveFileExW(const wchar_t* existing, const wchar_t* replacement, unsigned long flags);",
	"int QueryPerformanceCounter(int64_t *count);",
	"int QueryPerformanceFrequency(int64_t *freq);",
	"int SystemParametersInfoA(unsigned int action, unsigned int param, void *data, unsigned int winini);",
	"unsigned int timeBeginPeriod(unsigned int period);",
	"unsigned int timeEndPeriod(unsigned int period);",
	"void* ShellExecuteW(void* hwnd, const wchar_t* op, const wchar_t* file, const wchar_t* params, const wchar_t* dir, int show);",
	"int MultiByteToWideChar(unsigned int cp, unsigned long flags, const char* mb, int mbl, wchar_t* w, int wl);",
	"unsigned long GetLastError(void);",
	[[typedef struct {
		unsigned long Flags, Type;
		wchar_t* TargetName; wchar_t* Comment;
		unsigned long LastWrittenLow, LastWrittenHigh;
		unsigned long CredentialBlobSize; unsigned char* CredentialBlob;
		unsigned long Persist, AttributeCount;
		void* Attributes; wchar_t* TargetAlias; wchar_t* UserName;
	} LUNAR_CREDENTIALW;]],
	"int CredWriteW(LUNAR_CREDENTIALW* cred, unsigned long flags);",
	"int CredReadW(const wchar_t* target, unsigned long type, unsigned long flags, LUNAR_CREDENTIALW** cred);",
	"int CredDeleteW(const wchar_t* target, unsigned long type, unsigned long flags);",
	"void CredFree(void* buffer);",
	[[typedef struct {
		unsigned long dwScope, dwType, dwDisplayType, dwUsage;
		wchar_t* lpLocalName; wchar_t* lpRemoteName; wchar_t* lpComment; wchar_t* lpProvider;
	} LUNAR_NETRESOURCEW;]],
	"unsigned long WNetAddConnection2W(LUNAR_NETRESOURCEW* res, const wchar_t* password, const wchar_t* user, unsigned long flags);",
	"unsigned long WNetCancelConnection2W(const wchar_t* name, unsigned long flags, int force);",
	"void* FindFirstFileW(const wchar_t* pattern, void* data);",
	"int FindClose(void* handle);",
})

local libs = {}
local function lib(name)
	if libs[name] == nil then
		local ok, l = pcall(ffi.load, name)
		libs[name] = ok and l or false
	end
	return libs[name] or nil
end

-- ---------------------------------------------------------------------------
-- Window placement
-- ---------------------------------------------------------------------------

cdef({ "int SetWindowPos(void *hwnd, void *after, int x, int y, int cx, int cy, unsigned int flags);" })

local SWP_NOSIZE, SWP_NOZORDER, SWP_NOACTIVATE = 0x0001, 0x0004, 0x0010

--- Move a mapped dialog without resizing, activating or restacking it.
-- @param iup the IUP binding (unused here)
-- @param dlg IUP dialog handle
-- @tparam number x screen x
-- @tparam number y screen y
-- @treturn boolean
function M.move_window(iup, dlg, x, y)
	if not ffi then return false end
	local ok_iupffi, IupFFI = pcall(require, "core.classes.IupFFI")
	if not (ok_iupffi and IupFFI.available) then return false end
	local user32 = lib("user32")
	if not user32 then return false end
	local ok, moved = pcall(function()
		local p = IupFFI.ptr(dlg)
		if p == nil then return false end
		local hwnd = IupFFI.getptr(p, "HWND")
		if hwnd == nil then return false end
		return user32.SetWindowPos(hwnd, nil, x, y, 0, 0,
			SWP_NOSIZE + SWP_NOZORDER + SWP_NOACTIVATE) ~= 0
	end)
	return ok and moved or false
end

-- Wide string -> UTF-8 (the process code page, so io.open and lfs accept it).
local CP_UTF8 = 65001
local function narrow(wstr, wlen)
	local n = ffi.C.WideCharToMultiByte(CP_UTF8, 0, wstr, wlen or -1, nil, 0, nil, nil)
	if n <= 0 then return nil end
	local buf = ffi.new("char[?]", n)
	ffi.C.WideCharToMultiByte(CP_UTF8, 0, wstr, wlen or -1, buf, n, nil, nil)
	return ffi.string(buf, wlen and n or n - 1)
end

-- UTF-8 -> a NUL-terminated wide string (kept alive by the returned cdata).
local function widen(s)
	local n = ffi.C.MultiByteToWideChar(CP_UTF8, 0, s, #s, nil, 0)
	local buf = ffi.new("wchar_t[?]", n + 1)
	if n > 0 then ffi.C.MultiByteToWideChar(CP_UTF8, 0, s, #s, buf, n) end
	return buf
end

local function known_folder(d1, d2, d3, d4)
	if not ffi then return nil end
	local shell32, ole32 = lib("shell32"), lib("ole32")
	if not (shell32 and ole32) then return nil end
	local guid = ffi.new("LUNAR_GUID", d1, d2, d3, d4)
	local out = ffi.new("wchar_t*[1]")
	local ok, hr = pcall(shell32.SHGetKnownFolderPath, guid, 0, nil, out)
	if not ok or hr ~= 0 or out[0] == nil then return nil end
	local path = narrow(out[0])
	ole32.CoTaskMemFree(out[0])
	return path
end

local function env(name)
	local v = os.getenv(name)
	if v and v ~= "" then return v end
	return nil
end

-- Windows Credential Manager (generic credentials, this user, this machine).
local CRED_TYPE_GENERIC, CRED_PERSIST_LOCAL_MACHINE, ERROR_NOT_FOUND = 1, 2, 1168
-- Credential Manager's limit on a generic credential's blob.
local CRED_MAX_BLOB = 5 * 512

local function advapi()
	return ffi and lib("advapi32") or nil
end

--- Read a secret: the value, or nil plus "not found" / why the store failed.
function M.secret_get(target)
	local a = advapi()
	if not a then return nil, "Credential Manager unavailable" end
	local out = ffi.new("LUNAR_CREDENTIALW*[1]")
	if a.CredReadW(widen(target), CRED_TYPE_GENERIC, 0, out) == 0 then
		local code = ffi.C.GetLastError()
		return nil, code == ERROR_NOT_FOUND and "not found" or ("CredRead failed (" .. tonumber(code) .. ")")
	end
	local cred = out[0]
	local value = ffi.string(cred.CredentialBlob, cred.CredentialBlobSize)
	a.CredFree(cred)
	return value
end

--- Store (or replace) a secret.
function M.secret_set(target, value)
	local a = advapi()
	if not a then return nil, "Credential Manager unavailable" end
	if #value > CRED_MAX_BLOB then return nil, "secret is too long for Credential Manager" end
	local cred = ffi.new("LUNAR_CREDENTIALW")
	local wtarget, blob = widen(target), ffi.new("unsigned char[?]", math.max(#value, 1))
	ffi.copy(blob, value, #value)
	cred.Type, cred.Persist = CRED_TYPE_GENERIC, CRED_PERSIST_LOCAL_MACHINE
	cred.TargetName, cred.CredentialBlobSize, cred.CredentialBlob = wtarget, #value, blob
	local user = widen("lunar")
	cred.UserName = user
	if a.CredWriteW(cred, 0) == 0 then
		return nil, "CredWrite failed (" .. tonumber(ffi.C.GetLastError()) .. ")"
	end
	return true
end

--- Delete a secret. Deleting one that isn't there succeeds.
function M.secret_delete(target)
	local a = advapi()
	if not a then return nil, "Credential Manager unavailable" end
	if a.CredDeleteW(widen(target), CRED_TYPE_GENERIC, 0) == 0 then
		local code = ffi.C.GetLastError()
		if code ~= ERROR_NOT_FOUND then return nil, "CredDelete failed (" .. tonumber(code) .. ")" end
	end
	return true
end

-- ---------------------------------------------------------------------------
-- Network shares: sign in to an SMB server with an account other than your
-- Windows login (a separate file-server account).
-- ---------------------------------------------------------------------------

local CRED_TYPE_DOMAIN_PASSWORD, CRED_PERSIST_SESSION = 2, 1
local RESOURCETYPE_ANY, CONNECT_TEMPORARY = 0, 4
local WNET_ERRORS = {
	[5] = "access denied",
	[53] = "the server can't be found (on the network or VPN?)",
	[64] = "the server can't be reached (on the network or VPN?)",
	[67] = "the share name can't be found",
	[86] = "wrong password",
	[1219] = "this PC is already connected to that server with a different account; "
		.. "disconnect it (net use \\\\SERVER\\IPC$ /delete) or sign out, then try again",
	[1326] = "wrong user name or password",
	[1327] = "the account can't sign in now (restrictions)",
	[1330] = "the password has expired",
	[1331] = "the account is disabled",
	[1909] = "the account is locked out",
	[2202] = "the user name isn't in a valid form (try DOMAIN\\user)",
}

local function utf16_blob(s)
	local w = widen(s)
	local n = ffi.C.MultiByteToWideChar(65001, 0, s, #s, nil, 0)
	return w, n * 2   -- bytes, without the terminator
end

--- Can this folder be listed? `"ok"`, `"denied"`, `"missing"` or `"unreachable"`,
-- plus the Windows error code. (lfs reports every failure as "No such file",
-- which can't tell a missing folder from one this account may not read.)
function M.probe_dir(path)
	if not ffi then return nil end
	local data = ffi.new("uint8_t[600]")   -- WIN32_FIND_DATAW is 592 bytes
	local h = ffi.C.FindFirstFileW(widen(path:gsub("[/\\]+$", "") .. "\\*"), data)
	if ffi.cast("intptr_t", h) ~= -1 then
		ffi.C.FindClose(h)
		return "ok"
	end
	local code = tonumber(ffi.C.GetLastError())
	if code == 5 or code == 1326 then return "denied", code end
	if code == 53 or code == 64 or code == 1231 then return "unreachable", code end
	return "missing", code
end

--- Sign in to `\\server` for this user. The account is remembered the way
-- Explorer's "Remember my credentials" does it (a Windows credential named after
-- the server), so every program, child processes included, can then open
-- `\\server\...` paths; with `remember = false` it lasts until you sign out.
-- The sign-in is tested by connecting to `\\server\IPC$` and, when `check_path`
-- is given, by listing that folder: some servers (Samba with "map to guest")
-- accept any name and password on IPC$ as a guest, so IPC$ alone proves
-- nothing. A credential that doesn't work is removed again.
-- @treturn[1] boolean true
-- @treturn[2] nil
-- @treturn[2] string why, in plain words
function M.network_login(server, user, password, remember, check_path)
	local a, mpr = advapi(), ffi and lib("mpr")
	if not (a and mpr) then return nil, "network sign-in isn't available" end
	if not server:match("^[%w][%w.-]*$") then return nil, "not a server name: " .. server end
	local cred = ffi.new("LUNAR_CREDENTIALW")
	local wtarget, wuser = widen(server), widen(user)
	local wpass, nbytes = utf16_blob(password)
	cred.Type = CRED_TYPE_DOMAIN_PASSWORD
	cred.Persist = remember and CRED_PERSIST_LOCAL_MACHINE or CRED_PERSIST_SESSION
	cred.TargetName, cred.UserName = wtarget, wuser
	cred.CredentialBlobSize, cred.CredentialBlob = nbytes, ffi.cast("unsigned char*", wpass)
	if a.CredWriteW(cred, 0) == 0 then
		return nil, "couldn't save the sign-in (" .. tonumber(ffi.C.GetLastError()) .. ")"
	end
	-- A session opened earlier with another account would be reused; drop it so
	-- the new account is the one tested.
	local ipc = widen("\\\\" .. server .. "\\IPC$")
	mpr.WNetCancelConnection2W(ipc, 0, 1)
	local res = ffi.new("LUNAR_NETRESOURCEW")
	res.dwType, res.lpRemoteName = RESOURCETYPE_ANY, ipc
	local code = mpr.WNetAddConnection2W(res, wpass, wuser, CONNECT_TEMPORARY)
	if code ~= 0 then
		a.CredDeleteW(wtarget, CRED_TYPE_DOMAIN_PASSWORD, 0)
		return nil, WNET_ERRORS[tonumber(code)] or ("couldn't connect (error " .. tonumber(code) .. ")")
	end
	if check_path then
		local state = M.probe_dir(check_path)
		if state == "denied" then
			mpr.WNetCancelConnection2W(ipc, 0, 1)
			a.CredDeleteW(wtarget, CRED_TYPE_DOMAIN_PASSWORD, 0)
			return nil, server .. " answered, but this account can't open " .. check_path
				.. ". The user name may need its domain (e.g. " .. server:upper() .. "\\name), "
				.. "or the account hasn't been given access to that share."
		elseif state ~= "ok" then
			return nil, "signed in, but " .. check_path .. " isn't there (" .. tostring(state) .. ")"
		end
	end
	return true
end

--- Forget the sign-in for `\\server` and drop this session's connection to it.
function M.network_logout(server)
	local a, mpr = advapi(), ffi and lib("mpr")
	if not (a and mpr) then return nil, "network sign-in isn't available" end
	mpr.WNetCancelConnection2W(widen("\\\\" .. server .. "\\IPC$"), 0, 1)
	a.CredDeleteW(widen(server), CRED_TYPE_DOMAIN_PASSWORD, 0)
	return true
end

--- Roaming per-user settings root (`%APPDATA%`).
function M.user_config_root()
	return env("APPDATA")
		or known_folder(0x3EB685DB, 0x65F9, 0x4CF6, { 0xA0, 0x3A, 0xE3, 0xEF, 0x65, 0x72, 0x9F, 0x3D })
end

--- Local per-user root for caches and bulky data (`%LOCALAPPDATA%`).
function M.user_cache_root()
	return env("LOCALAPPDATA")
		or known_folder(0xF1B32785, 0x6FBA, 0x4FCF, { 0x9D, 0x55, 0x7B, 0x8E, 0x7F, 0x15, 0x70, 0x91 })
end

--- Machine-wide data root, as **Windows** reports it (FOLDERID_ProgramData),
-- never from the environment: org policy lives under it.
function M.system_data_root()
	return known_folder(0x62AB5D82, 0xFDC1, 0x4DC3, { 0xA9, 0xDD, 0x07, 0x0D, 0x1D, 0x49, 0x5D, 0x97 })
end

function M.temp_dir()
	return env("TEMP") or env("TMP") or "C:\\Windows\\Temp"
end

function M.home_dir()
	return env("USERPROFILE")
		or ((env("HOMEDRIVE") or "") .. (env("HOMEPATH") or ""))
end

--- This machine's DNS domain from Windows (ComputerNameDnsDomain), not the
-- environment, or nil.
function M.dns_domain()
	if not ffi then return nil end
	local size = ffi.new("unsigned long[1]", 256)
	local buf = ffi.new("wchar_t[256]")
	local ok, r = pcall(function() return ffi.C.GetComputerNameExW(2, buf, size) end)
	if not ok or r == 0 or size[0] == 0 then return nil end
	return narrow(buf, tonumber(size[0]))
end

--- Replace `dst` with `src` in one step (MoveFileEx REPLACE_EXISTING |
-- WRITE_THROUGH): on failure the old `dst` is untouched.
function M.replace_file(src, dst)
	if not ffi then return false end
	local ok, r = pcall(function() return ffi.C.MoveFileExW(widen(src), widen(dst), 1 + 8) end)
	return ok and r ~= 0
end

--- Make a font file available to this process only (AddFontResourceEx,
-- FR_PRIVATE); it disappears when the process exits.
-- @treturn boolean
-- @treturn string|nil Why not.
function M.register_font(path)
	local gdi32 = ffi and lib("gdi32")
	if not gdi32 then return false, "gdi32 unavailable" end
	cdef({ "int AddFontResourceExW(const wchar_t* name, unsigned long fl, void* res);" })
	local ok, n = pcall(function() return gdi32.AddFontResourceExW(widen(path), 0x10, nil) end)
	if ok and n > 0 then return true end
	return false, "could not load font " .. tostring(path)
end

-- Accounts that may own or write an admin-only folder: Administrators, SYSTEM and
-- TrustedInstaller.
local ADMIN_SIDS = {
	["S-1-5-32-544"] = true,
	["S-1-5-18"] = true,
	["S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464"] = true,
}
-- Rights that let an account change a folder's contents or its protection:
-- add file / add subfolder / delete child, DELETE, WRITE_DAC, WRITE_OWNER,
-- GENERIC_ALL, GENERIC_WRITE.
local WRITE_MASK = 0x2 + 0x4 + 0x40 + 0x10000 + 0x40000 + 0x80000 + 0x10000000 + 0x40000000
local ACCESS_ALLOWED_ACE_TYPE, INHERIT_ONLY_ACE = 0, 0x08
-- ACCESS_DENIED, ACCESS_DENIED_OBJECT, ACCESS_DENIED_CALLBACK(_OBJECT).
local DENY_ACE_TYPES = { [1] = true, [6] = true, [10] = true, [12] = true }
local ok_bit, bit = pcall(require, "bit")
if not ok_bit then bit = nil end

--- Is `dir` (a folder or file) protected so only administrators can change it?
-- True when it is not a link of any kind (symlink, junction or other reparse
-- point, which could lead somewhere unchecked), it is owned
-- by Administrators, SYSTEM or TrustedInstaller, and no other account is allowed
-- to add, delete or rewrite anything in it or change its permissions. Anything
-- that can't be read or checked counts as not protected.
-- @tparam string dir
-- @treturn boolean
-- @treturn string|nil Why not.
function M.admin_only(dir)
	local advapi32 = ffi and bit and lib("advapi32")
	local kernel32 = ffi and bit and lib("kernel32")
	if not (advapi32 and kernel32) then return false, "advapi32 unavailable" end
	cdef({
		"unsigned long GetNamedSecurityInfoW(const wchar_t* name, int type, unsigned long info, void** owner, void** group, void** dacl, void** sacl, void** sd);",
		"int ConvertSidToStringSidA(void* sid, char** out);",
		"void* LocalFree(void* mem);",
		"typedef struct { uint32_t AceCount, AclBytesInUse, AclBytesFree; } LUNAR_ACL_SIZE;",
		"int GetAclInformation(void* acl, void* info, unsigned long len, int cls);",
		"int GetAce(void* acl, unsigned long index, void** ace);",
		"unsigned long GetFileAttributesW(const wchar_t* name);",
		"typedef struct { uint8_t AceType; uint8_t AceFlags; uint16_t AceSize; uint32_t Mask; uint32_t SidStart; } LUNAR_ACE;",
	})

	local function sid_string(sid)
		local out = ffi.new("char*[1]")
		if advapi32.ConvertSidToStringSidA(sid, out) == 0 then return nil end
		local s = ffi.string(out[0])
		kernel32.LocalFree(out[0])
		return s
	end

	-- INVALID_FILE_ATTRIBUTES = 0xFFFFFFFF; FILE_ATTRIBUTE_REPARSE_POINT = 0x400.
	local wdir = widen(dir)
	local attrs = tonumber(kernel32.GetFileAttributesW(wdir))
	if attrs == 0xFFFFFFFF then return false, "not found" end
	if bit.band(attrs, 0x400) ~= 0 then return false, "is a link (reparse point)" end

	local owner, dacl, sd = ffi.new("void*[1]"), ffi.new("void*[1]"), ffi.new("void*[1]")
	-- SE_FILE_OBJECT = 1; OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION.
	local ok, rc = pcall(function()
		return advapi32.GetNamedSecurityInfoW(wdir, 1, 0x1 + 0x4, owner, nil, dacl, nil, sd)
	end)
	if not ok or rc ~= 0 then return false, "cannot read permissions (error " .. tostring(rc) .. ")" end

	local verdict, why = true, nil
	local ok_walk, err = pcall(function()
		local who = sid_string(owner[0])
		if not (who and ADMIN_SIDS[who]) then
			verdict, why = false, "owned by " .. tostring(who) .. ", not Administrators or SYSTEM"
			return
		end
		if dacl[0] == nil then
			verdict, why = false, "no access list (everyone has full control)"
			return
		end
		local info = ffi.new("LUNAR_ACL_SIZE")
		-- AclSizeInformation (2) starts with the ACE count.
		if advapi32.GetAclInformation(dacl[0], info, ffi.sizeof(info), 2) == 0 then
			verdict, why = false, "cannot read the access list"
			return
		end
		local ace = ffi.new("void*[1]")
		for i = 0, info.AceCount - 1 do
			if advapi32.GetAce(dacl[0], i, ace) == 0 then
				verdict, why = false, "cannot read the access list"
				return
			end
			local a = ffi.cast("LUNAR_ACE*", ace[0])
			local inherit_only = bit.band(a.AceFlags, INHERIT_ONLY_ACE) ~= 0
			-- Deny entries only take rights away. Inherit-only entries don't apply to
			-- this object; callers check each child separately.
			if not DENY_ACE_TYPES[a.AceType] and not inherit_only and bit.band(a.Mask, WRITE_MASK) ~= 0 then
				-- Object and callback allow entries put the SID elsewhere; refuse them.
				local who_ace = a.AceType == ACCESS_ALLOWED_ACE_TYPE
					and sid_string(ffi.cast("char*", ace[0]) + 8) or nil
				if not (who_ace and ADMIN_SIDS[who_ace]) then
					verdict, why = false, tostring(who_ace or "an unrecognised entry") .. " can modify it"
					return
				end
			end
		end
	end)
	kernel32.LocalFree(sd[0])
	if not ok_walk then return false, "cannot check permissions: " .. tostring(err) end
	return verdict, why
end

--- Is Windows in dark mode for apps? Reads AppsUseLightTheme (Settings >
-- Personalization > Colors > "Choose your app mode"). nil when Windows doesn't
-- have the setting (before Windows 10 1809) or it can't be read.
-- @treturn boolean|nil
function M.system_dark()
	local advapi32 = advapi()
	if not advapi32 then return nil end
	cdef({ "long RegGetValueW(void* hkey, const wchar_t* subkey, const wchar_t* value, unsigned long flags, unsigned long* type, void* data, unsigned long* size);" })
	-- HKEY_CURRENT_USER is (HKEY)(ULONG_PTR)(LONG)0x80000001: sign-extended on x64.
	local HKCU = ffi.cast("void*", ffi.cast("intptr_t", -2147483647))
	local RRF_RT_REG_DWORD = 0x10
	local data = ffi.new("uint32_t[1]")
	local size = ffi.new("unsigned long[1]", 4)
	local ok, rc = pcall(function()
		return advapi32.RegGetValueW(HKCU,
			widen("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
			widen("AppsUseLightTheme"), RRF_RT_REG_DWORD, nil, data, size)
	end)
	if not ok or rc ~= 0 then return nil end
	return data[0] == 0
end

--- No-op on Windows: the window icon is the exe's ICON resource (`ICON="IUP"`).
-- @treturn boolean false
-- @treturn string why
function M.set_app_icon()
	return false, "Windows uses the exe's icon resource"
end

--- Native widget styling is GTK-only; Windows draws its native controls itself.
-- @treturn boolean false
-- @treturn string why
function M.apply_native_style()
	return false, "not needed on Windows"
end

--- Open a file, folder or URL with its default application.
function M.open(target)
	local shell32 = ffi and lib("shell32")
	if not shell32 then return false, "shell32 unavailable" end
	local ok, h = pcall(shell32.ShellExecuteW, nil, widen("open"), widen(target), nil, nil, 1)
	-- ShellExecute returns a value > 32 on success.
	if ok and tonumber(ffi.cast("intptr_t", h)) > 32 then return true end
	return false, "could not open " .. tostring(target)
end


--- Start the program at `path` detached, so it keeps running after this one exits.
function M.launch(path)
	return M.open(path)
end

-- ---------------------------------------------------------------------------
-- Elevation and Windows Installer
-- ---------------------------------------------------------------------------

cdef({
	[[typedef struct {
		unsigned long cbSize, fMask; void* hwnd;
		const wchar_t* lpVerb; const wchar_t* lpFile; const wchar_t* lpParameters; const wchar_t* lpDirectory;
		int nShow; void* hInstApp; void* lpIDList; const wchar_t* lpClass; void* hkeyClass;
		unsigned long dwHotKey; void* hIcon; void* hProcess;
	} LUNAR_SHELLEXECUTEINFOW;]],
	"int ShellExecuteExW(LUNAR_SHELLEXECUTEINFOW* info);",
	"unsigned long WaitForSingleObject(void* handle, unsigned long ms);",
	"int GetExitCodeProcess(void* handle, unsigned long* code);",
	"int CloseHandle(void* handle);",
	"unsigned long MsiEnumRelatedProductsW(const wchar_t* upgrade_code, unsigned long reserved, unsigned long index, wchar_t* product);",
	"int MsiQueryFeatureStateW(const wchar_t* product, const wchar_t* feature);",
})

-- One argument as CommandLineToArgvW will read it back.
local function quote_arg(a)
	a = tostring(a)
	if a ~= "" and not a:find('[%s"]') then return a end
	local out = a:gsub('(\\*)"', '%1%1\\"'):gsub("(\\+)$", "%1%1")
	return '"' .. out .. '"'
end
M.quote_arg = quote_arg

--- Run `argv` elevated (a UAC prompt unless the process is already elevated).
-- Returns a job with `poll()` (the exit code once the program has finished, else
-- nil), `output()` (always "": an elevated program's output isn't ours) and
-- `close()`; or nil and why. Declining the prompt gives nil and `"cancelled"`.
function M.elevate(argv)
	local shell32 = ffi and lib("shell32")
	if not shell32 then return nil, "shell32 unavailable" end
	local params = {}
	for i = 2, #argv do params[#params + 1] = quote_arg(argv[i]) end
	local file, args = widen(argv[1]), widen(table.concat(params, " "))
	local verb = widen("runas")
	local info = ffi.new("LUNAR_SHELLEXECUTEINFOW")
	info.cbSize = ffi.sizeof(info)
	info.fMask = 0x40 + 0x100   -- SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC
	info.lpVerb, info.lpFile, info.lpParameters = verb, file, args
	info.nShow = 0
	if shell32.ShellExecuteExW(info) == 0 then
		if ffi.C.GetLastError() == 1223 then return nil, "cancelled" end   -- ERROR_CANCELLED
		return nil, "could not start " .. tostring(argv[1])
	end
	local handle, code = info.hProcess, nil
	return {
		poll = function()
			if code ~= nil then return code end
			if handle == nil then return nil end
			if ffi.C.WaitForSingleObject(handle, 0) ~= 0 then return nil end
			local out = ffi.new("unsigned long[1]")
			ffi.C.GetExitCodeProcess(handle, out)
			code = tonumber(out[0])
			ffi.C.CloseHandle(handle)
			handle = nil
			return code
		end,
		output = function() return "" end,
		close = function()
			if handle ~= nil then ffi.C.CloseHandle(handle) handle = nil end
		end,
	}
end

--- Which of `features` (MSI feature ids) are installed locally for the product
-- family `upgrade_code` (`"{GUID}"`)? Returns `{ [feature] = true }`, or nil when
-- that product isn't installed (or Windows Installer can't be asked).
function M.msi_installed_features(upgrade_code, features)
	local msi = ffi and lib("msi")
	if not msi then return nil end
	local product = ffi.new("wchar_t[39]")
	local ok, rc = pcall(msi.MsiEnumRelatedProductsW, widen(upgrade_code), 0, 0, product)
	if not ok or rc ~= 0 then return nil end
	local found = {}
	for _, feature in ipairs(features) do
		local okq, state = pcall(msi.MsiQueryFeatureStateW, product, widen(feature))
		if okq and state == 3 then found[feature] = true end   -- INSTALLSTATE_LOCAL
	end
	return found
end

--- The folder 64-bit programs install under (`%ProgramW6432%`).
function M.program_files_dir()
	return env("ProgramW6432") or env("ProgramFiles") or "C:\\Program Files"
end

-- ---------------------------------------------------------------------------
-- Clock
-- ---------------------------------------------------------------------------

local clock = {}
M.clock = clock

local qpc_buf, freq_hz, spi_buf, origin
do
	local kernel32 = ffi and lib("kernel32")
	if kernel32 then
		local freq = ffi.new("int64_t[1]")
		if kernel32.QueryPerformanceFrequency(freq) ~= 0 and tonumber(freq[0]) > 0 then
			freq_hz = tonumber(freq[0])
			qpc_buf = ffi.new("int64_t[1]")
		end
		spi_buf = ffi.new("int[1]")
	end
end

--- Whether a high-resolution monotonic clock is available.
clock.precise = freq_hz ~= nil

--- Monotonic seconds since an arbitrary origin (QueryPerformanceCounter).
-- Falls back to whole seconds of wall time; never to os.clock, which is CPU time
-- and stands still while the app waits.
function clock.now()
	if freq_hz and lib("kernel32").QueryPerformanceCounter(qpc_buf) ~= 0 then
		local ticks = tonumber(qpc_buf[0])
		if not origin then origin = ticks end
		return (ticks - origin) / freq_hz
	end
	return os.time()
end

--- Ask for 1 ms timer resolution (timeBeginPeriod); `false` if unsupported.
function clock.begin_high_resolution()
	local winmm = ffi and lib("winmm")
	if not winmm then return false end
	return (pcall(winmm.timeBeginPeriod, 1))
end

function clock.end_high_resolution()
	local winmm = ffi and lib("winmm")
	if winmm then pcall(winmm.timeEndPeriod, 1) end
end

--- Has the user turned animations off (SPI_GETCLIENTAREAANIMATION)?
-- @treturn boolean|nil nil when it can't be determined.
function clock.reduced_motion()
	local user32 = ffi and lib("user32")
	if not user32 then return nil end
	local ok, r = pcall(user32.SystemParametersInfoA, 0x1042, 0, spi_buf, 0)
	if not ok or r == 0 then return nil end
	return spi_buf[0] == 0
end

return M
