--- The documents a language server has open: `didOpen`, debounced `didChange`,
-- `didClose`, versions, and the mapping between an editor's byte columns and the
-- protocol's positions.
--
-- The editor (Scintilla) counts columns in UTF-8 bytes. The protocol counts in
-- UTF-16 code units unless the server agreed to `utf-8`, so every position that
-- crosses the boundary is converted here, against the text the server has.
--
-- Changes are sent whole (a `contentChanges` entry without a range), which every
-- server accepts whichever sync kind it advertises. Typing is debounced: `change`
-- only records the text, and `tick` sends it once the document has been quiet.
--
-- @classmod core.lsp.Documents
local Json = require("core.lsp.Json")
local Uri = require("core.lsp.Uri")

local Documents = {}
Documents.__index = Documents

--- Seconds a document must be quiet before its change is sent.
Documents.DEBOUNCE = 0.15

-- ---------------------------------------------------------------------------
-- Positions
-- ---------------------------------------------------------------------------

--- UTF-16 code units in the first `bytes` bytes of a UTF-8 string.
-- Bytes that are not valid UTF-8 count one unit each, so a position is always
-- produced.
function Documents.byteToCharacter(line, bytes, encoding)
	if bytes <= 0 then return 0 end
	if bytes > #line then bytes = #line end
	if encoding == "utf-8" then return bytes end
	local units = 0
	for i = 1, bytes do
		local b = line:byte(i)
		if b < 0x80 or b >= 0xC0 then
			units = units + (b >= 0xF0 and 2 or 1)
		end
	end
	return units
end

--- The byte offset in a UTF-8 line of protocol character `character`.
-- A character past the end of the line maps to the end of the line, as the
-- protocol says it should.
function Documents.characterToByte(line, character, encoding)
	if character <= 0 then return 0 end
	if encoding == "utf-8" then return math.min(character, #line) end
	local units, i, n = 0, 1, #line
	while i <= n do
		if units >= character then return i - 1 end
		local b = line:byte(i)
		local width = 1
		if b >= 0xF0 then width = 4 elseif b >= 0xE0 then width = 3 elseif b >= 0xC0 then width = 2 end
		units = units + (b >= 0xF0 and 2 or 1)
		i = i + width
	end
	return n
end

-- Offsets (1-based) at which each line starts, and the text's line ending
-- stripped lazily by `line`.
local function line_starts(text)
	local starts, pos = { 1 }, 1
	while true do
		local nl = text:find("\n", pos, true)
		if not nl then break end
		starts[#starts + 1] = nl + 1
		pos = nl + 1
	end
	return starts
end

-- ---------------------------------------------------------------------------
-- The open set
-- ---------------------------------------------------------------------------

--- @tparam table opts
-- @tparam function opts.notify `fn(method, params)`: send a notification
-- @tparam[opt] function opts.clock seconds
-- @tparam[opt] number opts.debounce seconds (default `Documents.DEBOUNCE`)
function Documents.new(opts)
	assert(type(opts) == "table" and type(opts.notify) == "function", "Documents.new: opts.notify is required")
	return setmetatable({
		_notify = opts.notify,
		_clock = opts.clock or os.time,
		_debounce = opts.debounce or Documents.DEBOUNCE,
		_docs = {},      -- key -> document
		_count = 0,
		_live = false,   -- is there an initialized server to tell?
		_encoding = "utf-16",
	}, Documents)
end

--- The position encoding agreed with the server (`utf-16` or `utf-8`).
function Documents:setEncoding(encoding)
	self._encoding = encoding == "utf-8" and "utf-8" or "utf-16"
end

function Documents:encoding()
	return self._encoding
end

--- How many documents are open.
function Documents:count()
	return self._count
end

--- The open document for a URI, or nil.
function Documents:get(uri)
	return self._docs[Uri.key(uri)]
end

--- Every open document, in no particular order.
function Documents:all()
	local out = {}
	for _, doc in pairs(self._docs) do out[#out + 1] = doc end
	return out
end

function Documents:_sendOpen(doc)
	doc.version = doc.version + 1
	doc.dirty = false
	doc.sent = true
	self._notify("textDocument/didOpen", {
		textDocument = { uri = doc.uri, languageId = doc.language_id, version = doc.version, text = doc.text },
	})
end

--- Open a document (or replace the text of one already open).
-- @tparam string uri
-- @tparam string language_id the protocol's language id, e.g. `"lua"`
-- @tparam string text
-- @treturn table the document
function Documents:open(uri, language_id, text)
	local key = Uri.key(uri)
	local doc = self._docs[key]
	if doc then
		self:change(uri, text)
		return doc
	end
	doc = { uri = uri, language_id = language_id, text = text or "", version = 0, dirty = false, sent = false }
	self._docs[key] = doc
	self._count = self._count + 1
	if self._live then self:_sendOpen(doc) end
	return doc
end

--- Record new text. It is sent once the document has been quiet for the
-- debounce interval (see `tick`), or at once by `flush`.
function Documents:change(uri, text)
	local doc = self._docs[Uri.key(uri)]
	if not doc or doc.text == text then return doc end
	doc.text = text
	doc._starts = nil
	doc.dirty = true
	doc.due = self._clock() + self._debounce
	return doc
end

function Documents:_sendChange(doc)
	doc.dirty = false
	if not (self._live and doc.sent) then return end
	doc.version = doc.version + 1
	self._notify("textDocument/didChange", {
		textDocument = { uri = doc.uri, version = doc.version },
		contentChanges = Json.array({ { text = doc.text } }),
	})
end

--- Send pending changes now: one document's, or every document's. Call it
-- before a request whose answer depends on the text (hover, completion).
function Documents:flush(uri)
	if uri then
		local doc = self._docs[Uri.key(uri)]
		if doc and doc.dirty then self:_sendChange(doc) end
		return
	end
	for _, doc in pairs(self._docs) do
		if doc.dirty then self:_sendChange(doc) end
	end
end

--- Send the changes whose quiet period has passed.
function Documents:tick()
	local now
	for _, doc in pairs(self._docs) do
		if doc.dirty then
			now = now or self._clock()
			if now >= doc.due then self:_sendChange(doc) end
		end
	end
end

--- Close a document.
function Documents:close(uri)
	local key = Uri.key(uri)
	local doc = self._docs[key]
	if not doc then return false end
	self._docs[key] = nil
	self._count = self._count - 1
	if self._live and doc.sent then
		self._notify("textDocument/didClose", { textDocument = { uri = doc.uri } })
	end
	return true
end

--- Say whether an initialized server is listening. Going live opens every
-- document again with its current text, which is what a restarted server needs.
function Documents:setLive(live)
	live = live == true
	if live == self._live then return end
	self._live = live
	for _, doc in pairs(self._docs) do
		doc.sent = false
		if live then self:_sendOpen(doc) end
	end
end

--- One line of a document's text, without its line ending.
-- @tparam table doc
-- @tparam number line zero-based
-- @treturn string `""` past the end
function Documents.lineOf(doc, line)
	local starts = doc._starts
	if not starts then
		starts = line_starts(doc.text)
		doc._starts = starts
	end
	local from = starts[line + 1]
	if not from then return "" end
	local to = (starts[line + 2] or (#doc.text + 2)) - 2
	local text = doc.text:sub(from, to)
	if text:sub(-1) == "\r" then text = text:sub(1, -2) end
	return text
end

--- A protocol position for a zero-based line and a byte column in it.
-- @treturn table `{ line, character }`
function Documents:toPosition(uri, line, byte_column)
	local doc = self._docs[Uri.key(uri)]
	local text = doc and Documents.lineOf(doc, line) or ""
	return { line = line, character = Documents.byteToCharacter(text, byte_column, self._encoding) }
end

--- The zero-based line and byte column a protocol position names.
-- @treturn number line
-- @treturn number byte column
function Documents:fromPosition(uri, position)
	local doc = self._docs[Uri.key(uri)]
	local line = tonumber(position and position.line) or 0
	local character = tonumber(position and position.character) or 0
	local text = doc and Documents.lineOf(doc, line) or ""
	if not doc then return line, character end
	return line, Documents.characterToByte(text, character, self._encoding)
end

return Documents
