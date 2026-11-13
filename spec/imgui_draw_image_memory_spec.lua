local Draw = require("core.imgui.Draw")
local Element = require("core.imgui.Element")
local Fonts = require("core.imgui.Fonts")
local Null = require("core.imgui.backend.Null")
require("core.imgui.widgets.image")

local function image(pixels)
	return Element.new("imagergba", { width = 1, height = 1, pixels = pixels })
end

local function backend()
	local b = { next = 1, uploads = {}, frees = {}, images = {} }
	function b.texture(pixels, w, h)
		local id = b.next
		b.next = id + 1
		b.uploads[#b.uploads + 1] = { id, pixels, w, h }
		return id
	end
	function b.texture_free(id) b.frees[#b.frees + 1] = id end
	function b.image(...) b.images[#b.images + 1] = { ... } end
	return b
end

describe("bounded ImGui draw caches and image textures", function()
	it("reuses the bounded font measurement cache without a per-font string table", function()
		local b = Null.new()
		Fonts.backend = b
		Fonts.reset()
		local font = Fonts.get("Segoe UI, 9")

		Draw.wrap(font, "a long line that needs wrapping", 20)
		assert.is_nil(font._widths)
		local stats = Fonts.measure_cache_stats()
		assert.is_true(stats.entries <= stats.max_entries)
		assert.is_true(stats.bytes <= stats.max_bytes)
	end)

	it("frees replaced textures, retries failed uploads, and retains source pixels", function()
		local b1, b2 = backend(), backend()
		local img = image("\1\2\3\4")

		assert.equal(1, Draw.texture(img, b1))
		Element.setAttribute(img, "PIXELS", "\5\6\7\8")
		assert.same({ 1 }, b1.frees)
		assert.equal("\5\6\7\8", Element.state(img).data.pixels)

		local failed = true
		function b2.texture(pixels, w, h)
			if failed then failed = false; return nil end
			local id = b2.next
			b2.next = id + 1
			b2.uploads[#b2.uploads + 1] = { id, pixels, w, h }
			return id
		end
		assert.is_nil(Draw.texture(img, b2))
		assert.equal("\5\6\7\8", Element.state(img).data.pixels)
		assert.is_not_nil(Draw.texture(img, b2))

		assert.equal(1, #b1.frees)
		Element.destroy(img)
		assert.same({ 1 }, b2.frees)
	end)

	it("keeps the existing recorded image command shape", function()
		local b = backend()
		local img = image("\1\2\3\4")
		local dc = Draw.new(b)
		dc:begin(10, 10)
		dc:record(true)
		dc:image(img, 1, 2, 3, 4)
		local list = dc:stop()

		assert.equal("image", list[1][1])
		assert.equal(1, list[1][2])
		assert.equal(1, #b.images)
		assert.equal(1, b.images[1][1])
	end)

	it("keeps a recorded texture alive after its image owner changes", function()
		local b = backend(); local refs = {}
		local upload = b.texture
		function b.texture(...) local id=upload(...);refs[id]=1;return id end
		function b.texture_retain(id) if refs[id] then refs[id]=refs[id]+1;return true end end
		function b.texture_free(id) refs[id]=refs[id]-1;if refs[id]==0 then refs[id]=nil end end
		local img=image("\1\2\3\4");local dc=Draw.new(b)
		dc:record(false);dc:image(img,0,0,1,1);local recording=dc:stop()
		assert.equal(2,refs[1]);img.PIXELS="\5\6\7\8";assert.equal(1,refs[1])
		dc:replay(recording);assert.equal(1,b.images[1][1])
		Draw.releaseRecording(recording);assert.is_nil(refs[1])
		Draw.releaseRecording(recording)
		Element.destroy(img)
	end)

	it("bounds provider uploads by bytes and keeps a large live image usable", function()
		local b=backend()
		function b.texture_bits(...) return b.texture(...) end
		Draw.bitsTexture(b,"first",1024,1024)
		Draw.bitsTexture(b,"second",1024,1024)
		local stats=Draw.bitsCacheStats(b)
		assert.equal(1,stats.entries);assert.is_true(stats.bytes<=stats.max_bytes)
		assert.same({1},b.frees)
		Draw.bitsTexture(b,"large",2048,2048)
		stats=Draw.bitsCacheStats(b)
		assert.equal(1,stats.entries);assert.is_true(stats.bytes>stats.max_bytes)
		assert.equal(3,Draw.bitsTexture(b,"large",2048,2048))
		Draw.clearBitsCache(b);assert.equal(0,Draw.bitsCacheStats(b).entries)
		assert.same({1,2,3},b.frees)
	end)

	it("releases runtime roots and textures on close, then can reopen", function()
		local Runtime=require("core.imgui.Runtime")
		local iup=require("core.imgui.iup")
		local b=Null.new();Runtime.init(b)
		local img=image("\1\2\3\4");Draw.texture(img,b)
		local button=iup.flatbutton{TITLE="owned"};local dialog=iup.dialog{button}
		Runtime.show(dialog)
		Runtime.close();Runtime.close()
		assert.is_nil(Element.state(dialog));assert.is_nil(Element.state(button))
		assert.equal(0,#Runtime.dialogs());assert.is_nil(Runtime.mainDialog())
		assert.is_nil(Element.state(img).data.tex)
		Runtime.init(b);assert.is_not_nil(Draw.texture(img,b));Element.destroy(img)
		Runtime.close()
	end)

	it("closes compositor handles and releases scenes when their owner dies", function()
		local Runtime=require("core.imgui.Runtime")
		local iup=require("core.imgui.iup")
		Runtime.init(Null.new())
		local dialog=iup.dialog{iup.label{TITLE="owner"}}
		local overlay=assert(require("core.imgui.native.compositor").overlay(dialog))
		overlay:present({{kind="fill",x=0,y=0,w=1,h=1,color="0 0 0"}})
		local handle=overlay.handle;assert.is_true(handle:isOpen())
		Element.destroy(dialog)
		assert.is_false(handle:isOpen());assert.is_false(overlay:isOpen())
		assert.is_nil(overlay.scene);assert.equal(0,#Runtime.overlays())
		Runtime.close()
	end)
end)
