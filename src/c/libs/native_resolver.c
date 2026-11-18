#include <lua.h>
#include <lauxlib.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#ifdef _WIN32
#include <process.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
typedef HANDLE resolver_thread;
typedef CRITICAL_SECTION resolver_mutex;
#define RESOLVER_THREAD_RETURN unsigned __stdcall
#define RESOLVER_THREAD_CALL __stdcall
static void resolver_mutex_init(resolver_mutex *m) { InitializeCriticalSection(m); }
static void resolver_mutex_destroy(resolver_mutex *m) { DeleteCriticalSection(m); }
static void resolver_mutex_lock(resolver_mutex *m) { EnterCriticalSection(m); }
static void resolver_mutex_unlock(resolver_mutex *m) { LeaveCriticalSection(m); }
#else
#include <netdb.h>
#include <pthread.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <time.h>
typedef pthread_t resolver_thread;
typedef pthread_mutex_t resolver_mutex;
#define RESOLVER_THREAD_RETURN void *
#define RESOLVER_THREAD_CALL
static void resolver_mutex_init(resolver_mutex *m) { pthread_mutex_init(m, NULL); }
static void resolver_mutex_destroy(resolver_mutex *m) { pthread_mutex_destroy(m); }
static void resolver_mutex_lock(resolver_mutex *m) { pthread_mutex_lock(m); }
static void resolver_mutex_unlock(resolver_mutex *m) { pthread_mutex_unlock(m); }
#endif

#define RESOLVER_MAX_ACTIVE 4
#define RESOLVER_MAX_ADDRESSES 16

static char *resolver_strdup(const char *text)
{
	size_t length = strlen(text) + 1;
	char *copy = (char *)malloc(length);
	if (copy) memcpy(copy, text, length);
	return copy;
}

typedef struct resolver_request {
	resolver_mutex mutex;
	volatile int cancelled;
	int done;
	int status;
	int refs;
	char error[128];
	char *addresses[RESOLVER_MAX_ADDRESSES];
	size_t address_count;
} resolver_request;

static resolver_mutex g_active_mutex;
static int g_active;
#ifdef _WIN32
static INIT_ONCE g_once = INIT_ONCE_STATIC_INIT;
static BOOL CALLBACK resolver_init_once(PINIT_ONCE once, PVOID arg, PVOID *context)
{
	(void)once; (void)arg; (void)context;
	resolver_mutex_init(&g_active_mutex); return TRUE;
}
static void resolver_global_init(void) { InitOnceExecuteOnce(&g_once, resolver_init_once, NULL, NULL); }
#else
static pthread_once_t g_once = PTHREAD_ONCE_INIT;
static void resolver_init_once(void) { resolver_mutex_init(&g_active_mutex); }
static void resolver_global_init(void) { pthread_once(&g_once, resolver_init_once); }
#endif

static void resolver_release(resolver_request *request)
{
	int free_request = 0;
	resolver_mutex_lock(&request->mutex);
	request->refs--;
	free_request = request->refs == 0;
	resolver_mutex_unlock(&request->mutex);
	if (!free_request) return;
	{
		size_t i;
		for (i = 0; i < request->address_count; i++) free(request->addresses[i]);
	}
	resolver_mutex_destroy(&request->mutex);
	free(request);
}

static int resolver_cancelled(resolver_request *request)
{
	int cancelled;
	resolver_mutex_lock(&request->mutex);
	cancelled = request->cancelled;
	resolver_mutex_unlock(&request->mutex);
	return cancelled;
}

static void resolver_finish(resolver_request *request, int status, const char *error)
{
	resolver_mutex_lock(&request->mutex);
	if (!request->cancelled) {
		request->status = status;
		if (error) {
			strncpy(request->error, error, sizeof(request->error) - 1);
			request->error[sizeof(request->error) - 1] = '\0';
		}
	}
	request->done = 1;
	resolver_mutex_unlock(&request->mutex);
}

static RESOLVER_THREAD_RETURN RESOLVER_THREAD_CALL resolver_run(void *arg)
{
	resolver_request *request = (resolver_request *)arg;
	struct addrinfo hints;
	struct addrinfo *result = NULL;
	struct addrinfo *it;
	const char *host = (const char *)(request + 1);
	int rc;
	memset(&hints, 0, sizeof(hints));
	hints.ai_socktype = SOCK_STREAM;
	hints.ai_family = AF_UNSPEC;
	rc = getaddrinfo(host, NULL, &hints, &result);
	if (rc != 0) {
#ifdef _WIN32
		resolver_finish(request, 0, gai_strerrorA(rc));
#else
		resolver_finish(request, 0, gai_strerror(rc));
#endif
		goto done;
	}
	for (it = result; it && request->address_count < RESOLVER_MAX_ADDRESSES; it = it->ai_next) {
		char text[INET6_ADDRSTRLEN + 16];
		void *source = NULL;
		if (resolver_cancelled(request)) break;
		if (it->ai_family == AF_INET) {
			source = &((struct sockaddr_in *)it->ai_addr)->sin_addr;
		} else if (it->ai_family == AF_INET6) {
			source = &((struct sockaddr_in6 *)it->ai_addr)->sin6_addr;
		}
		if (!source || !inet_ntop(it->ai_family, source, text, sizeof(text))) continue;
		if (it->ai_family == AF_INET6 && ((struct sockaddr_in6 *)it->ai_addr)->sin6_scope_id) {
			size_t used = strlen(text);
			snprintf(text + used, sizeof(text) - used, "%%%u", (unsigned)((struct sockaddr_in6 *)it->ai_addr)->sin6_scope_id);
		}
		request->addresses[request->address_count] = resolver_strdup(text);
		if (!request->addresses[request->address_count]) break;
		request->address_count++;
	}
	freeaddrinfo(result);
	resolver_finish(request, request->address_count ? 1 : 0,
		request->address_count ? NULL : "host resolution returned no addresses");
done:
	resolver_mutex_lock(&g_active_mutex);
	g_active--;
	resolver_mutex_unlock(&g_active_mutex);
	resolver_release(request);
#ifdef _WIN32
	return 0;
#else
	return NULL;
#endif
}

static int l_start(lua_State *L)
{
	size_t length;
	const char *host = luaL_checklstring(L, 1, &length);
	resolver_request *request;
	resolver_request **slot;
	resolver_thread thread;
	if (length == 0 || length > 255 || memchr(host, '\0', length)) {
		lua_pushnil(L); lua_pushliteral(L, "invalid host"); return 2;
	}
	/* Allocate Lua ownership before starting the worker: an allocation failure
	   after thread launch would otherwise longjmp and leak the owner's reference. */
	slot = (resolver_request **)lua_newuserdata(L, sizeof(request));
	*slot = NULL;
	luaL_getmetatable(L, "native_resolver.request");
	lua_setmetatable(L, -2);
	resolver_global_init();
	resolver_mutex_lock(&g_active_mutex);
	if (g_active >= RESOLVER_MAX_ACTIVE) {
		resolver_mutex_unlock(&g_active_mutex);
		lua_pushnil(L); lua_pushliteral(L, "DNS resolver is busy"); return 2;
	}
	g_active++;
	resolver_mutex_unlock(&g_active_mutex);
	request = (resolver_request *)calloc(1, sizeof(*request) + length + 1);
	if (!request) {
		resolver_mutex_lock(&g_active_mutex); g_active--; resolver_mutex_unlock(&g_active_mutex);
		lua_pushnil(L); lua_pushliteral(L, "out of memory"); return 2;
	}
	resolver_mutex_init(&request->mutex);
	request->refs = 2;
	memcpy(request + 1, host, length + 1);
#ifdef _WIN32
	thread = (HANDLE)_beginthreadex(NULL, 0, resolver_run, request, 0, NULL);
	if (!thread) {
#else
	if (pthread_create(&thread, NULL, resolver_run, request) != 0) {
#endif
		resolver_mutex_destroy(&request->mutex); free(request);
		resolver_mutex_lock(&g_active_mutex); g_active--; resolver_mutex_unlock(&g_active_mutex);
		lua_pushnil(L); lua_pushliteral(L, "could not create DNS worker"); return 2;
	}
#ifdef _WIN32
	CloseHandle(thread);
#else
	pthread_detach(thread);
#endif
	*slot = request;
	return 1;
}

static resolver_request *request_from_lua(lua_State *L)
{
	resolver_request **slot = (resolver_request **)luaL_checkudata(L, 1, "native_resolver.request");
	return *slot;
}

static int l_poll(lua_State *L)
{
	resolver_request *request = request_from_lua(L);
	if (!request) { lua_pushliteral(L, "error"); lua_pushliteral(L, "resolver request closed"); return 2; }
	int done, status;
	char error[sizeof(request->error)];
	size_t i;
	resolver_mutex_lock(&request->mutex);
	done = request->done;
	status = request->status;
	strncpy(error, request->error, sizeof(error));
	error[sizeof(error) - 1] = '\0';
	resolver_mutex_unlock(&request->mutex);
	if (!done) { lua_pushliteral(L, "pending"); return 1; }
	if (!status) { lua_pushliteral(L, "error"); lua_pushstring(L, error); return 2; }
	lua_pushliteral(L, "done");
	lua_newtable(L);
	for (i = 0; i < request->address_count; i++) {
		lua_pushstring(L, request->addresses[i]);
		lua_rawseti(L, -2, (int)i + 1);
	}
	return 2;
}

static int l_close(lua_State *L)
{
	resolver_request **slot = (resolver_request **)luaL_checkudata(L, 1, "native_resolver.request");
	resolver_request *request = *slot;
	if (!request) return 0;
	resolver_mutex_lock(&request->mutex);
	request->cancelled = 1;
	resolver_mutex_unlock(&request->mutex);
	*slot = NULL;
	resolver_release(request);
	return 0;
}

static int l_cancel(lua_State *L) { return l_close(L); }

static int l_gc(lua_State *L) { return l_close(L); }
static int l_stats(lua_State *L)
{
	int active;
	resolver_global_init();
	resolver_mutex_lock(&g_active_mutex); active = g_active; resolver_mutex_unlock(&g_active_mutex);
	lua_newtable(L);
	lua_pushinteger(L, active); lua_setfield(L, -2, "active");
	lua_pushinteger(L, RESOLVER_MAX_ACTIVE); lua_setfield(L, -2, "limit");
	lua_pushliteral(L, "discard_result"); lua_setfield(L, -2, "cancellation");
	return 1;
}
static int l_now(lua_State *L)
{
#ifdef _WIN32
	LARGE_INTEGER count, frequency;
	QueryPerformanceCounter(&count); QueryPerformanceFrequency(&frequency);
	lua_pushnumber(L, (double)count.QuadPart / (double)frequency.QuadPart);
#else
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	lua_pushnumber(L, (double)ts.tv_sec + ts.tv_nsec / 1e9);
#endif
	return 1;
}

int luaopen_native_resolver(lua_State *L)
{
	static const luaL_Reg methods[] = {
		{ "start", l_start }, { "poll", l_poll }, { "cancel", l_cancel },
		{ "close", l_close }, { "now", l_now }, { "stats", l_stats }, { NULL, NULL }
	};
	resolver_global_init();
	if (luaL_newmetatable(L, "native_resolver.request")) {
		lua_pushcfunction(L, l_gc); lua_setfield(L, -2, "__gc");
		lua_pop(L, 1);
	} else {
		lua_pop(L, 1);
	}
	lua_newtable(L);
	for (const luaL_Reg *it = methods; it->name; it++) {
		lua_pushcfunction(L, it->func); lua_setfield(L, -2, it->name);
	}
	return 1;
}
