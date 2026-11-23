# Run on Windows with Flutter and Visual Studio C++ desktop tooling installed.
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path $PSScriptRoot -Parent
Push-Location (Join-Path $taskRoot 'client')
try {
    flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed' }
    flutter analyze
    if ($LASTEXITCODE -ne 0) { throw 'flutter analyze failed' }
    flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw 'Windows build failed' }
    Write-Host 'Portable Windows build, including Python, is ready under client/build/windows.'
} finally { Pop-Location }
