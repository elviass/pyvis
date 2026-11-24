# Run on Windows x64 with Flutter and Visual Studio C++ desktop tooling installed.
param(
    [ValidateSet('Both', 'MSI', 'Portable')]
    [string]$Format = 'Both',
    [string]$Wix = 'wix'
)

$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path $PSScriptRoot -Parent
$client = Join-Path $taskRoot 'client'

function Invoke-Checked {
    param([string]$Command, [string[]]$Arguments)
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command exited with code $LASTEXITCODE" }
}

function Copy-VisualCppRuntime([string]$Destination) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $install = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or !$install) { throw 'Visual Studio C++ toolchain not found.' }
    $redist = Join-Path ($install | Select-Object -First 1) 'VC\Redist\MSVC'
    $crt = Get-ChildItem $redist -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+(\.\d+)?$' } |
        Sort-Object { [version]$_.Name } -Descending |
        ForEach-Object { Get-ChildItem (Join-Path $_.FullName 'x64') -Directory -Filter 'Microsoft.VC*.CRT' -ErrorAction SilentlyContinue } |
        Select-Object -First 1
    if (!$crt) { throw 'Visual C++ x64 redistributable DLLs not found.' }
    Copy-Item (Join-Path $crt.FullName '*.dll') $Destination
}

Push-Location $client
try {
    Invoke-Checked flutter @('pub', 'get')
    Invoke-Checked flutter @('analyze')
    try {
        Invoke-Checked flutter @('build', 'windows', '--release', '--no-pub')
    } catch {
        $build = Join-Path $client 'build\windows\x64'
        $cache = Join-Path $build CMakeCache.txt
        if (Test-Path $cache) {
            $cmake = Select-String -Path $cache -Pattern '^CMAKE_COMMAND:INTERNAL=(.+)$' |
                Select-Object -First 1
            if ($cmake -and (Test-Path (Join-Path $build 'runner\Release\pyvis_editor.exe'))) {
                & $cmake.Matches[0].Groups[1].Value --install $build --config Release
            }
        }
        throw
    }

    $release = Join-Path $client 'build\windows\x64\runner\Release'
    $python = Join-Path $release 'python\python.exe'
    if (!(Test-Path (Join-Path $release 'pyvis_editor.exe')) -or !(Test-Path $python)) {
        throw 'Expected a Windows x64 build with embedded Python.'
    }
    Copy-VisualCppRuntime $release
    Invoke-Checked $python @('-B', '-c', 'import pyvis_runtime, ssl; print(ssl.OPENSSL_VERSION)')

    $versionLine = Get-Content pubspec.yaml | Select-String '^version:\s*(\d+\.\d+\.\d+)(?:\+\d+)?\s*$' | Select-Object -First 1
    if (!$versionLine) { throw 'pubspec.yaml does not contain a valid release version.' }
    $version = $versionLine.Matches[0].Groups[1].Value
    $output = Join-Path $client 'build\windows\packages'
    New-Item -ItemType Directory -Force -Path $output | Out-Null

    if ($Format -in @('Both', 'Portable')) {
        $portable = Join-Path $output "Pyvis-$version-win-x64-portable.zip"
        if (Test-Path $portable) { Remove-Item $portable }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::CreateFromDirectory($release, $portable)
        Write-Host "Portable ZIP: $portable"
    }

    if ($Format -in @('Both', 'MSI')) {
        $installer = Join-Path $client 'windows\packaging\Pyvis.wxs'
        $icon = Join-Path $client 'windows\runner\resources\app_icon.ico'
        $msi = Join-Path $output "Pyvis-$version-win-x64.msi"
        Invoke-Checked $Wix @('build', '-arch', 'x64',
            '-d', "PackageVersion=$version", '-d', "AppIcon=$icon",
            '-bindpath', "payload=$release", '-out', $msi, $installer)
        Write-Host "MSI: $msi"
    }
} finally {
    Pop-Location
}
