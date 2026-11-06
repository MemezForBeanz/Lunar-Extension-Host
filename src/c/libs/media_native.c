/* media_native: posters decoded on worker threads, kept in a bounded cache the UI thread owns.
 *
 * Threading rule: workers never touch Lua or the cache. They take a job, decode and scale it
 * with no lock held, and leave the pixels in a ring. The UI thread empties the ring from a host
 * timer (cache:drain) and is the only thread that reads the cache or frees pixels, so a pointer
 * from cache:get stays valid until the next drain, forget, clear or close on that same thread.
 *
 * Jobs run newest first and the queue is bounded: while the user flings through a long list,
 * what is on screen now wins and what scrolled past is dropped unstarted. The Lua API is
 * documented in src/lua/core/ui/PosterCache.lua. */
#include <lua.h>
#include <lauxlib.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>

#ifdef _WIN32
#undef _WIN32_WINNT
#define _WIN32_WINNT 0x0601
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <wincodec.h>
typedef CRITICAL_SECTION media_lock;
typedef CONDITION_VARIABLE media_cond;
typedef HANDLE media_thread;
#define lock_init(l) InitializeCriticalSection(l)
#define lock_free(l) DeleteCriticalSection(l)
#define lock_take(l) EnterCriticalSection(l)
#define lock_give(l) LeaveCriticalSection(l)
#define cond_init(c) InitializeConditionVariable(c)
#define cond_free(c) ((void)0)
#define cond_wait(c, l) SleepConditionVariableCS(c, l, INFINITE)
#define cond_one(c) WakeConditionVariable(c)
#define cond_all(c) WakeAllConditionVariable(c)
#else
#include <pthread.h>
#include <gdk-pixbuf/gdk-pixbuf.h>
typedef pthread_mutex_t media_lock;
typedef pthread_cond_t media_cond;
typedef pthread_t media_thread;
#define lock_init(l) pthread_mutex_init(l, NULL)
#define lock_free(l) pthread_mutex_destroy(l)
#define lock_take(l) pthread_mutex_lock(l)
#define lock_give(l) pthread_mutex_unlock(l)
#define cond_init(c) pthread_cond_init(c, NULL)
#define cond_free(c) pthread_cond_destroy(c)
#define cond_wait(c, l) pthread_cond_wait(c, l)
#define cond_one(c) pthread_cond_signal(c)
#define cond_all(c) pthread_cond_broadcast(c)
#endif

#define CACHE_META "lunar.media_native.cache"
#define BUCKETS 8192
#define RING_SIZE 64
#define MAX_THREADS 8
#define MAX_SIDE 4096
#define ERROR_SIZE 96

enum { STATE_QUEUED, STATE_READY, STATE_FAILED };

typedef struct Entry {
    char *key;
    unsigned hash;
    struct Entry *chain, *newer, *older;
    unsigned char *pixels;
    int width, height, stride, state;
    size_t bytes;
    char *error;
} Entry;

typedef struct Job {
    char *key, *path;
    unsigned char *data;
    size_t size;
    int width, height;
    struct Job *newer, *older;
} Job;

typedef struct Done {
    char *key;
    unsigned char *pixels;
    int width, height, stride;
    char error[ERROR_SIZE];
} Done;

typedef struct Cache {
    /* UI thread only */
    Entry *buckets[BUCKETS];
    Entry *newest, *oldest;  /* ready entries, most recently used first */
    size_t used, max_bytes, dropped, entries;
    int closed, threads;
    media_thread thread[MAX_THREADS];
    /* under lock */
    media_lock lock;
    media_cond work, room;
    Job *jobs_newest, *jobs_oldest;
    int queued, max_queued, closing;
    Done ring[RING_SIZE];
    unsigned ring_read, ring_write;
} Cache;

static unsigned hash_key(const char *key)
{
    unsigned h = 2166136261u;
    for (; *key; key++) { h ^= (unsigned char)*key; h *= 16777619u; }
    return h;
}

static char *copy_text(const char *text)
{
    size_t size = strlen(text) + 1;
    char *copy = (char *)malloc(size);
    if (copy) memcpy(copy, text, size);
    return copy;
}

/* ---- decoding: no lock held, no Lua ------------------------------------------------------ */

#ifdef _WIN32
static int decode(void *factory_ptr, const Job *job, Done *done)
{
    IWICImagingFactory *factory = (IWICImagingFactory *)factory_ptr;
    IWICBitmapDecoder *decoder = NULL;
    IWICBitmapFrameDecode *frame = NULL;
    IWICBitmapScaler *scaler = NULL;
    IWICBitmapClipper *clipper = NULL;
    IWICFormatConverter *converter = NULL;
    IWICStream *stream = NULL;
    UINT source_w = 0, source_h = 0, scaled_w, scaled_h;
    WICRect crop;
    double scale;
    HRESULT hr;
    int stride = job->width * 4;
    unsigned char *pixels = NULL;
    const char *step = "open";

    if (job->path) {
        WCHAR wide[1024];
        if (!MultiByteToWideChar(CP_UTF8, 0, job->path, -1, wide, 1024)) {
            snprintf(done->error, ERROR_SIZE, "path too long");
            return 0;
        }
        hr = IWICImagingFactory_CreateDecoderFromFilename(factory, wide, NULL, GENERIC_READ,
            WICDecodeMetadataCacheOnDemand, &decoder);
    } else {
        hr = IWICImagingFactory_CreateStream(factory, &stream);
        if (SUCCEEDED(hr)) hr = IWICStream_InitializeFromMemory(stream, job->data, (DWORD)job->size);
        if (SUCCEEDED(hr)) hr = IWICImagingFactory_CreateDecoderFromStream(factory, (IStream *)stream, NULL,
            WICDecodeMetadataCacheOnDemand, &decoder);
    }
    if (SUCCEEDED(hr)) { step = "decode"; hr = IWICBitmapDecoder_GetFrame(decoder, 0, &frame); }
    if (SUCCEEDED(hr)) hr = IWICBitmapFrameDecode_GetSize(frame, &source_w, &source_h);
    if (SUCCEEDED(hr) && (!source_w || !source_h)) hr = E_FAIL;
    if (SUCCEEDED(hr)) {
        /* Cover the cell and crop the overflow, so no cell ever shows a letterbox. */
        double sx = (double)job->width / source_w, sy = (double)job->height / source_h;
        scale = sx > sy ? sx : sy;
        scaled_w = (UINT)ceil(source_w * scale);
        scaled_h = (UINT)ceil(source_h * scale);
        if (scaled_w < (UINT)job->width) scaled_w = job->width;
        if (scaled_h < (UINT)job->height) scaled_h = job->height;
        step = "scale";
        hr = IWICImagingFactory_CreateBitmapScaler(factory, &scaler);
    }
    if (SUCCEEDED(hr)) hr = IWICBitmapScaler_Initialize(scaler, (IWICBitmapSource *)frame, scaled_w, scaled_h,
        WICBitmapInterpolationModeFant);
    if (SUCCEEDED(hr)) hr = IWICImagingFactory_CreateBitmapClipper(factory, &clipper);
    if (SUCCEEDED(hr)) {
        crop.X = (INT)(scaled_w - job->width) / 2;
        crop.Y = (INT)(scaled_h - job->height) / 2;
        crop.Width = job->width;
        crop.Height = job->height;
        hr = IWICBitmapClipper_Initialize(clipper, (IWICBitmapSource *)scaler, &crop);
    }
    if (SUCCEEDED(hr)) { step = "convert"; hr = IWICImagingFactory_CreateFormatConverter(factory, &converter); }
    if (SUCCEEDED(hr)) hr = IWICFormatConverter_Initialize(converter, (IWICBitmapSource *)clipper,
        &GUID_WICPixelFormat32bppPBGRA, WICBitmapDitherTypeNone, NULL, 0.0, WICBitmapPaletteTypeCustom);
    if (SUCCEEDED(hr)) {
        pixels = (unsigned char *)malloc((size_t)stride * job->height);
        if (!pixels) hr = E_OUTOFMEMORY;
    }
    if (SUCCEEDED(hr)) hr = IWICFormatConverter_CopyPixels(converter, NULL, stride, (UINT)stride * job->height, pixels);

    if (converter) IWICFormatConverter_Release(converter);
    if (clipper) IWICBitmapClipper_Release(clipper);
    if (scaler) IWICBitmapScaler_Release(scaler);
    if (frame) IWICBitmapFrameDecode_Release(frame);
    if (decoder) IWICBitmapDecoder_Release(decoder);
    if (stream) IWICStream_Release(stream);
    if (FAILED(hr)) {
        free(pixels);
        snprintf(done->error, ERROR_SIZE, "%s failed (0x%08lx)", step, (unsigned long)hr);
        return 0;
    }
    done->pixels = pixels;
    done->width = job->width;
    done->height = job->height;
    done->stride = stride;
    return 1;
}
#else
static int decode(void *unused, const Job *job, Done *done)
{
    GError *error = NULL;
    GdkPixbuf *source = NULL, *scaled;
    int source_w, source_h, scaled_w, scaled_h, x, y, stride = job->width * 4;
    double sx, sy, scale;
    unsigned char *pixels;
    (void)unused;
    if (job->path) source = gdk_pixbuf_new_from_file(job->path, &error);
    else {
        GdkPixbufLoader *loader = gdk_pixbuf_loader_new();
        if (gdk_pixbuf_loader_write(loader, job->data, job->size, &error) && gdk_pixbuf_loader_close(loader, &error)) {
            source = gdk_pixbuf_loader_get_pixbuf(loader);
            if (source) g_object_ref(source);
        }
        g_object_unref(loader);
    }
    if (!source) {
        snprintf(done->error, ERROR_SIZE, "%s", error ? error->message : "decode failed");
        if (error) g_error_free(error);
        return 0;
    }
    source_w = gdk_pixbuf_get_width(source);
    source_h = gdk_pixbuf_get_height(source);
    sx = (double)job->width / source_w;
    sy = (double)job->height / source_h;
    scale = sx > sy ? sx : sy;
    scaled_w = (int)ceil(source_w * scale);
    scaled_h = (int)ceil(source_h * scale);
    if (scaled_w < job->width) scaled_w = job->width;
    if (scaled_h < job->height) scaled_h = job->height;
    scaled = gdk_pixbuf_scale_simple(source, scaled_w, scaled_h, GDK_INTERP_HYPER);
    g_object_unref(source);
    pixels = scaled ? (unsigned char *)malloc((size_t)stride * job->height) : NULL;
    if (!pixels) {
        if (scaled) g_object_unref(scaled);
        snprintf(done->error, ERROR_SIZE, "scale failed");
        return 0;
    }
    {
        const unsigned char *from = gdk_pixbuf_get_pixels(scaled);
        int from_stride = gdk_pixbuf_get_rowstride(scaled), channels = gdk_pixbuf_get_n_channels(scaled);
        int crop_x = (scaled_w - job->width) / 2, crop_y = (scaled_h - job->height) / 2;
        for (y = 0; y < job->height; y++) {
            const unsigned char *in = from + (size_t)(y + crop_y) * from_stride + (size_t)crop_x * channels;
            unsigned char *out = pixels + (size_t)y * stride;
            for (x = 0; x < job->width; x++, in += channels, out += 4) {
                unsigned a = channels == 4 ? in[3] : 255;
                out[0] = (unsigned char)(in[2] * a / 255);
                out[1] = (unsigned char)(in[1] * a / 255);
                out[2] = (unsigned char)(in[0] * a / 255);
                out[3] = (unsigned char)a;
            }
        }
    }
    g_object_unref(scaled);
    done->pixels = pixels;
    done->width = job->width;
    done->height = job->height;
    done->stride = stride;
    return 1;
}
#endif

/* ---- workers ------------------------------------------------------------------------------ */

static void job_free(Job *job)
{
    free(job->key);
    free(job->path);
    free(job->data);
    free(job);
}

/* Lock held. */
static void job_unlink(Cache *cache, Job *job)
{
    if (job->newer) job->newer->older = job->older; else cache->jobs_newest = job->older;
    if (job->older) job->older->newer = job->newer; else cache->jobs_oldest = job->newer;
    cache->queued--;
}

static void worker_loop(Cache *cache, void *factory)
{
    for (;;) {
        Job *job;
        Done done;
        lock_take(&cache->lock);
        while (!cache->jobs_newest && !cache->closing) cond_wait(&cache->work, &cache->lock);
        if (cache->closing) { lock_give(&cache->lock); return; }
        job = cache->jobs_newest;
        job_unlink(cache, job);
        lock_give(&cache->lock);

        memset(&done, 0, sizeof(done));
        if (!factory) snprintf(done.error, ERROR_SIZE, "no image decoder on this thread");
        else decode(factory, job, &done);
        done.key = job->key;
        job->key = NULL;
        job_free(job);

        lock_take(&cache->lock);
        while (cache->ring_write - cache->ring_read == RING_SIZE && !cache->closing)
            cond_wait(&cache->room, &cache->lock);
        if (cache->closing) {
            lock_give(&cache->lock);
            free(done.key);
            free(done.pixels);
            return;
        }
        cache->ring[cache->ring_write++ % RING_SIZE] = done;
        lock_give(&cache->lock);
    }
}

#ifdef _WIN32
static DWORD WINAPI worker_main(LPVOID arg)
{
    IWICImagingFactory *factory = NULL;
    HRESULT init = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (SUCCEEDED(init))
        CoCreateInstance(&CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER, &IID_IWICImagingFactory, (void **)&factory);
    worker_loop((Cache *)arg, factory);
    if (factory) IWICImagingFactory_Release(factory);
    if (SUCCEEDED(init)) CoUninitialize();
    return 0;
}
static int thread_start(media_thread *thread, Cache *cache)
{
    *thread = CreateThread(NULL, 0, worker_main, cache, 0, NULL);
    return *thread != NULL;
}
static void thread_join(media_thread thread)
{
    WaitForSingleObject(thread, INFINITE);
    CloseHandle(thread);
}
#else
static void *worker_main(void *arg)
{
    static int factory = 1;
    worker_loop((Cache *)arg, &factory);
    return NULL;
}
static int thread_start(media_thread *thread, Cache *cache) { return pthread_create(thread, NULL, worker_main, cache) == 0; }
static void thread_join(media_thread thread) { pthread_join(thread, NULL); }
#endif

/* ---- the cache: UI thread ----------------------------------------------------------------- */

static Entry *entry_find(Cache *cache, const char *key, unsigned hash)
{
    Entry *entry;
    for (entry = cache->buckets[hash % BUCKETS]; entry; entry = entry->chain)
        if (entry->hash == hash && strcmp(entry->key, key) == 0) return entry;
    return NULL;
}

static void lru_unlink(Cache *cache, Entry *entry)
{
    if (entry->newer) entry->newer->older = entry->older; else cache->newest = entry->older;
    if (entry->older) entry->older->newer = entry->newer; else cache->oldest = entry->newer;
    entry->newer = entry->older = NULL;
}

static void lru_front(Cache *cache, Entry *entry)
{
    entry->older = cache->newest;
    entry->newer = NULL;
    if (cache->newest) cache->newest->newer = entry; else cache->oldest = entry;
    cache->newest = entry;
}

static void entry_remove(Cache *cache, Entry *entry)
{
    Entry **link = &cache->buckets[entry->hash % BUCKETS];
    while (*link != entry) link = &(*link)->chain;
    *link = entry->chain;
    if (entry->state == STATE_READY) {
        lru_unlink(cache, entry);
        cache->used -= entry->bytes;
    }
    cache->entries--;
    free(entry->pixels);
    free(entry->error);
    free(entry->key);
    free(entry);
}

static Entry *entry_add(Cache *cache, const char *key, unsigned hash)
{
    Entry *entry = (Entry *)calloc(1, sizeof(Entry));
    if (!entry) return NULL;
    entry->key = copy_text(key);
    if (!entry->key) { free(entry); return NULL; }
    entry->hash = hash;
    entry->state = STATE_QUEUED;
    entry->chain = cache->buckets[hash % BUCKETS];
    cache->buckets[hash % BUCKETS] = entry;
    cache->entries++;
    return entry;
}

static void evict(Cache *cache, Entry *keep)
{
    while (cache->used > cache->max_bytes && cache->oldest && cache->oldest != keep) {
        cache->dropped++;
        entry_remove(cache, cache->oldest);
    }
}

static void shut_down(Cache *cache)
{
    Job *job;
    unsigned i;
    int t;
    if (cache->closed) return;
    cache->closed = 1;
    lock_take(&cache->lock);
    cache->closing = 1;
    cond_all(&cache->work);
    cond_all(&cache->room);
    lock_give(&cache->lock);
    for (t = 0; t < cache->threads; t++) thread_join(cache->thread[t]);
    while ((job = cache->jobs_newest) != NULL) {
        job_unlink(cache, job);
        job_free(job);
    }
    for (i = cache->ring_read; i != cache->ring_write; i++) {
        free(cache->ring[i % RING_SIZE].key);
        free(cache->ring[i % RING_SIZE].pixels);
    }
    for (t = 0; t < BUCKETS; t++)
        while (cache->buckets[t]) entry_remove(cache, cache->buckets[t]);
    lock_free(&cache->lock);
    cond_free(&cache->work);
    cond_free(&cache->room);
}

/* ---- Lua ---------------------------------------------------------------------------------- */

static Cache *check_cache(lua_State *L)
{
    Cache *cache = (Cache *)luaL_checkudata(L, 1, CACHE_META);
    if (cache->closed) luaL_error(L, "cache is closed");
    return cache;
}

static int l_cache(lua_State *L)
{
    lua_Number max_mb = 256;
    int threads = 2, max_queued = 256, t;
    Cache *cache;
    if (lua_istable(L, 1)) {
        lua_getfield(L, 1, "max_mb");
        if (lua_isnumber(L, -1)) max_mb = lua_tonumber(L, -1);
        lua_getfield(L, 1, "threads");
        if (lua_isnumber(L, -1)) threads = (int)lua_tointeger(L, -1);
        lua_getfield(L, 1, "max_queued");
        if (lua_isnumber(L, -1)) max_queued = (int)lua_tointeger(L, -1);
        lua_pop(L, 3);
    }
    threads = threads < 1 ? 1 : threads > MAX_THREADS ? MAX_THREADS : threads;
    cache = (Cache *)lua_newuserdata(L, sizeof(Cache));
    memset(cache, 0, sizeof(Cache));
    cache->closed = 1;  /* until the lock exists */
    luaL_getmetatable(L, CACHE_META);
    lua_setmetatable(L, -2);
    cache->max_bytes = (size_t)(max_mb * 1024 * 1024);
    cache->max_queued = max_queued < 8 ? 8 : max_queued;
    lock_init(&cache->lock);
    cond_init(&cache->work);
    cond_init(&cache->room);
    cache->closed = 0;
    for (t = 0; t < threads; t++) {
        if (!thread_start(&cache->thread[cache->threads], cache)) break;
        cache->threads++;
    }
    if (!cache->threads) {
        shut_down(cache);
        return luaL_error(L, "could not start a decode thread");
    }
    return 1;
}

static int enqueue(lua_State *L, const char *path, const char *data, size_t size)
{
    Cache *cache = check_cache(L);
    const char *key = luaL_checkstring(L, 2);
    int width = luaL_checkint(L, 4), height = luaL_checkint(L, 5);
    unsigned hash = hash_key(key);
    Job *job;
    Entry *entry;
    if (width < 1 || height < 1 || width > MAX_SIDE || height > MAX_SIDE)
        return luaL_error(L, "poster size out of range");
    if (entry_find(cache, key, hash)) { lua_pushboolean(L, 0); return 1; }
    job = (Job *)calloc(1, sizeof(Job));
    if (job) job->key = copy_text(key);
    if (job && path) job->path = copy_text(path);
    if (job && data) {
        job->data = (unsigned char *)malloc(size);
        if (job->data) memcpy(job->data, data, size);
        job->size = size;
    }
    entry = job && job->key && (job->path || job->data) ? entry_add(cache, key, hash) : NULL;
    if (!entry) {
        if (job) job_free(job);
        return luaL_error(L, "out of memory");
    }
    job->width = width;
    job->height = height;
    lock_take(&cache->lock);
    job->older = cache->jobs_newest;
    if (cache->jobs_newest) cache->jobs_newest->newer = job; else cache->jobs_oldest = job;
    cache->jobs_newest = job;
    cache->queued++;
    if (cache->queued > cache->max_queued) {
        Job *stale = cache->jobs_oldest;
        Entry *gone = entry_find(cache, stale->key, hash_key(stale->key));
        job_unlink(cache, stale);
        if (gone) entry_remove(cache, gone);  /* asked for again if it comes back into view */
        job_free(stale);
    }
    cond_one(&cache->work);
    lock_give(&cache->lock);
    lua_pushboolean(L, 1);
    return 1;
}

static int l_request(lua_State *L)
{
    return enqueue(L, luaL_checkstring(L, 3), NULL, 0);
}

static int l_request_bytes(lua_State *L)
{
    size_t size;
    const char *data = luaL_checklstring(L, 3, &size);
    return enqueue(L, NULL, data, size);
}

static int l_get(lua_State *L)
{
    Cache *cache = check_cache(L);
    const char *key = luaL_checkstring(L, 2);
    Entry *entry = entry_find(cache, key, hash_key(key));
    if (!entry || entry->state != STATE_READY) return 0;
    if (cache->newest != entry) {
        lru_unlink(cache, entry);
        lru_front(cache, entry);
    }
    lua_pushlightuserdata(L, entry->pixels);
    lua_pushinteger(L, entry->stride);
    lua_pushinteger(L, entry->width);
    lua_pushinteger(L, entry->height);
    return 4;
}

static int l_status(lua_State *L)
{
    Cache *cache = check_cache(L);
    const char *key = luaL_checkstring(L, 2);
    Entry *entry = entry_find(cache, key, hash_key(key));
    if (!entry) return 0;
    lua_pushstring(L, entry->state == STATE_READY ? "ready" : entry->state == STATE_QUEUED ? "queued" : "failed");
    if (entry->error) { lua_pushstring(L, entry->error); return 2; }
    return 1;
}

static int l_drain(lua_State *L)
{
    Cache *cache = check_cache(L);
    int limit = luaL_optint(L, 2, RING_SIZE), count = 0;
    Done taken[RING_SIZE];
    int i;
    if (limit > RING_SIZE) limit = RING_SIZE;
    lock_take(&cache->lock);
    while (count < limit && cache->ring_read != cache->ring_write)
        taken[count++] = cache->ring[cache->ring_read++ % RING_SIZE];
    if (count) cond_all(&cache->room);
    lock_give(&cache->lock);
    lua_createtable(L, count, 0);
    for (i = 0; i < count; i++) {
        Done *done = &taken[i];
        Entry *entry = entry_find(cache, done->key, hash_key(done->key));
        if (!entry || entry->state != STATE_QUEUED) {  /* forgotten or cleared while it decoded */
            free(done->pixels);
        } else if (done->pixels) {
            entry->pixels = done->pixels;
            entry->width = done->width;
            entry->height = done->height;
            entry->stride = done->stride;
            entry->bytes = (size_t)done->stride * done->height;
            entry->state = STATE_READY;
            cache->used += entry->bytes;
            lru_front(cache, entry);
            evict(cache, entry);
        } else {
            entry->state = STATE_FAILED;
            entry->error = copy_text(done->error);
        }
        lua_pushstring(L, done->key);
        lua_rawseti(L, -2, i + 1);
        free(done->key);
    }
    return 1;
}

static int l_forget(lua_State *L)
{
    Cache *cache = check_cache(L);
    const char *key = luaL_checkstring(L, 2);
    Entry *entry = entry_find(cache, key, hash_key(key));
    if (entry) entry_remove(cache, entry);
    return 0;
}

static int l_clear(lua_State *L)
{
    Cache *cache = check_cache(L);
    Job *job;
    int t;
    lock_take(&cache->lock);
    while ((job = cache->jobs_newest) != NULL) {
        job_unlink(cache, job);
        job_free(job);
    }
    lock_give(&cache->lock);
    for (t = 0; t < BUCKETS; t++)
        while (cache->buckets[t]) entry_remove(cache, cache->buckets[t]);
    return 0;
}

static int l_stats(lua_State *L)
{
    Cache *cache = check_cache(L);
    int queued;
    lock_take(&cache->lock);
    queued = cache->queued;
    lock_give(&cache->lock);
    lua_createtable(L, 0, 5);
    lua_pushnumber(L, (lua_Number)cache->used); lua_setfield(L, -2, "used_bytes");
    lua_pushnumber(L, (lua_Number)cache->max_bytes); lua_setfield(L, -2, "max_bytes");
    lua_pushnumber(L, (lua_Number)cache->entries); lua_setfield(L, -2, "entries");
    lua_pushnumber(L, (lua_Number)cache->dropped); lua_setfield(L, -2, "evicted");
    lua_pushinteger(L, queued); lua_setfield(L, -2, "queued");
    return 1;
}

static int l_close(lua_State *L)
{
    shut_down((Cache *)luaL_checkudata(L, 1, CACHE_META));
    return 0;
}

static const luaL_Reg cache_methods[] = {
    { "request", l_request },
    { "requestBytes", l_request_bytes },
    { "get", l_get },
    { "status", l_status },
    { "drain", l_drain },
    { "forget", l_forget },
    { "clear", l_clear },
    { "stats", l_stats },
    { "close", l_close },
    { NULL, NULL }
};

static const luaL_Reg module_functions[] = {
    { "cache", l_cache },
    { NULL, NULL }
};

int luaopen_media_native(lua_State *L)
{
    luaL_newmetatable(L, CACHE_META);
    lua_pushcfunction(L, l_close);
    lua_setfield(L, -2, "__gc");
    lua_newtable(L);
    luaL_register(L, NULL, cache_methods);
    lua_setfield(L, -2, "__index");
    lua_pop(L, 1);
    lua_newtable(L);
    luaL_register(L, NULL, module_functions);
    return 1;
}
