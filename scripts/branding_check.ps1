# Native branding regression checks against the built GUI executable, without showing it.
param([string]$Packs, [string]$Exe)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $Packs) { $Packs = Join-Path $repo '../lunar-orgpacks' }
if (-not $Exe) { $Exe = Join-Path $repo 'build/rel/bin/Lunar.exe' }
$fixtures = Join-Path $repo 'build/branding-fixtures'
@'
from pathlib import Path
import struct, sys, zlib
p = Path(sys.argv[1])
p.mkdir(parents=True, exist_ok=True)
def chunk(tag, data):
    return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data))
def header(w, h):
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
# 2x2: opaque red beside fully transparent blue, in both rows.
row = b'\x00' + bytes([255, 0, 0, 255, 0, 0, 255, 0])
png = header(2, 2) + chunk(b'IDAT', zlib.compress(row * 2)) + chunk(b'IEND', b'')
(p / 'alpha.png').write_bytes(png)
(p / 'oversized.png').write_bytes(b'\0' * (8 * 1024 * 1024 + 1))
(p / 'dimensions.png').write_bytes(header(8193, 1) + chunk(b'IEND', b''))
(p / 'corrupt.png').write_bytes(b'not a png')
(p / 'truncated.png').write_bytes(png[:40])
'@ | python - $fixtures
if ($LASTEXITCODE -ne 0) { throw 'Could not create PNG fixtures' }
$env:LUNAR_REPO = $repo
$env:LUNAR_PROFILE_DIR = (Resolve-Path -LiteralPath $Packs).Path
$script = Join-Path $PSScriptRoot 'branding_check.lua'
$process = Start-Process -FilePath $Exe -ArgumentList ('"' + $script + '"') -WorkingDirectory (Split-Path $Exe) -WindowStyle Hidden -PassThru -Wait
Get-Content -LiteralPath (Join-Path $repo 'build/branding-check.txt')
exit $process.ExitCode
