--- Bounded scrollback, retaining styles only while their text is retained.
local Buffer = {}
Buffer.__index = Buffer
--- A new, empty scrollback.
-- @tparam[opt=262144] number limit most bytes of text to keep
-- @treturn table the buffer
function Buffer.new(limit)
	return setmetatable({ blocks = {}, bytes = 0, limit = limit or 256 * 1024 }, Buffer)
end
function Buffer:clear() self.blocks, self.bytes = {}, 0 end
function Buffer:append(text, opts)
	opts = opts or {}
	text = tostring(text)
	if not opts.language then text = text:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\27%[[%d;?]*[%a]", "") end
	if #text > self.limit then
		text = text:sub(-self.limit)
		-- Do not begin on a UTF-8 continuation byte.
		while #text > 0 and text:byte(1) >= 128 and text:byte(1) < 192 do text = text:sub(2) end
		opts = { role = opts.role }
	end
	local block = { text = text, language = opts.language, role = opts.role, tokens = opts.tokens }
	self.blocks[#self.blocks + 1], self.bytes = block, self.bytes + #text
	while self.bytes > self.limit and #self.blocks > 1 do
		local removed = table.remove(self.blocks, 1)
		self.bytes = self.bytes - #removed.text
	end
	return block
end
function Buffer:snapshot()
	local texts, fragments, start = {}, {}, 0
	for _, block in ipairs(self.blocks) do
		texts[#texts + 1] = block.text
		block.start, block.length = start, #block.text
		fragments[#fragments + 1] = block
		start = start + #block.text
	end
	return table.concat(texts), fragments
end
return Buffer
