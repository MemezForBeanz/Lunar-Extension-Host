# The Linux ImGui target has no IUP/GTK widget dependency. SDL owns the windows and
# input; OpenGL renders Lunar's existing ImGui draw lists.
find_package(PkgConfig REQUIRED)
pkg_check_modules(FONTCONFIG REQUIRED IMPORTED_TARGET fontconfig)
pkg_check_modules(GLIB REQUIRED IMPORTED_TARGET glib-2.0)
pkg_check_modules(PIXBUF REQUIRED IMPORTED_TARGET gdk-pixbuf-2.0)
find_package(OpenGL REQUIRED)
find_package(SDL3 3.2 CONFIG QUIET)
if(NOT SDL3_FOUND)
    include(FetchContent)
    set(SDL_TESTS OFF CACHE BOOL "" FORCE)
    set(SDL_EXAMPLES OFF CACHE BOOL "" FORCE)
    set(SDL_SHARED OFF CACHE BOOL "" FORCE)
    set(SDL_STATIC ON CACHE BOOL "" FORCE)
    FetchContent_Declare(SDL3
        URL https://github.com/libsdl-org/SDL/releases/download/release-3.2.20/SDL3-3.2.20.tar.gz
        URL_HASH SHA256=467600ae090dd28616fa37369faf4e3143198ff1da37729b552137e47f751a67
        DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
    FetchContent_MakeAvailable(SDL3)
endif()
add_executable(Lunar
    src/c/core/main_imgui.c
    src/c/platform/posix/host.c
    src/c/platform/posix/process.c
    src/c/libs/logscan.c
    src/c/libs/native_resolver.c
    src/c/libs/compositor/blend.c
    src/c/libs/compositor/compositor_lua.c
    src/c/libs/compositor/backend_none.c
    src/c/libs/media_native.c
    src/c/libs/imagecodec.c
    src/c/libs/nanosvg_impl.c
    src/c/libs/svgicon_sizes.c
    src/cpp/lunarimgui_sdl.cpp
    src/cpp/lunar_layout.cpp
    vendor/imgui/imgui.cpp
    vendor/imgui/imgui_demo.cpp
    vendor/imgui/imgui_draw.cpp
    vendor/imgui/imgui_tables.cpp
    vendor/imgui/imgui_widgets.cpp
    vendor/imgui/backends/imgui_impl_sdl3.cpp
    vendor/imgui/backends/imgui_impl_opengl3.cpp
    vendor/cimgui/cimgui.cpp)
set_target_properties(Lunar PROPERTIES OUTPUT_NAME lunar ENABLE_EXPORTS TRUE)
add_dependencies(Lunar embed_lua embed_images)
target_compile_definitions(Lunar PRIVATE IMGUI_DISABLE_DEMO_WINDOWS IMGUI_DISABLE_OBSOLETE_FUNCTIONS=1)
target_include_directories(Lunar PRIVATE ${LUA_SRC} ${NANOSVG_DIR} ${VENDOR}
    ${CMAKE_SOURCE_DIR}/include ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/c
    ${VENDOR}/imgui ${VENDOR}/cimgui)
target_link_libraries(Lunar PRIVATE file_stream_static lua_static lfs_static cjson_static luasec_static luasocket_static
    OpenSSL::SSL OpenSSL::Crypto SDL3::SDL3 OpenGL::GL
    PkgConfig::FONTCONFIG PkgConfig::GLIB PkgConfig::PIXBUF m dl pthread)
target_link_options(Lunar PRIVATE -Wl,--export-dynamic)
option(LUNAR_DEV_BUILD "Development build: load repo extensions and Lua" ON)
if(LUNAR_DEV_BUILD)
    target_compile_definitions(Lunar PRIVATE LUNAR_DEV_BUILD=1 LUNAR_SOURCE_DIR="${CMAKE_SOURCE_DIR}")
endif()
