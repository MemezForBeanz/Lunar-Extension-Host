-- Native parser acceptance: run with LunarCLI, where file_stream is preloaded.
local native = require("file_stream")
local matrix = {
	{ "0", "", 200, "0", "0" }, { "0", "bytes=0-", 416, "0", "0" },
	{ "10", "bytes=0-0", 206, "0", "1" }, { "10", "bytes=-3", 206, "7", "3" },
	{ "10", "bytes=8-", 206, "8", "2" }, { "10", "bytes=-99", 206, "0", "10" },
	{ "10", "bytes=4-99", 206, "4", "6" }, { "10", "bytes=-0", 416, "0", "0" },
	{ "10", "bytes=10-", 416, "0", "0" }, { "10", "bytes=9-8", 416, "0", "0" },
	{ "10", "bytes=0-1,3-4", 416, "0", "0" },
	{ "10", "bytes=9223372036854775808-", 416, "0", "0" },
	{ "9223372036854775807", "bytes=9223372036854775806-", 206, "9223372036854775806", "1" },
	{ "9223372036854775807", "bytes=-9223372036854775807", 206, "0", "9223372036854775807" },
	{ "9007199254740993", "bytes=9007199254740992-", 206, "9007199254740992", "1" },
}
for _, row in ipairs(matrix) do
	local code, offset, length = native.plan(row[1], row[2])
	assert(code == row[3] and offset == row[4] and length == row[5], table.concat(row, ","))
end
for _, value in ipairs({ "bytes=", "bytes=-", "bytes=x-y", "items=0-1", "bytes=0-1 ", "bytes=+1-2" }) do
	assert(native.plan("10", value) == 416, value)
end
assert(not pcall(native.target, "D:/media", "/untrusted", "video/mp4"))
assert(not pcall(native.target, "D:/media", "file", "video/mp4\r\nInjected: yes"))
print("native file range checks passed: " .. #matrix .. " exact arithmetic cases plus malformed inputs")
