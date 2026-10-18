<#
.SYNOPSIS
    Rebuild the vendored static OpenSSL (vendor\openssl) with unused features
    disabled, to keep the shipped executable small.

.DESCRIPTION
    vendor\openssl used to hold a stock MSYS2 build of OpenSSL 3.6.1, whose
    libcrypto.a alone is 9.55 MB and which contributed more to the executable
    than anything else. The app only ever needs a TLS *client*: the feedback
    backend, HTTPS calls extensions make, and the GitHub release check.

    What the backend actually negotiates (measured with `openssl s_client`):
        Protocol   TLSv1.3
        Cipher     TLS_AES_256_GCM_SHA384
        Signature  rsa_pss_rsae_sha256
        Group      X25519MLKEM768   <-- hybrid post-quantum ML-KEM

    So ML-KEM, X25519, RSA-PSS, AES-GCM and SHA-2 are all load-bearing and must
    stay enabled. TLS 1.2 stays as well, for older servers.

    Deliberately NOT passed:
      no-deprecated  LuaSec's context.c/x509.c use EC_KEY, RSA_* and DH_* APIs
                     that OpenSSL 3.x marks deprecated. Disabling them fails the
                     LuaSec compile outright.
      no-des         Kept: 3DES/DES-CBC still show up in legacy PEM and PKCS#12
                     handling, and the code is small.

    no-asm is the single largest saving here (~1.1 MB): the AVX-512 AES-GCM
    routines alone are 330 KB each, plus ~180 KB of precomputed curve tables.
    The trade is software crypto instead of hardware-accelerated. For a tool that
    makes intermittent REST calls with small JSON payloads that is not a
    measurable difference; do not copy this choice into a throughput-sensitive
    project.

.PARAMETER Version
    OpenSSL version to build. Must match the vendored headers' OPENSSL_VERSION_STR.

.PARAMETER WorkDir
    Scratch directory for the source tree and build.

.PARAMETER SkipDownload
    Reuse an already-downloaded/extracted source tree in WorkDir.

.EXAMPLE
    scripts\build-openssl.ps1

.NOTES
    Requires MSYS2 with the mingw64 toolchain (gcc, mingw32-make) and perl.
    After running, rebuild the app and check what it negotiates:
        build\win\bin\LunarCLI.exe scripts\tls_check.lua <host> [port]
#>
[CmdletBinding()]
param(
    [string] $Version = '3.6.1',
    [string] $WorkDir = "$env:TEMP\openssl-build",
    [switch] $SkipDownload
)

$ErrorActionPreference = 'Stop'

$RepoRoot  = Split-Path -Parent $PSScriptRoot
$VendorSsl = Join-Path $RepoRoot 'vendor\openssl'
$Msys      = 'C:\msys64'
$Bash      = Join-Path $Msys 'usr\bin\bash.exe'

if (-not (Test-Path $Bash)) { throw "MSYS2 bash not found at $Bash" }

# The configure options, kept here so the vendored binaries are reproducible.
# Anything added must be justified against the negotiated profile documented above.
$ConfigOpts = @(
    'no-shared', 'no-tests', 'no-apps', 'no-docs'
    'no-quic', 'no-ssl3', 'no-ssl3-method', 'no-dtls'
    'no-comp', 'no-zlib', 'no-brotli', 'no-zstd'
    'no-legacy', 'no-engine', 'no-module', 'no-async', 'no-ui-console'
    'no-srp', 'no-cmp', 'no-cms', 'no-ts', 'no-ocsp'
    'no-gost', 'no-camellia', 'no-seed', 'no-idea', 'no-rc2', 'no-rc4', 'no-rc5'
    'no-md4', 'no-mdc2', 'no-whirlpool', 'no-rmd160'
    'no-sm2', 'no-sm3', 'no-sm4'
    'no-cast', 'no-bf', 'no-aria', 'no-ec2m'
    'no-asm'
)

$tarball = "openssl-$Version.tar.gz"
$srcUrl  = "https://github.com/openssl/openssl/releases/download/openssl-$Version/$tarball"
# Pinned here, not fetched beside the tarball: a checksum from the same server
# only catches a corrupt download, not a replaced one. Update with -Version.
$PinnedSha256 = @{
    '3.6.1' = 'b1bfedcd5b289ff22aee87c9d600f515767ebf45f77168cb6d64f231f518a82e'
}

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$tarPath = Join-Path $WorkDir $tarball

if (-not $SkipDownload) {
    Write-Host "==> Downloading $tarball" -ForegroundColor Cyan
    Invoke-WebRequest -Uri $srcUrl -OutFile $tarPath -UseBasicParsing -TimeoutSec 600
}

Write-Host "==> Verifying checksum" -ForegroundColor Cyan
$pinned = $PinnedSha256[$Version]
if (-not $pinned) { throw "No pinned SHA-256 for OpenSSL $Version; add it to `$PinnedSha256 after checking the release." }
$local = (Get-FileHash $tarPath -Algorithm SHA256).Hash.ToLower()
if ($local -ne $pinned) { throw "checksum mismatch for ${tarball}: pinned $pinned, got $local" }
Write-Host "    sha256 ok: $local"

# MSYS2 tools need the source under a path bash can reach without drive-letter
# translation quirks, so everything happens in the MSYS2 /tmp tree.
$msysWork = '/tmp/openssl-build'
$hostWork = Join-Path $Msys 'tmp\openssl-build'

Write-Host "==> Staging source into MSYS2 /tmp" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $hostWork | Out-Null
Copy-Item -LiteralPath $tarPath -Destination (Join-Path $hostWork $tarball) -Force

$script = @"
set -e
export PATH=/mingw64/bin:/usr/bin:`$PATH
cd $msysWork
rm -rf openssl-$Version
tar xzf $tarball
cd openssl-$Version
perl ./Configure mingw64 $($ConfigOpts -join ' ') --prefix=$msysWork/out
mingw32-make -j4 build_libs
"@

$scriptPath = Join-Path $hostWork 'build.sh'
Set-Content -LiteralPath $scriptPath -Value ($script -replace "`r`n", "`n") -NoNewline -Encoding ASCII

Write-Host "==> Configuring and building (several minutes)" -ForegroundColor Cyan
& {
    $ErrorActionPreference = 'Continue'
    & $Bash -lc "bash $msysWork/build.sh" 2>&1 | Out-Null
}
if ($LASTEXITCODE -ne 0) { throw "OpenSSL build failed ($LASTEXITCODE). See $hostWork" }

$builtCrypto = Join-Path $hostWork "openssl-$Version\libcrypto.a"
$builtSsl    = Join-Path $hostWork "openssl-$Version\libssl.a"
foreach ($f in @($builtCrypto, $builtSsl)) {
    if (-not (Test-Path $f)) { throw "expected build output missing: $f" }
}

Write-Host "==> Installing into vendor\openssl" -ForegroundColor Cyan
foreach ($d in 'lib', 'include\openssl') { New-Item -ItemType Directory -Force -Path (Join-Path $VendorSsl $d) | Out-Null }
Copy-Item -LiteralPath $builtCrypto -Destination (Join-Path $VendorSsl 'lib\libcrypto.a') -Force
Copy-Item -LiteralPath $builtSsl    -Destination (Join-Path $VendorSsl 'lib\libssl.a')    -Force

# The headers come from the same build: build_libs generates the version and
# feature headers (configuration.h records what is enabled), so they always
# match the archives. A fresh checkout gets them from here too.
$builtInc = Join-Path $hostWork "openssl-$Version\include\openssl"
Copy-Item -Path (Join-Path $builtInc '*.h') -Destination (Join-Path $VendorSsl 'include\openssl') -Force

Write-Host ""
Write-Host "Installed:" -ForegroundColor Green
Get-ChildItem (Join-Path $VendorSsl 'lib') -Filter *.a |
    ForEach-Object { "  {0,-16} {1,8:N2} MB" -f $_.Name, ($_.Length / 1MB) }
Write-Host ""
Write-Host "Now rebuild and run the TLS regression:" -ForegroundColor Yellow
Write-Host "  cmake --build --preset dev"
Write-Host "  build\win\bin\LunarCLI.exe scripts\tls_check.lua <host> [port]"
