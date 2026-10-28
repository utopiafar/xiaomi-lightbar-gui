$ErrorActionPreference = 'Stop'
$projectDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$artifactDir = if ($args.Count -gt 0) { $args[0] } else { Join-Path $projectDir 'build\artifacts' }
New-Item -ItemType Directory -Force $artifactDir | Out-Null

cargo build --locked --release --manifest-path (Join-Path $projectDir 'core\Cargo.toml') --target x86_64-pc-windows-msvc
if ($LASTEXITCODE -ne 0) { throw 'Rust core build failed' }
cargo test --locked --manifest-path (Join-Path $projectDir 'core\Cargo.toml') --target x86_64-pc-windows-msvc
if ($LASTEXITCODE -ne 0) { throw 'Rust core tests failed' }

Push-Location (Join-Path $projectDir 'desktop')
try {
    flutter pub get --enforce-lockfile
    if ($LASTEXITCODE -ne 0) { throw 'Flutter dependency resolution failed' }
    flutter analyze --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Flutter analysis failed' }
    flutter test --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Flutter tests failed' }
    flutter build windows --release --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Windows desktop build failed' }
} finally { Pop-Location }

$bundle = Join-Path $projectDir 'desktop\build\windows\x64\runner\Release'
if (-not (Test-Path $bundle)) { throw 'The Flutter x64 output was not found. Use an x64 Windows Flutter SDK and C++ toolchain.' }
Copy-Item (Join-Path $projectDir 'core\target\x86_64-pc-windows-msvc\release\lightbar_core.dll') $bundle
Copy-Item (Join-Path $projectDir 'LICENSE') (Join-Path $bundle 'LICENSE.txt')
python (Join-Path $projectDir 'scripts\collect-notices.py') (Join-Path $bundle 'THIRD_PARTY_NOTICES.txt')
if ($LASTEXITCODE -ne 0) { throw 'Third-party notice collection failed' }
Copy-Item (Join-Path $projectDir 'docs\INSTALL-WINDOWS.txt') (Join-Path $bundle 'README.txt')
Copy-Item (Join-Path $projectDir 'scripts\install-windows-shortcut.ps1') $bundle
Copy-Item (Join-Path $projectDir 'scripts\Create-Start-Menu-Shortcut.cmd') $bundle
$archive = Join-Path $artifactDir 'xiaomi-lightbar-windows-x86_64.zip'
Compress-Archive -Force -Path (Join-Path $bundle '*') -DestinationPath $archive
Write-Host "Built: $archive"
