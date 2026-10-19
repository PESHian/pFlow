param([string]$Root = $PSScriptRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\WindowsArchitecture.ps1"
$arch = Get-PFlowArchitecture
if ([PFlowNativeSystemInfo]::WindowsBuild() -lt 14393) { throw 'pFlow needs Windows 10 version 1607 or later, or Windows 11. Older Windows cannot run its .NET runtime.' }
$source = Join-Path $Root "payloads\win-$arch"
$shared = Join-Path $Root 'shared\models'
Assert-PFlowArchitecture $source $arch
# Check the selected payload before the installer can rename an existing app.
$manifest = Get-Content -LiteralPath (Join-Path $Root 'package-hashes.json') -Raw | ConvertFrom-Json
$entries = @($manifest | Where-Object { $_.path.StartsWith("payloads/win-$arch/", [StringComparison]::Ordinal) -or $_.path.StartsWith('shared/', [StringComparison]::Ordinal) })
if ($entries.Count -lt 10) { throw 'The universal package is incomplete. Extract the whole ZIP again.' }
foreach ($entry in $entries) {
    if ($entry.path -match '(^|/)\.\.(/|$)|[:\\]' -or $entry.path.StartsWith('/')) { throw 'Invalid package path.' }
    $file = Join-Path $Root $entry.path
    if (!(Test-Path -LiteralPath $file -PathType Leaf) -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $entry.sha256) {
        throw 'The extracted app is damaged or incomplete. Extract the whole ZIP again. Your installed app was not changed.'
    }
}
Write-Output "Installing pFlow for $arch Windows..."
& "$source\install-windows.ps1" -Source $source -SharedModelDirectory $shared
