# Convenience targets for the command line (Windows: `mingw32-make <target>` from
# MSYS2, which is on PATH in the VS Code terminal). The real build is CMake with
# the presets in CMakePresets.json; VS Code users can use the tasks instead
# (Ctrl+Shift+B builds, "Tasks: Run Task" lists the rest).
#
#   make build      configure + build the dev tree   (build/win)
#   make release    configure + build what ships      (build/rel)
#   make run        build, then start the dev build
#   make run-packs  ...with ../lunar-orgpacks as dev org packs
#   make test       busted suite
#   make lint       luacheck
#   make docs       LDoc site + warning check
#   make check      test + lint + docs
#   make harness    end-to-end process check (needs MSYS2 python)
#   make clean      delete both build trees

PS := powershell -NoProfile -Command

.PHONY: build release run run-packs test lint docs check harness clean

build:
	cmake --preset dev && cmake --build --preset dev

release:
	cmake --preset release && cmake --build --preset release

run: build
	$(PS) "Start-Process build/win/bin/Lunar.exe -WorkingDirectory build/win/bin"

run-packs: build
	$(PS) "$$env:LUNAR_PROFILE_DIR = (Resolve-Path ../lunar-orgpacks).Path; Start-Process build/win/bin/Lunar.exe -WorkingDirectory build/win/bin"

test:
	powershell -NoProfile -File scripts/test.ps1

lint:
	powershell -NoProfile -File scripts/lint.ps1

docs:
	powershell -NoProfile -File scripts/docs.ps1 -OutDir dist/docs-ci -Check

check: test lint docs

harness: build
	$(PS) "$$env:LUA_PATH = 'src/lua/?.lua;vendor/luarocks-tree/share/lua/5.1/?.lua;;'; $$env:LUNAR_REPO = (Get-Location).Path; build/win/bin/LunarCLI.exe scripts/process_check.lua C:/msys64/mingw64/bin/python.exe; exit $$LASTEXITCODE"

clean:
	$(PS) "Remove-Item -Recurse -Force build/win, build/rel -ErrorAction SilentlyContinue"
