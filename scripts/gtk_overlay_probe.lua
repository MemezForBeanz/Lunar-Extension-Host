-- scripts/gtk_overlay_probe.lua — GTK/X11 compositor backend probe (Linux only).
--
-- Answers, on a real IUP dialog, the questions the compositor design leaves open
-- for GTK (vault: 02 Design/Compositor Design.md):
--   * does a translucent frame blend over native GTK widgets AND IUP's flat
--     controls (canvases with their own X windows)?  -- in two overlay modes:
--       native:     the overlay is its own X window, raised above everything
--       windowless: the overlay draws into the dialog's window
--       backdrop:   native, but each frame is composited over a capture of the
--                   page beneath it, and the window's bounding shape is limited
--                   to the sprites' area so the live page shows everywhere else
--   * does an input shape make the overlay click-through except action regions?
--   * does the overlay follow a resize, stay out of snapshots, and tear down?
--   * what does a frame cost (render + present)?
--
-- Run:  build/linux/bin/LunarExtensionHost scripts/gtk_overlay_probe.lua <out_dir> [native|windowless|backdrop] [WxH] [interactive]
--   WxH          dialog size (default 520x360), to measure frame cost at real window sizes
--   interactive  after the checks, keep a toast up for 40 s and log real clicks: the
--                native button under the click-through area, and the toast's close button
-- Writes <out_dir>/probe-<mode>-*.png from the overlay's own pixels and prints results.
-- Screen-level checks (what the user sees) are taken by the caller with xwd.

local iup = require("iup")
local ffi = require("ffi")
local compositor = require("compositor")

local out_dir = arg and arg[1] or "/tmp"
local mode = arg and arg[2] or "native"
local dialog_size = arg and arg[3] or "520x360"
local interactive = arg and arg[4] == "interactive"

ffi.cdef[[
typedef struct _GtkWidget GtkWidget;
typedef struct _GdkWindow GdkWindow;
typedef struct _cairo cairo_t;
typedef struct _cairo_surface cairo_surface_t;
typedef struct _cairo_region cairo_region_t;
typedef struct { int x, y, width, height; } GtkAllocation;
typedef void (*GCallback)(void);
typedef int (*draw_cb_t)(GtkWidget *, cairo_t *, void *);
typedef void (*alloc_cb_t)(GtkWidget *, GtkAllocation *, void *);
GtkWidget *gtk_bin_get_child(GtkWidget *bin);
GtkWidget *gtk_drawing_area_new(void);
void gtk_fixed_put(GtkWidget *fixed, GtkWidget *w, int x, int y);
void gtk_widget_set_size_request(GtkWidget *w, int width, int height);
void gtk_widget_size_allocate(GtkWidget *w, GtkAllocation *a);
void gtk_widget_show(GtkWidget *w);
void gtk_widget_destroy(GtkWidget *w);
void gtk_widget_set_has_window(GtkWidget *w, int has);
int gtk_widget_get_has_window(GtkWidget *w);
void gtk_widget_set_child_visible(GtkWidget *w, int visible);
void gtk_widget_draw(GtkWidget *w, cairo_t *cr);
void gtk_widget_get_allocation(GtkWidget *w, GtkAllocation *a);
GdkWindow *gtk_widget_get_window(GtkWidget *w);
void gtk_widget_input_shape_combine_region(GtkWidget *w, cairo_region_t *r);
void gtk_widget_shape_combine_region(GtkWidget *w, cairo_region_t *r);
int gtk_widget_translate_coordinates(GtkWidget *src, GtkWidget *dest, int sx, int sy, int *dx, int *dy);
void g_signal_handler_disconnect(void *instance, unsigned long id);
void gtk_widget_add_events(GtkWidget *w, int events);
typedef int (*button_cb_t)(GtkWidget *, void *event, void *);
void gtk_widget_queue_draw(GtkWidget *w);
int gdk_window_ensure_native(GdkWindow *w);
void gdk_window_raise(GdkWindow *w);
void gdk_window_invalidate_rect(GdkWindow *w, void *rect, int children);
void gdk_window_process_updates(GdkWindow *w, int children);
unsigned long gdk_x11_window_get_xid(GdkWindow *w);
void *gdk_window_get_display(GdkWindow *w);
void *gdk_x11_display_get_xdisplay(void *display);
unsigned long g_signal_connect_data(void *instance, const char *signal, GCallback cb, void *data, void *destroy, int flags);
cairo_surface_t *cairo_image_surface_create(int format, int w, int h);
cairo_surface_t *cairo_image_surface_create_for_data(unsigned char *data, int format, int w, int h, int stride);
unsigned char *cairo_image_surface_get_data(cairo_surface_t *s);
int cairo_image_surface_get_stride(cairo_surface_t *s);
void cairo_surface_flush(cairo_surface_t *s);
void cairo_surface_destroy(cairo_surface_t *s);
cairo_t *cairo_create(cairo_surface_t *s);
void cairo_destroy(cairo_t *cr);
void cairo_set_source_surface(cairo_t *cr, cairo_surface_t *s, double x, double y);
void cairo_set_operator(cairo_t *cr, int op);
void cairo_paint(cairo_t *cr);
int cairo_surface_write_to_png(cairo_surface_t *s, const char *file);
cairo_region_t *cairo_region_create(void);
cairo_region_t *cairo_region_create_rectangle(const GtkAllocation *rect);
int cairo_region_union_rectangle(cairo_region_t *r, const GtkAllocation *rect);
void cairo_region_destroy(cairo_region_t *r);
typedef struct { short x, y; unsigned short width, height; } XRectangle;
XRectangle *XShapeGetRectangles(void *dpy, unsigned long window, int kind, int *count, int *ordering);
int XFree(void *data);
]]
local C = ffi.C
local CAIRO_FORMAT_ARGB32, CAIRO_OPERATOR_SOURCE, CAIRO_OPERATOR_OVER = 0, 1, 2
local SHAPE_INPUT = 2

local results = {}
local function report(name, ok, detail)
	results[#results + 1] = { name = name, ok = ok }
	io.stdout:write(string.format("[%s] %s%s\n", ok and "PASS" or "FAIL", name, detail and (" -- " .. tostring(detail)) or ""))
	io.stdout:flush()
end
local function info(...) io.stdout:write("[info] ", table.concat({ ... }, " "), "\n"); io.stdout:flush() end

-- A page with every kind of widget Lunar's UI uses.
local page = iup.vbox{
	iup.label{ title = "Native label" },
	iup.button{ title = "Native button", rastersize = "160x30",
		action = function() io.stdout:write("CLICK native button (passed through the overlay)\n"); io.stdout:flush() end },
	iup.text{ value = "native entry", expand = "HORIZONTAL" },
	iup.flatbutton{ title = "Flat button", CORNERRADIUS = "8", GRADIENTCOLOR = "0 120 255",
		BGCOLOR = "60 60 60", fgcolor = "255 255 255", rastersize = "160x34" },
	iup.flatlabel{ title = "Flat label (canvas)", bgcolor = "200 200 200", rastersize = "200x24" },
	iup.list{ "one", "two", "three"; expand = "YES" },
	margin = "16x16", gap = "8",
}
local dlg = iup.dialog{ page, title = "GTK overlay probe (" .. mode .. ")", rastersize = dialog_size, bgcolor = "240 240 240" }
dlg:showxy(iup.CENTER, iup.CENTER)

local window = ffi.cast("GtkWidget *", iup.GetAttribute(dlg, "WID"))
local fixed = C.gtk_bin_get_child(window)
local da = C.gtk_drawing_area_new()

-- The overlay's frame: a cairo surface the blend core renders into.
local frame = { surface = nil, w = 0, h = 0, keep = nil }
local function frame_from(buffer)
	-- compositor buffers are top-down premultiplied BGRA, stride w*4: the same
	-- memory as cairo ARGB32 on little-endian, so they can be wrapped directly.
	local bytes = buffer:bytes()
	if frame.surface ~= nil then C.cairo_surface_destroy(frame.surface) end
	frame.keep = bytes   -- keep the Lua string alive while cairo points at it
	frame.surface = C.cairo_image_surface_create_for_data(ffi.cast("unsigned char *", bytes),
		CAIRO_FORMAT_ARGB32, buffer.w, buffer.h, buffer.w * 4)
	frame.w, frame.h = buffer.w, buffer.h
end

local draw_cb = ffi.cast("draw_cb_t", function(_, cr)
	if frame.surface == nil then return 0 end
	-- native mode: our own X window starts undefined, so replace (SOURCE);
	-- windowless: blend over what the dialog already drew (OVER).
	C.cairo_set_operator(cr, mode == "windowless" and CAIRO_OPERATOR_OVER or CAIRO_OPERATOR_SOURCE)
	C.cairo_set_source_surface(cr, frame.surface, 0, 0)
	C.cairo_paint(cr)
	return 0
end)
C.g_signal_connect_data(da, "draw", ffi.cast("GCallback", draw_cb), nil, nil, 0)
-- Clicks that land on the overlay: only possible inside its input shape.
local GDK_BUTTON_PRESS_MASK = 256
C.gtk_widget_add_events(da, GDK_BUTTON_PRESS_MASK)
local press_cb = ffi.cast("button_cb_t", function()
	io.stdout:write("CLICK toast close button (overlay action region)\n"); io.stdout:flush()
	return 1
end)
C.g_signal_connect_data(da, "button-press-event", ffi.cast("GCallback", press_cb), nil, nil, 0)

local alloc = ffi.new("GtkAllocation")
local function cover_size()
	C.gtk_widget_get_allocation(fixed, alloc)
	return alloc.width, alloc.height
end
-- Follow the cover: GtkFixed doesn't stretch children. Run AFTER the fixed has
-- allocated its children (G_CONNECT_AFTER), then allocate the overlay to the
-- new size directly; a size request alone only lands on the next layout pass,
-- leaving the overlay a frame behind (a strip of undimmed page).
local G_CONNECT_AFTER = 1
local resize_count = 0
local alloc_cb = ffi.cast("alloc_cb_t", function(_, a)
	resize_count = resize_count + 1
	C.gtk_widget_set_size_request(da, a.width, a.height)
	C.gtk_widget_size_allocate(da, ffi.new("GtkAllocation", 0, 0, a.width, a.height))
end)
local alloc_handler = C.g_signal_connect_data(fixed, "size-allocate", ffi.cast("GCallback", alloc_cb), nil, nil, G_CONNECT_AFTER)

if mode == "windowless" then C.gtk_widget_set_has_window(da, 0) end
C.gtk_fixed_put(fixed, da, 0, 0)
local w0, h0 = cover_size()
C.gtk_widget_set_size_request(da, w0, h0)
C.gtk_widget_show(da)
iup.Flush()

local gdkwin = C.gtk_widget_get_window(da)
if mode ~= "windowless" then
	report("ensure_native", C.gdk_window_ensure_native(gdkwin) ~= 0)
	C.gdk_window_raise(gdkwin)
end
info("mode", mode, "overlay has own window:", tostring(C.gtk_widget_get_has_window(da)), "cover", w0 .. "x" .. h0)

-- Input: only action regions take clicks; everything else passes through.
local function set_input_regions(regions)
	local region = C.cairo_region_create()
	for _, r in ipairs(regions) do
		C.cairo_region_union_rectangle(region, ffi.new("GtkAllocation", r.x, r.y, r.w, r.h))
	end
	C.gtk_widget_input_shape_combine_region(da, region)
	C.cairo_region_destroy(region)
end
local function x_input_rects()
	local win = C.gtk_widget_get_window(da)
	if mode == "windowless" then return nil end
	local dpy = C.gdk_x11_display_get_xdisplay(C.gdk_window_get_display(win))
	local count, ordering = ffi.new("int[1]"), ffi.new("int[1]")
	local rects = C.XShapeGetRectangles(dpy, C.gdk_x11_window_get_xid(win), SHAPE_INPUT, count, ordering)
	local out = {}
	for i = 0, count[0] - 1 do out[#out + 1] = { rects[i].x, rects[i].y, rects[i].width, rects[i].height } end
	if rects ~= nil then C.XFree(rects) end
	return out
end

local snapshot   -- defined below; present() needs it in backdrop mode

-- Union of the sprites' rectangles (clipped to the scene): where the overlay
-- window exists at all in backdrop mode.
local function sprite_bounds(scene)
	local region = C.cairo_region_create()
	for _, sp in ipairs(scene) do
		C.cairo_region_union_rectangle(region, ffi.new("GtkAllocation", sp.x, sp.y, sp.w, sp.h))
	end
	return region
end

local capture_ms = 0
local function present(scene)
	local t0 = os.clock()
	if mode == "backdrop" then
		-- The page beneath, as the bottom layer, so translucent pixels blend
		-- with what is really there (X doesn't blend a child window for us).
		local surface, w, h = snapshot()
		local data = C.cairo_image_surface_get_data(surface)
		local snap = compositor.image(w, h, ffi.string(data, w * h * 4))
		C.cairo_surface_destroy(surface)
		local framed = { w = scene.w, h = scene.h,
			{ kind = "image", snap = snap, x = 0, y = 0, sx = 0, sy = 0,
				sw = math.min(w, scene.w), sh = math.min(h, scene.h), alpha = 1 } }
		for _, sp in ipairs(scene) do framed[#framed + 1] = sp end
		local region = sprite_bounds(scene)
		C.gtk_widget_shape_combine_region(da, region)
		C.cairo_region_destroy(region)
		capture_ms = (os.clock() - t0) * 1000
		scene = framed
		t0 = os.clock()
	end
	local buffer = compositor.render(scene)
	local t1 = os.clock()
	frame_from(buffer)
	local win = C.gtk_widget_get_window(da)
	C.gdk_window_invalidate_rect(win, nil, 0)
	C.gdk_window_process_updates(win, 0)
	return (t1 - t0) * 1000, (os.clock() - t1) * 1000
end

-- Capture the cover without the overlay in it.
-- Drawn from the toplevel (GtkFixed doesn't paint the window background),
-- translated so the cover's origin lands at (0,0).
local cairo_translate = (function()
	pcall(ffi.cdef, "void cairo_translate(cairo_t *cr, double tx, double ty);")
	return C.cairo_translate
end)()
function snapshot()
	local w, h = cover_size()
	local surface = C.cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h)
	local cr = C.cairo_create(surface)
	local ox, oy = ffi.new("int[1]"), ffi.new("int[1]")
	C.gtk_widget_translate_coordinates(fixed, window, 0, 0, ox, oy)
	cairo_translate(cr, -ox[0], -oy[0])
	C.gtk_widget_set_child_visible(da, 0)
	C.gtk_widget_draw(window, cr)
	C.gtk_widget_set_child_visible(da, 1)
	C.cairo_destroy(cr)
	C.cairo_surface_flush(surface)
	return surface, w, h
end
local function surface_pixel(surface, w, x, y)
	local data = C.cairo_image_surface_get_data(surface)
	local stride = C.cairo_image_surface_get_stride(surface)
	local p = data + y * stride + x * 4
	local _ = w
	return p[0], p[1], p[2], p[3]
end

local steps = {}
local function step(fn) steps[#steps + 1] = fn end

-- 1. Snapshot first (no overlay content yet), and prove the overlay isn't in it.
local snap_surface, snap_w
step(function()
	present({ w = w0, h = h0, { kind = "fill", x = 0, y = 0, w = w0, h = h0, color = 0xff00ff, alpha = 1 } })
	snap_surface, snap_w = snapshot()
	C.cairo_surface_write_to_png(snap_surface, out_dir .. "/probe-" .. mode .. "-snapshot.png")
	local b, g, r = surface_pixel(snap_surface, snap_w, 5, 5)
	report("snapshot excludes the overlay (no magenta)", not (r == 255 and g == 0 and b == 255),
		string.format("pixel(5,5) = %d,%d,%d", r, g, b))
end)

-- 2. A translucent scrim: 50% black over the live page.
step(function()
	local w, h = cover_size()
	local render_ms, present_ms = present({ w = w, h = h,
		{ kind = "fill", x = 0, y = 0, w = w, h = h, color = 0x000000, alpha = 0.5 } })
	info(string.format("scrim frame %dx%d: capture %.2f ms, render %.2f ms, present %.2f ms", w, h, capture_ms, render_ms, present_ms))
	set_input_regions({})
	local rects = x_input_rects()
	if rects then report("passthrough: X input shape is empty", #rects == 0, #rects .. " rects") end
	io.stdout:write("SHOT scrim\n"); io.stdout:flush()
end)

-- 3. Scrim plus a toast whose close button is an action region.
step(function()
	local w, h = cover_size()
	present({ w = w, h = h,
		{ kind = "fill", x = 0, y = 0, w = w, h = h, color = 0x000000, alpha = 0.3 },
		{ kind = "rrect", x = w - 230, y = h - 70, w = 210, h = 50, radius = 8, color = 0x262626, alpha = 0.97 },
		{ kind = "fill", x = w - 50, y = h - 58, w = 24, h = 24, color = 0xda1e28, alpha = 1 } })
	set_input_regions({ { x = w - 50, y = h - 58, w = 24, h = 24 } })
	local rects = x_input_rects()
	if rects then
		local r = rects[1]
		report("action region: X input shape is exactly the close button",
			#rects == 1 and r[1] == w - 50 and r[2] == h - 58 and r[3] == 24 and r[4] == 24,
			#rects .. " rects" .. (r and string.format(" first %d,%d %dx%d", r[1], r[2], r[3], r[4]) or ""))
	end
	io.stdout:write("SHOT toast\n"); io.stdout:flush()
end)

-- 4. Resize the dialog (applied by IUP on a later tick), then check the overlay followed.
local resize_before
step(function()
	resize_before = resize_count
	iup.SetAttribute(dlg, "RASTERSIZE", "640x420")
	iup.Refresh(dlg)
end)
step(function()
	local before = resize_before
	local w, h = cover_size()
	present({ w = w, h = h, { kind = "fill", x = 0, y = 0, w = w, h = h, color = 0x000000, alpha = 0.5 } })
	local da_alloc = ffi.new("GtkAllocation")
	C.gtk_widget_get_allocation(da, da_alloc)
	report("overlay follows a resize", resize_count > before and da_alloc.width == w and da_alloc.height == h,
		string.format("cover %dx%d overlay %dx%d", w, h, da_alloc.width, da_alloc.height))
	io.stdout:write("SHOT resized\n"); io.stdout:flush()
end)

-- 5. Frame cost of a 60-frame fade at the current size.
step(function()
	local w, h = cover_size()
	local total_r, total_p = 0, 0
	for i = 1, 60 do
		local r, p = present({ w = w, h = h,
			{ kind = "fill", x = 0, y = 0, w = w, h = h, color = 0x000000, alpha = i / 120 } })
		total_r, total_p = total_r + r, total_p + p
	end
	info(string.format("fade 60 frames at %dx%d: render %.2f ms/frame, present %.2f ms/frame (CPU)%s", w, h, total_r / 60, total_p / 60,
		mode == "backdrop" and string.format(", last capture %.2f ms", capture_ms) or ""))
end)

-- 5b. Interactive: a toast with a live close button over a passthrough page.
if interactive then
	step(function()
		local w, h = cover_size()
		present({ w = w, h = h,
			{ kind = "rrect", x = w - 230, y = h - 70, w = 210, h = 50, radius = 8, color = 0x262626, alpha = 0.97 },
			{ kind = "fill", x = w - 50, y = h - 58, w = 24, h = 24, color = 0xda1e28, alpha = 1 } })
		set_input_regions({ { x = w - 50, y = h - 58, w = 24, h = 24 } })
		io.stdout:write("INTERACTIVE: click 'Native button', type in the entry, then click the red square (40 s)\n")
		io.stdout:flush()
	end)
	for _ = 1, 26 do step(function() end) end   -- ~40 s at 1.5 s per tick
end

-- 6. Teardown: destroy the overlay, then close.
step(function()
	-- Disconnect first: the dialog outlives the overlay and keeps allocating.
	C.g_signal_handler_disconnect(fixed, alloc_handler)
	C.gtk_widget_destroy(da)
	if frame.surface ~= nil then C.cairo_surface_destroy(frame.surface); frame.surface = nil end
	C.cairo_surface_destroy(snap_surface)
	report("overlay destroyed while the dialog lives", true)
end)

-- Run one step per timer tick so GTK can lay out and paint between them; the
-- caller takes a screenshot after each SHOT line (1.5 s per step).
local i = 0
local timer = iup.timer{ time = 1500 }
function timer:action_cb()
	i = i + 1
	if steps[i] then
		local ok, err = pcall(steps[i])
		if not ok then report("step " .. i, false, err) end
		return iup.DEFAULT
	end
	self.run = "NO"
	local failed = 0
	for _, r in ipairs(results) do if not r.ok then failed = failed + 1 end end
	io.stdout:write(failed == 0 and "ALL PASSED\n" or (failed .. " FAILED\n")); io.stdout:flush()
	return iup.CLOSE
end
timer.run = "YES"
iup.MainLoop()
