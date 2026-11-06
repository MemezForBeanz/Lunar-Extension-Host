/* Native HTTP file delivery. Workers never enter Lua. One worker per admitted
 * connection, one 64 KiB buffer, and at most one 1 MiB kernel send outstanding.
 * The Lua owner keeps the transport alive until the worker has joined. */
#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64
#ifdef _WIN32
#include <winsock2.h>
#include <windows.h>
#include <mswsock.h>
#include <winternl.h>
#else
#include <sys/socket.h>
#include <sys/sendfile.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <sched.h>
#endif
#include <lua.h>
#include <lauxlib.h>
#include "luasec/src/ssl.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <errno.h>
#include <stdatomic.h>
#define CHUNK 65536
#define QUANTUM 1048576
#define TARGET "lunar.file.target"
#define TASK "lunar.file.task"
typedef struct { char root[4096], path[4096], mime[256]; } target;
typedef struct {
    target target;
    t_socket sock;
    SSL *ssl;
    char range[8193], match[8193], none[8193], ifrange[8193], modified[8193], unmodified[8193];
    int head, status, error, joined;
    atomic_int cancel, done;
#ifdef _WIN32
    HANDLE thread, file;
#else
    pthread_t thread;
    int file;
#endif
} task;

static int decimal(const char **p, uint64_t *v) {
    const char *s=*p; uint64_t n=0;
    if (*s<'0'||*s>'9') return 0;
    do { unsigned d=(unsigned)(*s++-'0');
        if (n>(INT64_MAX-d)/10) return 0;
        n=n*10+d;
    } while (*s>='0'&&*s<='9');
    *v=n; *p=s; return 1;
}
/* Signed 64-bit file sizes, subtraction before addition, no Lua doubles. */
static int range_plan(uint64_t size, const char *range, uint64_t *off, uint64_t *len) {
    uint64_t a,b; const char *s=range;
    *off=0; *len=size;
    if (!*s) return 200;
    if (strncmp(s,"bytes=",6)||strchr(s,',')) return 416;
    s+=6;
    if (*s=='-') {
        s++; if (!decimal(&s,&a)||*s||!a||!size) return 416;
        *len=a<size?a:size; *off=size-*len;
    } else {
        if (!decimal(&s,&a)||*s++!='-'||a>=size) return 416;
        if (!*s) b=size-1;
        else if (!decimal(&s,&b)||*s||b<a) return 416;
        if (b>=size) b=size-1;
        *off=a; *len=b-a+1;
    }
    return 206;
}
static int component(const char *s) {
    return *s && strcmp(s,".") && strcmp(s,"..") && !strpbrk(s,"\\:%");
}
#ifdef _WIN32
/* Relative NT opens pin every lookup to the already verified parent. No
 * traversal follows a reparse point, including a junction in the root path. */
typedef NTSTATUS (NTAPI *ntopen_fn)(PHANDLE,ACCESS_MASK,POBJECT_ATTRIBUTES,
    PIO_STATUS_BLOCK,PLARGE_INTEGER,ULONG,ULONG,ULONG,ULONG,PVOID,ULONG);
static HANDLE child(HANDLE parent,const char *name,int directory) {
    WCHAR wide[4096]; UNICODE_STRING us; OBJECT_ATTRIBUTES oa; IO_STATUS_BLOCK io;
    HANDLE h=INVALID_HANDLE_VALUE; FILE_ATTRIBUTE_TAG_INFO tag;
    ntopen_fn fn=(ntopen_fn)(void*)GetProcAddress(GetModuleHandleW(L"ntdll.dll"),"NtCreateFile");
    int n=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,name,-1,wide,4096);
    if (!fn||!n) return INVALID_HANDLE_VALUE;
    us.Buffer=wide; us.Length=(USHORT)((n-1)*2); us.MaximumLength=(USHORT)(n*2);
    InitializeObjectAttributes(&oa,&us,OBJ_CASE_INSENSITIVE|0x1000,parent,NULL);
    NTSTATUS st=fn(&h,GENERIC_READ|(directory?SYNCHRONIZE:0),&oa,&io,NULL,0,
        FILE_SHARE_READ,1,0x00200000|(directory?0x21:0x40),NULL,0);
    if (st<0) return INVALID_HANDLE_VALUE;
    if (!GetFileInformationByHandleEx(h,FileAttributeTagInfo,&tag,sizeof(tag)) ||
        (tag.FileAttributes&FILE_ATTRIBUTE_REPARSE_POINT)) { CloseHandle(h); return INVALID_HANDLE_VALUE; }
    return h;
}
static int open_file(task *t,uint64_t *size,char *etag,size_t cap,int64_t *mtime) {
    char root[4096],path[4096],*s,*next; HANDLE h,nh; BY_HANDLE_FILE_INFORMATION info;
    strcpy(root,t->target.root); strcpy(path,t->target.path);
    if (!((root[0]>='A'&&root[0]<='Z')||(root[0]>='a'&&root[0]<='z'))||root[1]!=':'||
        (root[2]!='/'&&root[2]!='\\')) return 0;
    char drive[]={root[0],':','\\',0};
    WCHAR wd[4]; MultiByteToWideChar(CP_UTF8,0,drive,-1,wd,4);
    h=CreateFileW(wd,GENERIC_READ,FILE_SHARE_READ,NULL,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OPEN_REPARSE_POINT,NULL);
    if(h==INVALID_HANDLE_VALUE) return 0;
    for(s=root+3;*s;s=next) {
        next=strpbrk(s,"/\\"); if(next) *next++=0; else next=s+strlen(s);
        if(!component(s)) {CloseHandle(h);return 0;}
        nh=child(h,s,1); CloseHandle(h); h=nh; if(h==INVALID_HANDLE_VALUE)return 0;
    }
    for(s=path;*s;s=next) {
        next=strchr(s,'/'); int dir=next!=NULL;
        if(next) *next++=0; else next=s+strlen(s);
        if(!component(s)) {CloseHandle(h);return 0;}
        nh=child(h,s,dir); CloseHandle(h); h=nh; if(h==INVALID_HANDLE_VALUE)return 0;
    }
    if(!GetFileInformationByHandle(h,&info)||(info.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY)) {CloseHandle(h);return 0;}
    *size=((uint64_t)info.nFileSizeHigh<<32)|info.nFileSizeLow;
    if(*size>INT64_MAX){CloseHandle(h);return 0;}
    snprintf(etag,cap,"\"%lx-%lx%08lx-%lx%08lx-%llx\"",(unsigned long)info.dwVolumeSerialNumber,
        (unsigned long)info.nFileIndexHigh,(unsigned long)info.nFileIndexLow,
        (unsigned long)info.ftLastWriteTime.dwHighDateTime,(unsigned long)info.ftLastWriteTime.dwLowDateTime,(unsigned long long)*size);
    uint64_t ft=((uint64_t)info.ftLastWriteTime.dwHighDateTime<<32)|info.ftLastWriteTime.dwLowDateTime;
    *mtime=(int64_t)(ft/10000000)-11644473600LL;
    t->file=h; return 1;
}
#else
static int walk(int parent,char *path,int final) {
    char *s=path,*next; int fd=parent;
    while(*s) {
        next=strchr(s,'/'); int dir=next!=NULL||!final;
        if(next)*next++=0;else next=s+strlen(s);
        if(!component(s)){close(fd);return -1;}
        int n=openat(fd,s,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK|(dir?O_DIRECTORY:0));
        close(fd); if(n<0)return -1; fd=n; s=next;
    }
    return fd;
}
static int open_file(task *t,uint64_t *size,char *etag,size_t cap,int64_t *mtime) {
    char root[4096],path[4096]; struct stat st;
    strcpy(root,t->target.root);strcpy(path,t->target.path);
    if(root[0]!='/')return 0;
    int fd=open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC);
    if(fd<0)return 0;
    fd=walk(fd,root+1,0);if(fd<0)return 0;
    fd=walk(fd,path,1);if(fd<0)return 0;
    if(fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_size<0){close(fd);return 0;}
    *size=(uint64_t)st.st_size;*mtime=(int64_t)st.st_mtime;t->file=fd;
    snprintf(etag,cap,"\"%llx-%llx-%llx-%llx-%llx\"",(unsigned long long)st.st_dev,
        (unsigned long long)st.st_ino,(unsigned long long)st.st_mtim.tv_sec,
        (unsigned long long)st.st_mtim.tv_nsec,(unsigned long long)*size);return 1;
}
#endif
static int wait_socket(task *t,int reading) {
    if(atomic_load(&t->cancel))return 0;
#ifdef _WIN32
    WSAPOLLFD p={t->sock,reading?POLLRDNORM:POLLWRNORM,0};
    int n=WSAPoll(&p,1,10);
#else
    struct pollfd p={t->sock,reading?POLLIN:POLLOUT,0};
    int n=poll(&p,1,10);
#endif
    return n>=0 && !(p.revents&(POLLERR|POLLHUP|POLLNVAL)) && !atomic_load(&t->cancel);
}
static int write_buffer(task *t,const char *buf,size_t len) {
    while(len&&!atomic_load(&t->cancel)) {
        int n;
        if(t->ssl) {
            n=SSL_write(t->ssl,buf,(int)len);
            if(n<=0) {int e=SSL_get_error(t->ssl,n);
                if((e==SSL_ERROR_WANT_READ||e==SSL_ERROR_WANT_WRITE)&&wait_socket(t,e==SSL_ERROR_WANT_READ))continue;
                return 0;
            }
        } else {
#ifdef _WIN32
            n=send(t->sock,buf,(int)len,0);
            if(n<0&&WSAGetLastError()==WSAEWOULDBLOCK&&wait_socket(t,0))continue;
#else
            n=(int)send(t->sock,buf,len,MSG_NOSIGNAL);
            if(n<0&&(errno==EAGAIN||errno==EWOULDBLOCK||errno==EINTR)&&wait_socket(t,0))continue;
#endif
            if(n<=0)return 0;
        }
        buf+=n;len-=(size_t)n;
    }
    return !len;
}
static int transfer(task *t,uint64_t off,uint64_t len) {
    char buffer[CHUNK];
    while(len&&!atomic_load(&t->cancel)) {
        unsigned count=(unsigned)(len>QUANTUM?QUANTUM:len); uint64_t sent=0;
#ifdef _WIN32
        OVERLAPPED ov={0};ov.Offset=(DWORD)off;ov.OffsetHigh=(DWORD)(off>>32);
        ov.hEvent=CreateEventW(NULL,TRUE,FALSE,NULL);if(!ov.hEvent)return 0;
        BOOL ok;DWORD n=0;
        if(t->ssl) {if(count>CHUNK)count=CHUNK;ok=ReadFile(t->file,buffer,count,&n,&ov);}
        else ok=TransmitFile(t->sock,t->file,count,0,&ov,NULL,0);
        DWORD e=ok?0:GetLastError();
        if(!ok&&e!=ERROR_IO_PENDING){CloseHandle(ov.hEvent);return 0;}
        HANDLE owner=t->ssl?t->file:(HANDLE)t->sock;
        while(WaitForSingleObject(ov.hEvent,10)==WAIT_TIMEOUT) {
            if(atomic_load(&t->cancel)) {CancelIoEx(owner,&ov);break;}
        }
        ok=GetOverlappedResult(owner,&ov,&n,TRUE);CloseHandle(ov.hEvent);
        if(!ok||atomic_load(&t->cancel))return 0;
        sent=n;
#else
        if(t->ssl) {
            if(count>CHUNK)count=CHUNK;
            ssize_t n=pread(t->file,buffer,count,(off_t)off);
            if(n<0&&errno==EINTR)continue;
            if(n<=0)return 0;sent=(uint64_t)n;
        } else {
            off_t pos=(off_t)off;ssize_t n=sendfile(t->sock,t->file,&pos,count);
            if(n<0&&(errno==EAGAIN||errno==EWOULDBLOCK||errno==EINTR)&&wait_socket(t,0))continue;
            if(n<=0)return 0;sent=(uint64_t)n;
        }
#endif
        if(!sent||sent>len)return 0;
        if(t->ssl&&!write_buffer(t,buffer,(size_t)sent))return 0;
        off+=sent;len-=sent;
#ifdef _WIN32
        SwitchToThread();
#else
        sched_yield();
#endif
        /* Worker scheduling bounds each kernel request; slow readers never
         * allocate queued chunks or keep the Lua event loop occupied. */
    }
    return !len;
}
static int tag_matches(const char *list,const char *etag,int weak) {
    if(!strcmp(list,"*"))return 1;
    while(*list) {
        while(*list==' '||*list=='\t'||*list==',')list++;
        const char *end=strchr(list,',');size_t n=end?(size_t)(end-list):strlen(list);
        while(n&&(list[n-1]==' '||list[n-1]=='\t'))n--;
        if(weak&&n>2&&!strncmp(list,"W/",2)){list+=2;n-=2;}
        if(strlen(etag)==n&&!memcmp(list,etag,n))return 1;
        if(!end)break;list=end+1;
    }return 0;
}
/* IMF-fixdate only; invalid or obsolete dates are safely ignored. */
static int64_t http_time(const char *s) {
    struct tm tm={0};char day[4],mon[4],zone[4],tail;int year;
    if(strlen(s)!=29||sscanf(s,"%3s, %d %3s %d %d:%d:%d %3s%c",day,&tm.tm_mday,mon,&year,
        &tm.tm_hour,&tm.tm_min,&tm.tm_sec,zone,&tail)!=8||strcmp(zone,"GMT"))return -1;
    const char *months="JanFebMarAprMayJunJulAugSepOctNovDec";const char *m=strstr(months,mon);
    if(!m||(m-months)%3||year<1970||year>9999||tm.tm_mday<1||tm.tm_mday>31||tm.tm_hour>23||tm.tm_min>59||tm.tm_sec>59)return -1;
    tm.tm_mon=(int)((m-months)/3);tm.tm_year=year-1900;
#ifdef _WIN32
    return (int64_t)_mkgmtime(&tm);
#else
    return (int64_t)timegm(&tm);
#endif
}
static void serve(task *t) {
    uint64_t size=0,off=0,len=0;char etag[256]="",headers[2048],extra[512]="";
    int status=404;int64_t mtime=0;char modified[128]="";
    if(open_file(t,&size,etag,sizeof(etag),&mtime)) {
        time_t stamp=(time_t)mtime;struct tm tm;
#ifdef _WIN32
        gmtime_s(&tm,&stamp);
#else
        gmtime_r(&stamp,&tm);
#endif
        strftime(modified,sizeof(modified),"Last-Modified: %a, %d %b %Y %H:%M:%S GMT\r\n",&tm);
        status=200;len=size;
        if(*t->match&&!tag_matches(t->match,etag,0)){status=412;len=0;}
        else if(!*t->match&&*t->unmodified&&http_time(t->unmodified)>=0&&mtime>http_time(t->unmodified)){status=412;len=0;}
        else if(*t->none&&tag_matches(t->none,etag,1)){status=304;len=0;}
        else if(!*t->none&&*t->modified&&http_time(t->modified)>=0&&http_time(t->modified)>=mtime){status=304;len=0;}
        else if(!t->head&&(!*t->ifrange||!strcmp(t->ifrange,etag)||(http_time(t->ifrange)>=0&&http_time(t->ifrange)>=mtime)))status=range_plan(size,t->range,&off,&len);
        if(status==206)snprintf(extra,sizeof(extra),"Content-Range: bytes %llu-%llu/%llu\r\n",(unsigned long long)off,(unsigned long long)(off+len-1),(unsigned long long)size);
        if(status==416){len=0;snprintf(extra,sizeof(extra),"Content-Range: bytes */%llu\r\n",(unsigned long long)size);}
    }
    t->status=status;
    int n=snprintf(headers,sizeof(headers),"HTTP/1.1 %d Response\r\nConnection: close\r\nAccept-Ranges: bytes\r\nContent-Type: %s\r\n%s%s%s%s%sContent-Length: %llu\r\n\r\n",status,t->target.mime,
        *etag?"ETag: ":"",etag,*etag?"\r\n":"",modified,extra,(unsigned long long)(status==304?size:len));
    if(n<0||(size_t)n>=sizeof(headers)||!write_buffer(t,headers,(size_t)n)||
        (!t->head&&len&&!transfer(t,off,len)))t->error=1;
#ifdef _WIN32
    if(t->file!=INVALID_HANDLE_VALUE)CloseHandle(t->file);
#else
    if(t->file>=0)close(t->file);
#endif
    atomic_store(&t->done,1);
}
#ifdef _WIN32
static DWORD WINAPI worker(void *p){serve(p);return 0;}
#else
static void *worker(void *p){
    sigset_t blocked;sigemptyset(&blocked);sigaddset(&blocked,SIGPIPE);
    pthread_sigmask(SIG_BLOCK,&blocked,NULL);serve(p);return NULL;
}
#endif
static void join(task *t) {
    if(t->joined)return;
#ifdef _WIN32
    WaitForSingleObject(t->thread,INFINITE);CloseHandle(t->thread);
#else
    pthread_join(t->thread,NULL);
#endif
    t->joined=1;
}
static void copyarg(lua_State *L,int index,char *out,size_t cap) {
    size_t n;const char *s=luaL_checklstring(L,index,&n);
    luaL_argcheck(L,n<cap&&strlen(s)==n,index,"string too long or contains NUL");
    memcpy(out,s,n+1);
}
static int new_target(lua_State *L) {
    target *t=lua_newuserdata(L,sizeof(*t));memset(t,0,sizeof(*t));
    copyarg(L,1,t->root,sizeof(t->root));copyarg(L,2,t->path,sizeof(t->path));
    copyarg(L,3,t->mime,sizeof(t->mime));
    luaL_argcheck(L,*t->path&&t->path[0]!='/'&&!strchr(t->path,'\\'),2,"relative slash-separated path required");
    for(const unsigned char *s=(const unsigned char*)t->mime;*s;s++)
        luaL_argcheck(L,*s>=32&&*s!=127,3,"invalid MIME");
    luaL_argcheck(L,*t->mime,3,"invalid MIME");
    luaL_getmetatable(L,TARGET);lua_setmetatable(L,-2);return 1;
}
static int start(lua_State *L) {
    target *src=luaL_checkudata(L,1,TARGET);
    task *t=lua_newuserdata(L,sizeof(*t));memset(t,0,sizeof(*t));t->target=*src;
    t->sock=(t_socket)luaL_checknumber(L,2);
    if(!lua_isnil(L,3))t->ssl=((p_ssl)luaL_checkudata(L,3,"SSL:Connection"))->ssl;
    t->head=lua_toboolean(L,4);
    copyarg(L,5,t->range,sizeof(t->range));copyarg(L,6,t->match,sizeof(t->match));
    copyarg(L,7,t->none,sizeof(t->none));copyarg(L,8,t->ifrange,sizeof(t->ifrange));
    copyarg(L,9,t->modified,sizeof(t->modified));copyarg(L,10,t->unmodified,sizeof(t->unmodified));
    atomic_init(&t->cancel,0);atomic_init(&t->done,0);
#ifdef _WIN32
    t->file=INVALID_HANDLE_VALUE;t->thread=CreateThread(NULL,0,worker,t,0,NULL);
    if(!t->thread)return luaL_error(L,"file worker unavailable");
#else
    t->file=-1;
    if(pthread_create(&t->thread,NULL,worker,t))return luaL_error(L,"file worker unavailable");
#endif
    /* Registry anchor makes the transport live exactly as long as the task.
     * HttpServer also keeps the wrapped connection alive and exclusively owned. */
    lua_newtable(L);lua_pushvalue(L,3);lua_setfield(L,-2,"tls");lua_setfenv(L,-2);
    luaL_getmetatable(L,TASK);lua_setmetatable(L,-2);return 1;
}
static int poll_task(lua_State *L) {
    task *t=luaL_checkudata(L,1,TASK);int done=atomic_load(&t->done);
    if(done)join(t);
    lua_pushboolean(L,done);lua_pushinteger(L,done?t->status:0);lua_pushboolean(L,done&&t->error);return 3;
}
static int cancel(lua_State *L){task *t=luaL_checkudata(L,1,TASK);atomic_store(&t->cancel,1);return 0;}
static int reap(lua_State *L){task *t=luaL_checkudata(L,1,TASK);atomic_store(&t->cancel,1);join(t);return 0;}
static int plan(lua_State *L) {
    const char *s=luaL_checkstring(L,1);uint64_t size,off,len;
    luaL_argcheck(L,decimal(&s,&size)&&!*s,1,"invalid size");
    int status=range_plan(size,luaL_checkstring(L,2),&off,&len);
    char a[32],b[32];snprintf(a,sizeof(a),"%llu",(unsigned long long)off);
    snprintf(b,sizeof(b),"%llu",(unsigned long long)(status==416?0:len));
    lua_pushinteger(L,status);lua_pushstring(L,a);lua_pushstring(L,b);return 3;
}
int luaopen_file_stream(lua_State *L) {
    luaL_newmetatable(L,TARGET);lua_pushliteral(L,"opaque file target");lua_setfield(L,-2,"__metatable");lua_pop(L,1);
    luaL_newmetatable(L,TASK);lua_pushcfunction(L,reap);lua_setfield(L,-2,"__gc");lua_pop(L,1);
    const luaL_Reg methods[]={{"target",new_target},{"start",start},{"poll",poll_task},{"cancel",cancel},{"reap",reap},{"plan",plan},{NULL,NULL}};
    lua_newtable(L);luaL_register(L,NULL,methods);return 1;
}
