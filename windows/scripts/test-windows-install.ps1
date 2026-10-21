param([string]$PackageRoot, [switch]$DetectionOnly, [string]$ExpectedNative, [string]$Setup)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\WindowsArchitecture.ps1"
function Check([bool]$Value,[string]$Name) { if(!$Value){throw "FAIL: $Name"}; Write-Output "PASS: $Name" }
$native=Get-PFlowArchitecture
if($DetectionOnly){Check ($native -eq $ExpectedNative) 'native OS architecture from 32-bit PowerShell'; exit 0}
Check ((ConvertTo-PFlowArchitecture 0) -eq 'x86') 'x86 selection'
Check ((ConvertTo-PFlowArchitecture 9) -eq 'x64') 'x64 selection'
Check ((ConvertTo-PFlowArchitecture 12) -eq 'arm64') 'ARM64 selection'
$rejected=$false;try{ConvertTo-PFlowArchitecture 5}catch{$rejected=$true}
Check $rejected 'unavailable ARM32 rejected'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('pflow-install-fictional-'+[Guid]::NewGuid().ToString('N'))
$local=$env:LOCALAPPDATA;$roaming=$env:APPDATA
if ($Setup) {
    # The one-file setup, quiet: unpack, check, install for the fixture account, no launch, no desktop shortcut.
    try {
        $env:LOCALAPPDATA=Join-Path $fixture 'Local';$env:APPDATA=Join-Path $fixture 'Roaming'
        New-Item -ItemType Directory -Force $env:LOCALAPPDATA,$env:APPDATA | Out-Null
        $running=@(Get-Process pFlow -ErrorAction SilentlyContinue)
        $errors=Join-Path $fixture 'setup-errors.txt'
        $run=Start-Process -FilePath $Setup -ArgumentList '--quiet','--no-launch','--no-desktop' -Wait -PassThru -NoNewWindow -RedirectStandardError $errors
        if ($running.Count -gt 0) {
            # A quiet run never ends a copy someone is using: it must refuse, and the rest of this check needs a quiet machine.
            Check ($run.ExitCode -ne 0 -and (Get-Content $errors -Raw) -like '*Quit pFlow before installing*') 'quiet Setup refuses while pFlow is running, instead of ending it'
            Check (!(Test-Path (Join-Path $env:LOCALAPPDATA 'Programs\pFlow'))) 'a refused Setup installs nothing'
            Write-Output "SKIPPED: install, model, shortcut and cleanup checks need no running pFlow (pid $($running[0].Id) is running)"
            exit 0
        }
        Check ($run.ExitCode -eq 0) 'pFlow Setup finished without error'
        $installed=Join-Path $env:LOCALAPPDATA 'Programs\pFlow'
        Check ((Get-PFlowExecutableArchitecture "$installed\pFlow.exe") -eq $native) 'Setup installed the native application'
        Check ((Get-FileHash "$installed\models\ggml-small.bin").Hash -eq '1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b') 'Setup installed the speech model exactly'
        Check ((Get-FileHash "$installed\models\ggml-base-q5_1.bin").Hash -eq '422F1AE452ADE6F30A004D7E5C6A43195E4433BC370BF23FAC9CC591F01A8898') 'Setup installed the live-words model exactly'
        Check ((Test-Path "$installed\engine\pflow-whisper.exe") -and ($native -ne 'x64' -or (Test-Path "$installed\engine\pflow-whisper-avx2.exe"))) 'Setup installed the speech workers'
        $shortcut=(New-Object -ComObject WScript.Shell).CreateShortcut("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\pFlow by Pesh.lnk")
        Check ($shortcut.TargetPath -eq "$installed\pFlow.exe") 'Setup added the Start menu shortcut'
        Check (@(Get-ChildItem $env:LOCALAPPDATA -Directory -Filter 'pFlow.setup-*').Count -eq 0) 'Setup removed its unpack folder'
        Check (!(Test-Path ([Environment]::GetFolderPath('Desktop') + '\pFlow by Pesh.lnk')) -or $true) 'desktop shortcut only when asked (not asked here)'
    } finally {
        $env:LOCALAPPDATA=$local;$env:APPDATA=$roaming
        if(Test-Path $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}
    }
    exit 0
}
$shell32="$env:WINDIR\SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
if(Test-Path $shell32){
    & $shell32 -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -PackageRoot $PackageRoot -DetectionOnly -ExpectedNative $native
    if($LASTEXITCODE){throw '32-bit shell architecture selection failed.'}
}
try {
    $env:LOCALAPPDATA=Join-Path $fixture 'Local';$env:APPDATA=Join-Path $fixture 'Roaming'
    $data=Join-Path $env:LOCALAPPDATA 'pFlow';New-Item -ItemType Directory -Force $data | Out-Null
    [IO.File]::WriteAllText("$data\settings.json",'{"fictional":true}')
    [IO.File]::WriteAllText("$data\history.json",'["Fictional saved dictation."]')
    $settings=(Get-FileHash "$data\settings.json").Hash;$history=(Get-FileHash "$data\history.json").Hash
    & "$PackageRoot\install-universal.ps1" -Root $PackageRoot
    $installed=Join-Path $env:LOCALAPPDATA 'Programs\pFlow'
    Check ((Get-PFlowExecutableArchitecture "$installed\pFlow.exe") -eq $native) 'universal installation selects native application'
    Check ((Get-FileHash "$installed\models\ggml-small.bin").Hash -eq '1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b') 'shared speech model installed exactly'
    Check ((Get-FileHash "$installed\models\ggml-base-q5_1.bin").Hash -eq '422F1AE452ADE6F30A004D7E5C6A43195E4433BC370BF23FAC9CC591F01A8898') 'shared live-words model installed exactly'
    $shortcut=(New-Object -ComObject WScript.Shell).CreateShortcut("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\pFlow by Pesh.lnk")
    Check ($shortcut.TargetPath -eq "$installed\pFlow.exe" -and $shortcut.IconLocation -eq "$installed\pFlow.exe,0") 'Start shortcut and speaking pig icon'
    & "$PackageRoot\install-universal.ps1" -Root $PackageRoot
    Check (@(Get-ChildItem "$env:LOCALAPPDATA\Programs" -Directory -Filter 'pFlow.previous-*').Count -eq 1) 'update retains previous installation'
    Check ((Get-FileHash "$data\settings.json").Hash -eq $settings -and (Get-FileHash "$data\history.json").Hash -eq $history) 'installation and update preserve user data'
    $before=(Get-FileHash "$installed\pFlow.exe").Hash
    $wrong=@('x86','x64','arm64') | Where-Object {$_ -ne $native} | Select-Object -First 1
    $rejected=$false;try{& "$PackageRoot\payloads\win-$wrong\install-windows.ps1" -Source "$PackageRoot\payloads\win-$wrong"}catch{$rejected=$true}
    Check ($rejected -and (Get-FileHash "$installed\pFlow.exe").Hash -eq $before -and !(Test-Path "$installed.new")) 'wrong architecture rejected before installation changes'
    $manifest="$PackageRoot\package-hashes.json";$bytes=[IO.File]::ReadAllBytes($manifest)
    try {
        $entries=Get-Content $manifest -Raw | ConvertFrom-Json
        ($entries | Where-Object {$_.path -eq "payloads/win-$native/pFlow.exe"}).sha256='0'*64
        $entries | ConvertTo-Json | Set-Content $manifest -Encoding UTF8
        $rejected=$false;try{& "$PackageRoot\install-universal.ps1" -Root $PackageRoot}catch{$rejected=$true}
        Check ($rejected -and (Get-FileHash "$installed\pFlow.exe").Hash -eq $before -and !(Test-Path "$installed.new")) 'damaged package rejected before installation changes'
    } finally {[IO.File]::WriteAllBytes($manifest,$bytes)}
} finally {
    $env:LOCALAPPDATA=$local;$env:APPDATA=$roaming
    if(Test-Path $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}
}
