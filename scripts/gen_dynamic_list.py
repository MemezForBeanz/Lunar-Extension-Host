#!/usr/bin/env python3
"""Translate the portable host exports from a Windows .def to GNU ld inputs."""

import argparse
from pathlib import Path
import re


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("definitions", type=Path)
    parser.add_argument("dynamic_list", type=Path)
    parser.add_argument("response", type=Path)
    args = parser.parse_args()

    symbols = []
    for line in args.definitions.read_text(encoding="utf-8").splitlines():
        line = line.split(";;", 1)[0].strip()
        if not re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*", line) or line == "EXPORTS":
            continue
        lower = line.lower()
        if ("win32" in lower or lower.startswith("iupwin") or line.endswith("WDL") or
                line.startswith("luaJIT_version_") or
                line in {"iupFontGetWinName", "iupFontParseWin",
                         "iupdrvDrawFlatRoundBorder", "iupdrvDrawFlatRoundBox",
                         "luaopen_subprocess", "luaopen_process", "luaopen_winredraw"}):
            continue
        symbols.append(line)

    args.dynamic_list.parent.mkdir(parents=True, exist_ok=True)
    args.dynamic_list.write_text("{\n" + "".join(f"  {s};\n" for s in symbols) + "};\n",
                                 encoding="utf-8")
    args.response.write_text("".join(f"-Wl,--undefined={s}\n" for s in symbols),
                             encoding="utf-8")
    print(f"Generated {len(symbols)} portable symbol requests")


if __name__ == "__main__":
    main()
