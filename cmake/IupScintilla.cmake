# IupScintilla: the text surface behind core.ui.CodeView.
#
# Scintilla 3.11.2 and IUP's wrapper for it ship inside the IUP source tarball
# (vendor/iup-src/iup/srcscintilla) but not among the prebuilt archives in
# vendor/iup, so they are compiled here into one static library, together with
# the generated Lua binding (srclua5/ctrl/il_scintilla.c).
#
# The source list and defines follow srcscintilla/config.mak for a C++11 compiler
# (its HAVE_CPP11 branch, which selects scintilla3112). One deliberate difference:
#
#   * DISABLE_D2D is not defined. config.mak sets it for every MinGW, because the
#     MinGW of its day had no Direct2D headers. MSYS2's mingw-w64 has them, and
#     DirectWrite text is what lets code read as well as it does in an editor.
#     CodeView picks the technology at run time and falls back to GDI.
#
# LPEG_LEXER is not defined, as in config.mak's default: LexLPeg.cxx then
# compiles to the stub lexer module that Catalogue.cxx still links against.
#
# The sources belong to the IUP fork tree, which scripts/build-iup-fork.ps1
# extracts and patches at build time. They are therefore marked GENERATED and the
# library depends on iup_fork, so a clean checkout configures before they exist.
#
# Sets LUNAR_SCINTILLA_TARGET to the library target on success.

enable_language(CXX)

set(IUPSCI_ROOT ${LUNAR_IUP_SOURCE}/srcscintilla)
set(IUPSCI_DIR  ${IUPSCI_ROOT}/scintilla3112)
set(IUPSCI_LUA  ${LUNAR_IUP_SOURCE}/srclua5)

set(IUPSCI_CORE
    AutoComplete CallTip Catalogue CellBuffer CharClassify ContractionState
    Decoration Document Editor ExternalLexer Indicator KeyMap LineMarker PerLine
    PositionCache RESearch RunStyles ScintillaBase Selection Style UniConversion
    ViewStyle XPM CaseConvert CaseFolder EditModel EditView MarginView DBCS
    UniqueString)

set(IUPSCI_LEXERS
    LexA68k LexAbaqus LexAda LexAPDL LexAsn1 LexASY LexAU3 LexAVE LexAVS LexBaan
    LexBash LexBasic LexBullant LexCaml LexCLW LexCmake LexCOBOL LexCoffeeScript
    LexConf LexCPP LexCrontab LexCsound LexCSS LexD LexECL LexEiffel LexErlang
    LexEScript LexFlagship LexForth LexFortran LexGAP LexGui4Cli LexHaskell
    LexHTML LexInno LexKix LexLisp LexLout LexLua LexMagik LexMarkdown LexMatlab
    LexMetapost LexMMIXAL LexModula LexMPT LexMSSQL LexMySQL LexNimrod LexNsis
    LexOpal LexOScript LexPascal LexPB LexPerl LexPLM LexPO LexPOV LexPowerPro
    LexPowerShell LexProgress LexPS LexPython LexR LexRebol LexRuby LexScriptol
    LexSmalltalk LexSML LexSorcus LexSpecman LexSpice LexSQL LexTACL LexTADS3
    LexTAL LexTCL LexTCMD LexTeX LexTxt2tags LexVB LexVerilog LexVHDL
    LexVisualProlog LexYAML LexKVIrc LexLaTeX LexSTTXT LexRust LexDMAP LexDMIS
    LexBibTeX LexHex LexAsm LexRegistry LexLed LexBatch LexDiff LexErrorList
    LexMake LexNull LexProps LexJSON LexEDIFACT LexIndent LexCIL LexDataflex
    LexHollywood LexMaxima LexNim LexSAS LexStata LexX12 LexLPeg)

set(IUPSCI_LEXLIB
    Accessor CharacterSet LexerBase LexerModule LexerNoExceptions LexerSimple
    PropSetSimple StyleContext WordList CharacterCategory DefaultLexer)

set(IUPSCI_WRAPPER
    iupsci_clipboard iupsci_folding iupsci_lexer iupsci_margin iupsci_overtype
    iupsci_scrolling iupsci_selection iupsci_style iupsci_tab iupsci_text
    iupsci_wordwrap iupsci_markers iupsci_bracelight iupsci_cursor
    iupsci_whitespace iupsci_annotation iupsci_autocompletion iupsci_searching
    iupsci_print iupsci_indicator iup_scintilla iup_scintilladlg)

set(IUPSCI_SOURCES)
foreach(name IN LISTS IUPSCI_CORE)
    list(APPEND IUPSCI_SOURCES ${IUPSCI_DIR}/src/${name}.cxx)
endforeach()
foreach(name IN LISTS IUPSCI_LEXERS)
    list(APPEND IUPSCI_SOURCES ${IUPSCI_DIR}/lexers/${name}.cxx)
endforeach()
foreach(name IN LISTS IUPSCI_LEXLIB)
    list(APPEND IUPSCI_SOURCES ${IUPSCI_DIR}/lexlib/${name}.cxx)
endforeach()
foreach(name IN LISTS IUPSCI_WRAPPER)
    list(APPEND IUPSCI_SOURCES ${IUPSCI_ROOT}/${name}.c)
endforeach()

if(WIN32)
    list(APPEND IUPSCI_SOURCES
        ${IUPSCI_DIR}/win32/PlatWin.cxx
        ${IUPSCI_DIR}/win32/ScintillaWin.cxx
        ${IUPSCI_DIR}/win32/HanjaDic.cxx
        ${IUPSCI_ROOT}/iup_scintilla_win.c)
else()
    list(APPEND IUPSCI_SOURCES
        ${IUPSCI_DIR}/gtk/PlatGTK.cxx
        ${IUPSCI_DIR}/gtk/ScintillaGTK.cxx
        ${IUPSCI_DIR}/gtk/ScintillaGTKAccessible.cxx
        ${IUPSCI_DIR}/gtk/scintilla-marshal.c
        ${IUPSCI_ROOT}/iup_scintilla_gtk.c)
endif()

# The Lua binding (generated C that ships in the tarball, with its Lua half as a
# byte array under lh/).
list(APPEND IUPSCI_SOURCES
    ${IUPSCI_LUA}/ctrl/il_scintilla.c
    ${IUPSCI_LUA}/ctrl/il_scintilladlg.c)

set_source_files_properties(${IUPSCI_SOURCES} PROPERTIES GENERATED TRUE)

add_library(iup_scintilla_static STATIC ${IUPSCI_SOURCES})
add_dependencies(iup_scintilla_static iup_fork)
set_target_properties(iup_scintilla_static PROPERTIES
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED ON
    CXX_EXTENSIONS ON)

target_include_directories(iup_scintilla_static PRIVATE
    ${LUA_SRC}
    ${LUNAR_IUP_SOURCE}/include
    ${LUNAR_IUP_SOURCE}/src
    ${IUPSCI_ROOT}
    ${IUPSCI_DIR}/include
    ${IUPSCI_DIR}/src
    ${IUPSCI_DIR}/lexlib
    ${IUPSCI_LUA}
    ${IUPSCI_LUA}/lh)

target_compile_definitions(iup_scintilla_static PRIVATE
    STATIC_BUILD SCI_LEXER SCI_NAMESPACE
    SCINTILLA_VERSION="3.11.2"
    IUPLUA_USELH)

# Third-party code: its warnings are not ours to fix. The -Wno-error set mirrors
# scripts/build-iup-fork.ps1, which compiles the same IUP headers.
target_compile_options(iup_scintilla_static PRIVATE -w
    $<$<COMPILE_LANGUAGE:C>:-Wno-error=incompatible-pointer-types>
    $<$<COMPILE_LANGUAGE:C>:-Wno-error=int-conversion>
    $<$<COMPILE_LANGUAGE:C>:-Wno-error=implicit-function-declaration>
    $<$<COMPILE_LANGUAGE:C>:-Wno-error=implicit-int>
    $<$<COMPILE_LANGUAGE:C>:-Wno-error=discarded-qualifiers>)

if(WIN32)
    target_include_directories(iup_scintilla_static PRIVATE
        ${LUNAR_IUP_SOURCE}/src/win
        ${IUPSCI_DIR}/win32)
    target_compile_definitions(iup_scintilla_static PRIVATE
        _WIN32 UNICODE _UNICODE _SCL_SECURE_NO_WARNINGS NO_CXX11_REGEX
        _WIN32_WINNT=0x0601 WINVER=0x0601)
    target_link_libraries(iup_scintilla_static INTERFACE
        -limm32 -lmsimg32 -ld2d1 -ldwrite)
else()
    target_include_directories(iup_scintilla_static PRIVATE
        ${LUNAR_IUP_SOURCE}/src/gtk
        ${IUPSCI_DIR}/gtk)
    target_compile_definitions(iup_scintilla_static PRIVATE
        GTK GTK_DISABLE_DEPRECATED GDK_DISABLE_DEPRECATED GSEAL_ENABLE G_HAVE_ISO_VARARGS)
    target_link_libraries(iup_scintilla_static PRIVATE PkgConfig::GTK3)
    target_link_libraries(iup_scintilla_static INTERFACE atk-1.0)
endif()

set(LUNAR_SCINTILLA_TARGET iup_scintilla_static)
