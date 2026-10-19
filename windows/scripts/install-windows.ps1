param([Parameter(Mandatory=$true)][string]$Source, [string]$SharedModelDirectory)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\WindowsArchitecture.ps1"
Assert-PFlowArchitecture $Source
$destination = Join-Path $env:LOCALAPPDATA 'Programs\pFlow'
$running = Get-Process pFlow -ErrorAction SilentlyContinue | Where-Object { [PFlowNativeSystemInfo]::ProcessPath($_.Id) -eq "$destination\pFlow.exe" }
if ($running) { throw 'Quit pFlow before updating it. Your settings and History will be kept.' }
if (!(Test-Path "$Source\pFlow.exe") -or !(Test-Path "$Source\engine\whisper-cli.exe") -or !(Test-Path "$Source\engine\pflow-whisper.exe")) { throw 'The portable package is incomplete.' }
$staging = "$destination.new"
if (Test-Path $staging) { throw 'An earlier installation is unfinished. Keep that folder and check it before installing again.' }
New-Item -ItemType Directory -Force $staging | Out-Null
try {
Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $staging -Recurse -Force
if ($SharedModelDirectory) {
    $model = Join-Path $SharedModelDirectory 'ggml-small.bin'
    if ((Get-Item -LiteralPath $model).Length -ne 487601967 -or (Get-PFlowFileSha256 $model) -ne '1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b') {
        throw 'The speech model is incomplete or damaged. Your installed app was not changed.'
    }
    New-Item -ItemType Directory -Force "$staging\models" | Out-Null
    Copy-Item -LiteralPath $model -Destination "$staging\models\ggml-small.bin"
}
} catch {
    Remove-Item -LiteralPath $staging -Recurse -Force
    throw
}
$previous = $null
try {
    if (Test-Path $destination) {
        $previous = "$destination.previous-$([Guid]::NewGuid().ToString('N'))"
        Move-Item -LiteralPath $destination -Destination $previous
    }
    Move-Item -LiteralPath $staging -Destination $destination
} catch {
    if ($previous -and !(Test-Path $destination)) { Move-Item -LiteralPath $previous -Destination $destination }
    throw
}
$shell = New-Object -ComObject WScript.Shell
$startMenu = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
New-Item -ItemType Directory -Force $startMenu | Out-Null
$link = $shell.CreateShortcut("$startMenu\pFlow by Pesh.lnk")
$link.IconLocation = "$destination\pFlow.exe,0"; $link.TargetPath = "$destination\pFlow.exe"; $link.WorkingDirectory = $destination; $link.Save()
Write-Output "Installed $destination\pFlow.exe"

if (-not ('PFlowShellIconRefresh' -as [type])) { Add-Type @'
using System;using System.Runtime.InteropServices;
public static class PFlowShellIconRefresh { [DllImport("shell32.dll")] public static extern void SHChangeNotify(uint change,uint flags,IntPtr first,IntPtr second); }
'@
}
[PFlowShellIconRefresh]::SHChangeNotify(0x08000000,0,[IntPtr]::Zero,[IntPtr]::Zero)
