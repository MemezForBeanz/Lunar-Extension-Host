#!/usr/bin/env python3
"""Build patched IUP 3.32 with its GTK3 driver and LuaJIT-compatible IupLua.

Usage: python3 -I scripts/build_iup.py [--fresh] [--clean] [--smoke] [--luajit-prefix DIR]

The source lists below follow the Linux USE_GTK/USE_GTK3/USE_NEW_DRAW branches
of IUP's src/config.mak and the Lua 5.1/NO_LUAOBJECT branch of
srclua5/config.mak. The lists are read from those files after extraction.
"""

import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import shlex
import subprocess
import sys
import tarfile
import urllib.request


REPO = Path(__file__).resolve().parent.parent
ROOT = REPO / "vendor/iup-src-linux"
SOURCE = ROOT / "iup"
BUILD = ROOT / "build"
TARBALL = REPO / "vendor/.downloads/iup-src/iup-3.32_Sources.tar.gz"
URL = "https://sourceforge.net/projects/iup/files/3.32/Docs%20and%20Sources/iup-3.32_Sources.tar.gz/download"
TARBALL_SHA256 = "871e17fca0fb04d0a13b68d2fdb9883596337826ea44c9254ca38e3eabb6a6a5"
STAMP = ROOT / ".patch-stamp"
SMOKE_SOURCE = REPO / "iup-fork/verify/iup_smoke_gtk.c"
# Set from --luajit-prefix in main(); CMake passes LUNAR_LUAJIT_PREFIX.
LUA_HEADERS = Path("/usr/local/include/luajit-2.1")
LUA_LIB = Path("/usr/local/lib/libluajit-5.1.a")
CFLAGS = ["-O2", "-g", "-fPIC"]


def run(args, verbose=True, **kwargs):
    if verbose:
        print("+ " + shlex.join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), check=True, **kwargs)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def patch_stamp(patches):
    # Same hash-of-uppercase-file-hashes format as build-iup-fork.ps1.
    hashes = ";".join(sha256(p).upper() for p in patches)
    return hashlib.sha256(hashes.encode("utf-8")).hexdigest().upper()


def prepare(fresh, patches):
    if not TARBALL.exists():
        print(f"Downloading {URL}", flush=True)
        TARBALL.parent.mkdir(parents=True, exist_ok=True)
        urllib.request.urlretrieve(URL, TARBALL)
    actual = sha256(TARBALL)
    if actual != TARBALL_SHA256:
        raise RuntimeError(f"Tarball SHA-256 mismatch: {actual} != {TARBALL_SHA256}")

    expected = patch_stamp(patches)
    sentinel = SOURCE / "src/iup_draw.c"
    need = (fresh or not sentinel.exists() or not STAMP.exists()
            or STAMP.read_text().strip() != expected)
    if not need:
        if "iupFlatDrawGradient" not in sentinel.read_text(errors="replace"):
            raise RuntimeError(f"Patch sentinel missing from {sentinel}")
        return False

    if SOURCE.exists():
        shutil.rmtree(SOURCE)
    STAMP.unlink(missing_ok=True)
    ROOT.mkdir(parents=True, exist_ok=True)
    print(f"Extracting {TARBALL}", flush=True)
    with tarfile.open(TARBALL, "r:gz") as archive:
        # The pinned upstream archive contains one top-level iup/ directory.
        for member in archive.getmembers():
            target = (ROOT / member.name).resolve()
            if not target.is_relative_to(ROOT.resolve()) or member.issym() or member.islnk():
                raise RuntimeError(f"Unsafe tar member: {member.name}")
        archive.extractall(ROOT, filter="data")
    if not (SOURCE / "src/config.mak").exists():
        raise RuntimeError("IUP source extraction did not produce src/config.mak")

    for patch in patches:
        print(f"Applying {patch.name}", flush=True)
        # git apply can silently skip every file under gitignored vendor/.
        run(["patch", "-p1", "--forward", "--batch", "-i", patch], cwd=SOURCE)
    if "iupFlatDrawGradient" not in sentinel.read_text(errors="replace"):
        raise RuntimeError(f"Patch sentinel missing from {sentinel}")
    STAMP.write_text(expected + "\n")
    print("Patched source verified", flush=True)
    return True


def assignment(config, name):
    """Read one literal multiline make assignment (no make interpreter needed)."""
    lines = config.read_text().splitlines()
    for index, line in enumerate(lines):
        match = re.match(r"^" + re.escape(name) + r"\s*(?::=|=)\s*(.*)$", line)
        if match:
            parts = []
            while True:
                value = match.group(1) if not parts else line
                more = value.rstrip().endswith("\\")
                parts.append(value.rstrip().rstrip("\\"))
                if not more:
                    return " ".join(parts).split()
                index += 1
                line = lines[index]
    raise RuntimeError(f"Missing {name} in {config}")


def appended_sources(config, anchor):
    """Read the SRC += continuation immediately after a known branch marker."""
    data = config.read_text()
    start = data.find(anchor)
    if start < 0:
        raise RuntimeError(f"Missing branch marker {anchor!r} in {config}")
    lines = data[start:].splitlines()
    first = next((i for i, line in enumerate(lines) if re.match(r"^\s*SRC\s*\+=", line)), None)
    if first is None:
        raise RuntimeError(f"Missing SRC += after {anchor!r}")
    line = re.sub(r"^\s*SRC\s*\+=\s*", "", lines[first])
    parts = []
    index = first
    while True:
        more = line.rstrip().endswith("\\")
        parts.append(line.rstrip().rstrip("\\"))
        if not more:
            return " ".join(parts).split()
        index += 1
        line = lines[index]


def source_lists():
    core_config = SOURCE / "src/config.mak"
    lua_config = SOURCE / "srclua5/config.mak"
    # Explicit branch markers prevent accidentally selecting Motif or GTK2.
    core = assignment(core_config, "SRC")
    core += appended_sources(core_config, "INCLUDES += gtk\n")
    core += appended_sources(core_config, "ifdef USE_GTK3\n    SRC += gtk/iupgtk_draw_cairo.c")
    core += appended_sources(core_config, "SRC += gtk/iupgtk_help.c mot/iupunix_info.c")
    core += appended_sources(core_config, "ifdef USE_GTK3\n        SRC += gtk/iupgtk_info.c")
    # The first append above includes the entire GTK common list; the latter two
    # name the Linux X11 help/info files and the GTK3-specific info file.
    lua_scripts = assignment(lua_config, "CTRLUA")
    lua_core = assignment(lua_config, "SRC")
    lua_core = [("elem/il_" + Path(name).stem + ".c") if item == "$(GC)" else item
                for item in lua_core for name in (lua_scripts if item == "$(GC)" else [item])]
    core = list(dict.fromkeys(core))
    return core, lua_core, ["iuplua.lua", "constants.lua", "iup_config.lua"] + lua_scripts


def generate_headers(lua_scripts):
    """Generate IUP's .lh include blocks with Lua source bytes, never bytecode."""
    header_dir = BUILD / "lh"
    header_dir.mkdir(parents=True, exist_ok=True)
    changed = False
    for name in lua_scripts:
        source = SOURCE / "srclua5" / ("elem" if name not in
                 {"iuplua.lua", "constants.lua", "iup_config.lua"} else "") / name
        destination = header_dir / (Path(name).stem + ".lh")
        if destination.exists() and destination.stat().st_mtime_ns >= source.stat().st_mtime_ns:
            continue
        changed = True
        data = source.read_bytes()
        # Hex escapes represent exact source bytes, including non-ASCII text.
        chunks = ["\"" + "".join(f"\\x{byte:02x}" for byte in data[i:i + 32]) + "\""
                  for i in range(0, len(data), 32)]
        code = ("/* Generated Lua source for LuaJIT; do not edit. */\n{\n"
                "static const char source[] =\n" + "\n".join(chunks) + ";\n"
                f'iuplua_dobuffer(L, source, sizeof(source) - 1, "={name}");\n}}\n')
        destination.write_text(code)
    return changed


def depfile_inputs(depfile):
    """Paths named by a gcc -MMD dependency file (the object's sources and headers)."""
    text = depfile.read_text(errors="replace").replace("\\\n", " ")
    _, _, deps = text.partition(": ")
    # Spaces inside paths are escaped as "\ "; IUP's tree has none, but keep them intact.
    return [Path(d.replace("\\ ", " ")) for d in re.split(r"(?<!\\) +", deps.strip()) if d]


def object_stale(obj, depfile):
    """True when the object is missing or older than any source or header it was built from."""
    if not obj.exists() or not depfile.exists():
        return True
    built = obj.stat().st_mtime_ns
    try:
        return any(dep.stat().st_mtime_ns > built for dep in depfile_inputs(depfile))
    except OSError:
        return True  # a dependency vanished: rebuild and let gcc report it


def compile_archive(label, source_root, sources, flags, clean):
    obj_dir = BUILD / "obj" / label
    obj_dir.mkdir(parents=True, exist_ok=True)
    archive = BUILD / ("libiup.a" if label == "iup" else "libiuplua51.a")
    # A change of compiler, flags or source list invalidates every object. The
    # stamp is written only after the archive is complete, so an interrupted
    # build is redone on the next run.
    gcc_version = subprocess.check_output(["gcc", "-dumpfullversion"], text=True).strip()
    config = hashlib.sha256("\n".join(map(str, [gcc_version, *CFLAGS, *flags, *sources])).encode()).hexdigest()
    config_stamp = obj_dir / ".config"
    if not config_stamp.exists() or config_stamp.read_text().strip() != config:
        clean = True
        config_stamp.unlink(missing_ok=True)
    objects = []
    compiled = 0
    for relative in sources:
        source = source_root / relative
        if not source.is_file():
            raise RuntimeError(f"Source listed by IUP is missing: {source}")
        obj = obj_dir / (relative.replace("/", "__") + ".o")
        depfile = obj.with_suffix(".d")
        objects.append(obj)
        if not clean and not object_stale(obj, depfile):
            continue
        print(f"Compiling {relative}", flush=True)
        try:
            run(["gcc", *CFLAGS, *flags, "-MMD", "-MF", depfile, "-c", source, "-o", obj], verbose=False)
        except subprocess.CalledProcessError as exc:
            obj.unlink(missing_ok=True)
            raise RuntimeError(f"Compilation failed: {source}") from exc
        compiled += 1
    newest = max(o.stat().st_mtime_ns for o in objects)
    if compiled or not archive.exists() or archive.stat().st_mtime_ns < newest:
        archive.unlink(missing_ok=True)
        run(["ar", "rcs", archive, *objects], verbose=False)
    config_stamp.write_text(config + "\n")
    print(f"{archive.name}: {compiled} compiled, {len(objects) - compiled} current", flush=True)


def build_smoke(gtk_cflags, link_flags):
    smoke = SMOKE_SOURCE
    executable = BUILD / "iup_smoke"
    dependencies = [smoke, BUILD / "libiuplua51.a", BUILD / "libiup.a", BUILD / "link-flags.txt"]
    if executable.exists() and all(executable.stat().st_mtime_ns >= p.stat().st_mtime_ns for p in dependencies):
        print("iup_smoke: current", flush=True)
        return
    run(["gcc", "-O2", "-g", *gtk_cflags, "-I", SOURCE / "include", "-I", LUA_HEADERS,
         smoke, BUILD / "libiuplua51.a", BUILD / "libiup.a", LUA_LIB,
         *link_flags, "-o", executable])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fresh", action="store_true", help="re-extract and patch upstream sources")
    parser.add_argument("--clean", action="store_true", help="wipe object cache and rebuild")
    parser.add_argument("--smoke", action="store_true", help=f"also build iup_smoke from {SMOKE_SOURCE.relative_to(REPO)}")
    parser.add_argument("--luajit-prefix", default=os.environ.get("LUNAR_LUAJIT_PREFIX") or "/usr/local",
                        help="LuaJIT install prefix (default: $LUNAR_LUAJIT_PREFIX or /usr/local)")
    args = parser.parse_args()
    global LUA_HEADERS, LUA_LIB
    LUA_HEADERS = Path(args.luajit_prefix) / "include/luajit-2.1"
    LUA_LIB = Path(args.luajit_prefix) / "lib/libluajit-5.1.a"
    if sys.platform != "linux":
        raise RuntimeError("This builder currently supports Linux only")
    patches = sorted((REPO / "iup-fork/patches").glob("*.patch"))
    if not patches:
        raise RuntimeError("No IUP fork patches found")
    if not LUA_HEADERS.is_dir() or not LUA_LIB.is_file():
        raise RuntimeError(f"LuaJIT headers or static library missing under {args.luajit_prefix}")
    prepared = prepare(args.fresh, patches)
    if args.clean or prepared:
        shutil.rmtree(BUILD / "obj", ignore_errors=True)
        shutil.rmtree(BUILD / "lh", ignore_errors=True)
    BUILD.mkdir(parents=True, exist_ok=True)
    core, lua, scripts = source_lists()
    generate_headers(scripts)  # .lh changes reach the objects through their .d files
    gtk_cflags = shlex.split(subprocess.check_output(["pkg-config", "--cflags", "gtk+-3.0"], text=True))
    gtk_libs = shlex.split(subprocess.check_output(["pkg-config", "--libs", "gtk+-3.0"], text=True))
    # GTK's pkg-config metadata omits X11/Xext, used directly by IUP's X11 code.
    link_flags = gtk_libs + ["-lX11", "-lXext", "-lm", "-ldl", "-pthread"]
    flags_file = BUILD / "link-flags.txt"
    desired = " ".join(link_flags) + "\n"
    if not flags_file.exists() or flags_file.read_text() != desired:
        flags_file.write_text(desired)
    core_flags = ["-DUSE_GTK3", "-DGTK_DISABLE_DEPRECATED", "-DGDK_DISABLE_DEPRECATED",
                  "-DGSEAL_ENABLE", "-I", SOURCE / "include", "-I", SOURCE / "src",
                  "-I", SOURCE / "src/gtk", *gtk_cflags]
    lua_flags = ["-DIUPLUA_USELH", "-I", BUILD / "lh", "-I", SOURCE / "include",
                 "-I", SOURCE / "src", "-I", SOURCE / "srclua5", "-I", LUA_HEADERS]
    compile_archive("iup", SOURCE / "src", core, core_flags, args.clean or prepared)
    compile_archive("iuplua51", SOURCE / "srclua5", lua, lua_flags, args.clean or prepared)
    if args.smoke:
        build_smoke(gtk_cflags, link_flags)
    print(f"Build complete: {BUILD}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError, tarfile.TarError) as exc:
        print(f"build_iup.py: {exc}", file=sys.stderr)
        sys.exit(1)
