# Rebuild managed code only. Speech/text engines are byte-for-byte from the
# architecture-tested public baseline; no model or engine work is repeated.
param([Parameter(Mandatory=$true)][ValidateSet('arm64','x64','x86')][string]$Architecture, [switch]$SkipCoreChecks)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Split-Path $PSScriptRoot -Parent
$rid = "win-$Architecture"
. "$PSScriptRoot\WindowsArchitecture.ps1"
$archive = Join-Path $env:RUNNER_TEMP 'verified-engine-baseline.zip'
Invoke-WebRequest -UseBasicParsing 'https://github.com/PESHian/pFlow/releases/download/pflow-desktop-2026.10.19/pFlow-Windows-Universal-0.1.9-testing.zip' -OutFile $archive
if ((Get-FileHash $archive -Algorithm SHA256).Hash -ne '366061b5cb0fffe1ac224c7f31f435cb70fc32e3655d188c252c011b09128cce') { throw 'Released engine baseline checksum mismatch.' }
$dist = "$root\dist\$rid"
New-Item -ItemType Directory -Force $dist | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($archive)
try {
    $prefix = "payloads/$rid/"
    foreach ($entry in $zip.Entries) {
        if (!$entry.FullName.StartsWith($prefix, [StringComparison]::Ordinal)) { continue }
        $relative = $entry.FullName.Substring($prefix.Length)
        if ($relative -notmatch '^(engine|text-engine|Licenses)/[^/]+$') { continue }
        $destination = Join-Path $dist $relative
        New-Item -ItemType Directory -Force (Split-Path $destination -Parent) | Out-Null
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destination, $true)
    }
} finally { $zip.Dispose() }
if (!(Test-Path "$dist\engine\pflow-whisper.exe") -or (Get-ChildItem "$dist\Licenses" -File).Count -lt 9) { throw 'Incomplete released engine baseline.' }
# Publish does not erase unrelated engine/license files already in the folder.
dotnet publish "$root\PFlow.App" -c Release -r $rid --self-contained true -p:RuntimeFrameworkVersion=10.0.13 -o $dist
if ($LASTEXITCODE) { throw 'Windows app build failed.' }
Copy-Item "$PSScriptRoot\install-windows.ps1","$PSScriptRoot\WindowsArchitecture.ps1" $dist
Assert-PFlowArchitecture $dist $Architecture
if (!$SkipCoreChecks) {
    dotnet run --project "$root\PFlow.Tests" -c Release -- --hotkeys-only
    if ($LASTEXITCODE) { throw 'Activation routing/preferences checks failed.' }
}
$checks = "$root\dist\checks-$Architecture"
dotnet publish "$root\PFlow.WindowsTests" -c Release -r $rid --self-contained true -p:RuntimeFrameworkVersion=10.0.13 -o $checks
if ($LASTEXITCODE) { throw 'Windows integration check build failed.' }
& "$checks\PFlow.WindowsTests.exe"
if ($LASTEXITCODE) { throw 'Private native hotkey/settings/clipboard checks failed.' }
$version = ([xml](Get-Content "$root\PFlow.App\PFlow.App.csproj")).Project.PropertyGroup.Version
"pFlow $version; $rid; source $env:GITHUB_SHA; .NET 10.0.13; verified 0.1.9 CPU engines reused" | Set-Content "$dist\BUILD.txt" -Encoding ASCII
if (Get-ChildItem $dist -Filter '*.pdb' -Recurse) { throw 'Debug symbols must not be distributed.' }
Write-Output "PASS: $rid managed hotkeys/settings; private native ABI/clipboard; unchanged verified CPU engines. Physical input is unverified."
