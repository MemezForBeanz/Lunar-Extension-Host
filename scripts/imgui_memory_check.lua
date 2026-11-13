-- Actual host VM checks for native memory ownership and bounded caches.
local B=require('core.imgui.backend.Native')
local json=require('cjson')
local output=assert(io.open(assert(arg[1]),'w'))
local report={}
local ok,err=xpcall(function()
 assert(B.open{title='Lunar memory ownership check',w=320,h=200})
 local windir=os.getenv('WINDIR') or 'C:\\Windows'
 local path=windir..'/Fonts/arial.ttf'
 local face=assert(B.font_load(path))
 local before=B.memory_stats()
 assert(B.font_load(path:upper())==face,'case aliases duplicated font faces')
 local after=B.memory_stats()
 assert(before.font_source_bytes==after.font_source_bytes and before.font_faces==after.font_faces)
 assert(after.font_source_private_bytes==0 and after.font_reference_bytes>after.font_mapped_bytes)
 report.fonts=after
 local texture=assert(B.texture(string.rep('\255\128\0\255',128*128),128,128))
 after=B.memory_stats()
 assert(after.texture_backup_bytes<after.texture_rgba_bytes/2,'solid texture backup was not compacted')
 assert(B.texture_retain(texture))
 B.texture_free(texture)
 B.frame_begin();B.image(texture,20,20,148,148);B.texture_free(texture)
 assert(B.memory_stats().retired_textures==1,'pending draw lost its SRV')
 B.frame_end()
 assert(B.memory_stats().retired_textures==0 and B.memory_stats().textures==0)
 local gid=B.gdi_font('Segoe UI',false,false)
 for size=1,400 do assert(B.gdi_text_size(gid,size,'zoom')>0) end
 assert(B.memory_stats().gdi_font_sizes<=B.memory_stats().gdi_font_size_limit)
 B.frame_begin()
 for i=1,2000 do B.text(0,12,0,-1000,0xffffffff,tostring(i)..string.rep('a',256),0,0,0,320,200,gid) end
 local cache=B.memory_stats()
 assert(cache.glyph_line_bytes<=cache.glyph_line_budget and cache.glyph_line_entries<2000)
 local bytes=cache.glyph_line_bytes
 B.text(0,12,0,-1000,0xffffffff,string.rep('a',100000),0,0,0,320,200,gid)
 assert(B.memory_stats().glyph_line_bytes==bytes,'oversized line entered the cache')
 B.frame_end()
 report.glyph_cache=B.memory_stats()
 B.close()
 assert(B.memory_stats().textures==0 and B.memory_stats().glyph_line_entries==0)
 report.ok=true
end,debug.traceback)
report.error=not ok and tostring(err) or nil
output:write(json.encode(report));output:close();os.exit(ok and 0 or 1)
