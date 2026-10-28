param(
    [Parameter(Mandatory = $true)][string]$BundleArchive,
    [string]$ArtifactDir = ''
)
$ErrorActionPreference = 'Stop'
$projectDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $ArtifactDir) { $ArtifactDir = Join-Path $projectDir 'build\artifacts' }
New-Item -ItemType Directory -Force $ArtifactDir | Out-Null
$bundleArchivePath = (Resolve-Path $BundleArchive).Path
$staging = Join-Path $projectDir 'build\single-exe-bundle'
$payloadArchive = Join-Path $projectDir 'build\single-exe-payload.zip'
$portable = Join-Path $ArtifactDir 'Xiaomi-Lightbar-Windows-x86_64.exe'
if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
Expand-Archive -Path $bundleArchivePath -DestinationPath $staging -Force

# Use the redistributable x64 CRT files shipped with Visual Studio. Keeping
# these next to the extracted app avoids requiring a separate runtime install.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { throw 'Visual Studio vswhere.exe was not found.' }
$install = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $install) { throw 'A Visual Studio C++ installation was not found.' }
$redistRoot = Join-Path $install 'VC\Redist\MSVC'
if (-not (Test-Path $redistRoot)) { throw 'Visual C++ redistributable files were not found.' }
$requiredCrt = @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')
$crtDirectory = $null
$redistDirs = @(Get-ChildItem $redistRoot -Directory)
$numbered = @($redistDirs | Where-Object { $_.Name -match '^\d+(\.\d+){1,3}$' } | Sort-Object { [version]$_.Name } -Descending)
$aliases = @($redistDirs | Where-Object { $_.Name -match '^v\d+$' } | Sort-Object Name -Descending)
foreach ($version in ($numbered + $aliases)) {
    $archDir = Join-Path $version.FullName 'x64'
    if (-not (Test-Path $archDir)) { continue }
    foreach ($candidate in (Get-ChildItem $archDir -Directory -Filter 'Microsoft.VC*.CRT')) {
        $missing = @($requiredCrt | Where-Object { -not (Test-Path (Join-Path $candidate.FullName $_)) })
        if ($missing.Count -eq 0) { $crtDirectory = $candidate.FullName; break }
    }
    if ($crtDirectory) { break }
}
if (-not $crtDirectory) { throw 'The required x64 Visual C++ redistributable DLLs were not found.' }
foreach ($name in $requiredCrt) { Copy-Item (Join-Path $crtDirectory $name) $staging }
Copy-Item (Join-Path $projectDir 'docs\WINDOWS-SINGLE-EXE.txt') (Join-Path $staging 'README.txt') -Force

# The launcher itself uses the static CRT, so it starts even on a system that
# has not installed the shared Visual C++ runtime yet.
$oldRustFlags = $env:RUSTFLAGS
try {
    $env:RUSTFLAGS = "$oldRustFlags -C target-feature=+crt-static"
    cargo test --locked --manifest-path (Join-Path $projectDir 'windows-launcher\Cargo.toml') --target x86_64-pc-windows-msvc
    if ($LASTEXITCODE -ne 0) { throw 'Single-file launcher tests failed.' }
    cargo build --locked --release --manifest-path (Join-Path $projectDir 'windows-launcher\Cargo.toml') --target x86_64-pc-windows-msvc
    if ($LASTEXITCODE -ne 0) { throw 'Single-file launcher build failed.' }
} finally {
    $env:RUSTFLAGS = $oldRustFlags
}
python (Join-Path $projectDir 'scripts\collect-launcher-notices.py') (Join-Path $staging 'LAUNCHER_NOTICES.txt')
if ($LASTEXITCODE -ne 0) { throw 'Launcher notice collection failed.' }
Compress-Archive -Force -Path (Join-Path $staging '*') -DestinationPath $payloadArchive
$stub = Join-Path $projectDir 'windows-launcher\target\x86_64-pc-windows-msvc\release\lightbar-launcher.exe'
python (Join-Path $projectDir 'scripts\package-single-exe.py') $stub $payloadArchive $portable
if ($LASTEXITCODE -ne 0) { throw 'Single-file packaging failed.' }

# Exercise the actual EXE twice, then start the bundled GUI on the Windows
# runner and ensure it remains alive for ten seconds without attached hardware.
$oldCache = $env:LIGHTBAR_LAUNCHER_CACHE
$oldDiagnostic = $env:LIGHTBAR_LAUNCHER_DIAGNOSTIC
$cache = Join-Path $projectDir 'build\single-exe-test-cache'
$diagnostic = Join-Path $projectDir 'build\single-exe-test-error.txt'
if (Test-Path $cache) { Remove-Item -Recurse -Force $cache }
if (Test-Path $diagnostic) { Remove-Item -Force $diagnostic }
try {
    $env:LIGHTBAR_LAUNCHER_CACHE = $cache
    $env:LIGHTBAR_LAUNCHER_DIAGNOSTIC = $diagnostic
    $firstLaunch = $true
    foreach ($argument in @('--verify-only', '--verify-only', '--smoke-test')) {
        $process = Start-Process -FilePath $portable -ArgumentList $argument -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            $details = if (Test-Path $diagnostic) { Get-Content -Raw $diagnostic } else { 'No launcher diagnostic was produced.' }
            throw "Single-file validation failed for $argument`: $details"
        }
        if ($firstLaunch) {
            $extracted = @(Get-ChildItem $cache -Directory)
            if ($extracted.Count -ne 1) { throw 'The launcher did not produce exactly one runtime cache.' }
            python (Join-Path $projectDir 'core\tests\windows_smoke.py') (Join-Path $extracted[0].FullName 'lightbar_core.dll')
            if ($LASTEXITCODE -ne 0) { throw 'The packaged Windows core smoke test failed.' }
            $firstLaunch = $false
        }
    }
} finally {
    $env:LIGHTBAR_LAUNCHER_CACHE = $oldCache
    $env:LIGHTBAR_LAUNCHER_DIAGNOSTIC = $oldDiagnostic
    if (Test-Path $cache) { Remove-Item -Recurse -Force $cache }
}
Write-Host "Built: $portable"
