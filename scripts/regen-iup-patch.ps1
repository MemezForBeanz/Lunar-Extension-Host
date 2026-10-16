# scripts/regen-iup-patch.ps1 — regenerate the IUP fork patch from the working tree.
#
# The Lunar IUP fork is stored as a patch series (iup-fork\patches\*.patch) applied
# onto a pristine upstream extract, not as a committed source tree — vendor\ is
# gitignored and regenerated. See iup-fork\README.md for why.
#
# The cost of that choice used to be the regeneration ritual: hand-build a
# throwaway git repo from a pristine extract, overlay the edited files, and remember
# to write the diff with `--output=` so it keeps LF endings. This script does all
# of that, and then *verifies* the result by applying it to a fresh pristine tree.
#
# Workflow:
#   1. scripts\build-iup-fork.ps1          # extracts + patches vendor\iup-src\iup
#   2. edit vendor\iup-src\iup\src\...     # make your changes in place
#   3. scripts\regen-iup-patch.ps1         # capture them back into iup-fork\patches
#   4. scripts\build-iup-fork.ps1          # stamp changed -> re-extract, re-apply, rebuild
#
# Usage:
#   scripts\regen-iup-patch.ps1
#   scripts\regen-iup-patch.ps1 -PatchName 0002-my-change.patch
#   scripts\regen-iup-patch.ps1 -Collapse   # required when the series has >1 patch

param(
	[string]$PatchName,
	[switch]$Collapse
)

$ErrorActionPreference = "Continue"   # native tools (git, tar, robocopy) write
                                      # progress to stderr; rely on explicit
                                      # $LASTEXITCODE checks + throw instead.
$repo = Split-Path -Parent $PSScriptRoot

$srcRoot  = Join-Path $repo "vendor\iup-src\iup"
$patchDir = Join-Path $repo "iup-fork\patches"
$tarball  = Join-Path $repo "vendor\iup-src\downloads\iup-3.32_Sources.tar.gz"

if (-not (Test-Path (Join-Path $srcRoot "src"))) {
	throw "No working IUP tree at $srcRoot. Run scripts\build-iup-fork.ps1 first."
}
if (-not (Test-Path $tarball)) {
	throw "Pristine source tarball missing at $tarball. Run scripts\build-iup-fork.ps1 to download it."
}

$existing = @(Get-ChildItem (Join-Path $patchDir "*.patch") -ErrorAction SilentlyContinue | Sort-Object Name)

# Regenerating produces ONE diff of the whole tree, so it cannot preserve a
# multi-patch series — running it blind would silently collapse the history into
# a single file and delete the rest. Make that an explicit choice.
if ($existing.Count -gt 1 -and -not $Collapse -and -not $PatchName) {
	throw ("The series has $($existing.Count) patches: " + (($existing | ForEach-Object { $_.Name }) -join ', ') + "`n" +
	       "Regenerating collapses them into a single diff. Re-run with -Collapse to accept that, " +
	       "or with -PatchName to write a specific file.")
}

if (-not $PatchName) {
	$PatchName = if ($existing.Count -ge 1) { $existing[0].Name } else { "0001-lunar.patch" }
}
if ($PatchName -notlike "*.patch") { $PatchName = "$PatchName.patch" }
$patchPath = Join-Path $patchDir $PatchName

# --- build a throwaway git repo rooted at the pristine iup/ directory ----------------
# Rooting the repo at iup/ (not its parent) is what makes the diff paths come out as
# `src/iup_draw.c`, which is exactly what build-iup-fork.ps1's
# `git apply -p1 --directory=vendor/iup-src/iup` expects.
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("lunar-iup-regen-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null

try {
	Write-Host "Extracting pristine IUP 3.32..." -ForegroundColor Cyan
	& tar.exe -xzf $tarball -C $work
	$pristine = Join-Path $work "iup"
	if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $pristine "src"))) {
		throw "Failed to extract $tarball into $work"
	}

	# core.autocrlf=false everywhere: the upstream sources are LF, and a patch with
	# CRLF endings will not apply onto them.
	$git = @("-c", "core.autocrlf=false", "-c", "core.safecrlf=false", "-C", $pristine)

	Write-Host "Snapshotting pristine tree..." -ForegroundColor Cyan
	& git @git init --quiet
	if ($LASTEXITCODE -ne 0) { throw "git init failed in $pristine" }

	# Normalize every blob to LF *in the index* on both sides of the diff. Without
	# this, a working tree whose patched files happen to be CRLF (which is what
	# `git apply` produces under a global core.autocrlf=true) diffs as a complete
	# rewrite of every touched file, burying the real edits in thousands of
	# line-ending-only changes. Using .git/info/attributes rather than a
	# .gitattributes file keeps it out of the worktree, and therefore out of the
	# generated patch.
	$attrDir = Join-Path $pristine ".git\info"
	New-Item -ItemType Directory -Force -Path $attrDir | Out-Null
	Set-Content -Path (Join-Path $attrDir "attributes") -Value "* text=auto eol=lf" -Encoding ascii

	& git @git add -A
	if ($LASTEXITCODE -ne 0) { throw "git add failed for the pristine tree" }
	& git @git -c user.name=lunar -c user.email=lunar@localhost commit --quiet -m "pristine iup-3.32"
	if ($LASTEXITCODE -ne 0) { throw "git commit failed for the pristine tree" }

	Write-Host "Overlaying working tree from $srcRoot..." -ForegroundColor Cyan
	# /MIR so deletions are captured too; /XD .git protects the snapshot repo.
	& robocopy.exe $srcRoot $pristine /MIR /XD (Join-Path $pristine ".git") /NFL /NDL /NJH /NJS /NP | Out-Null
	# robocopy exit codes < 8 are success (0-7 are informational bit flags).
	if ($LASTEXITCODE -ge 8) { throw "robocopy failed copying $srcRoot -> $pristine (exit $LASTEXITCODE)" }
	$global:LASTEXITCODE = 0

	Write-Host "Diffing..." -ForegroundColor Cyan
	& git @git add -A
	if ($LASTEXITCODE -ne 0) { throw "git add failed for the edited tree" }

	New-Item -ItemType Directory -Force -Path $patchDir | Out-Null
	$tmpPatch = Join-Path $work "out.patch"
	# --output= (rather than a redirect) is what keeps LF line endings intact.
	& git @git diff --cached --binary --output="$tmpPatch"
	if ($LASTEXITCODE -ne 0) { throw "git diff failed" }

	if (-not (Test-Path $tmpPatch) -or (Get-Item $tmpPatch).Length -eq 0) {
		throw ("The working tree is identical to pristine IUP 3.32 - nothing to capture.`n" +
		       "Refusing to write an empty patch (that would silently drop the fork). " +
		       "Did you edit $srcRoot, or has build-iup-fork.ps1 re-extracted over your changes?")
	}

	# --- verify: the regenerated patch must apply to a fresh pristine tree ------------
	Write-Host "Verifying the patch applies to a clean extract..." -ForegroundColor Cyan
	$verify = Join-Path $work "verify"
	New-Item -ItemType Directory -Force -Path $verify | Out-Null
	& tar.exe -xzf $tarball -C $verify
	if ($LASTEXITCODE -ne 0) { throw "Failed to extract $tarball into $verify" }
	$applyOut = & git -c core.autocrlf=false -C $verify apply -p1 --directory="iup" --whitespace=nowarn --verbose $tmpPatch 2>&1
	if ($LASTEXITCODE -ne 0) {
		$applyOut | ForEach-Object { Write-Host "    $_" }
		throw "The regenerated patch does not apply to a pristine tree - not writing it."
	}
	if ($applyOut -match 'Skipped patch') {
		$applyOut | ForEach-Object { Write-Host "    $_" }
		throw "The regenerated patch was silently skipped on apply - not writing it."
	}

	Copy-Item $tmpPatch $patchPath -Force

	# Any other patch in the series is now folded into this one.
	if ($Collapse) {
		foreach ($old in $existing) {
			if ($old.FullName -ne $patchPath) {
				Write-Host "  removing collapsed patch $($old.Name)" -ForegroundColor DarkYellow
				Remove-Item $old.FullName -Force
			}
		}
	}

	$changed = (& git @git diff --cached --name-only) -split "`n" | Where-Object { $_ }
	Write-Host "`nWrote $patchPath" -ForegroundColor Green
	Write-Host "  $($changed.Count) file(s) changed:" -ForegroundColor Green
	$changed | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
	Write-Host "`nThe patch stamp has changed, so the next scripts\build-iup-fork.ps1 will" -ForegroundColor Cyan
	Write-Host "re-extract and re-apply from scratch (a full rebuild of libiup.a)." -ForegroundColor Cyan
} finally {
	Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
