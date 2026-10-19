param([Parameter(Mandatory=$true)][string]$Source)
$ErrorActionPreference = 'Stop'
$destination = Join-Path $env:LOCALAPPDATA 'Programs\pFlow'
$running = Get-Process pFlow -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq "$destination\pFlow.exe" }
if ($running) { throw 'Quit pFlow before updating it. Your settings and History will be kept.' }
if (!(Test-Path "$Source\pFlow.exe") -or !(Test-Path "$Source\engine\whisper-cli.exe") -or !(Test-Path "$Source\engine\pflow-whisper.exe")) { throw 'The portable package is incomplete.' }
$staging = "$destination.new"
if (Test-Path $staging) { throw 'An earlier installation is unfinished. Keep that folder and check it before installing again.' }
New-Item -ItemType Directory -Force $staging | Out-Null
Copy-Item "$Source\*" $staging -Recurse -Force
if (Test-Path $destination) { Move-Item $destination "$destination.previous-$(Get-Date -Format yyyyMMddHHmmss)" }
Move-Item $staging $destination
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\pFlow by Pesh.lnk")
$link.IconLocation = "$destination\pFlow.exe,0"; $link.TargetPath = "$destination\pFlow.exe"; $link.WorkingDirectory = $destination; $link.Save()
Write-Output "Installed $destination\pFlow.exe"

if (-not ('PFlowShellIconRefresh' -as [type])) { Add-Type @'
using System;using System.Runtime.InteropServices;
public static class PFlowShellIconRefresh { [DllImport("shell32.dll")] public static extern void SHChangeNotify(uint change,uint flags,IntPtr first,IntPtr second); }
'@
}
[PFlowShellIconRefresh]::SHChangeNotify(0x08000000,0,[IntPtr]::Zero,[IntPtr]::Zero)
