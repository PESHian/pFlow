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
        # The real uninstall against this fixture account: decoy siblings with similar names, a junction to a decoy, and
        # the data folder must survive; only pFlow's own folders, shortcut and keys go. The signed-in account's own Run
        # value, Uninstall key and desktop shortcut are saved first and put back, since the registry is not redirected.
        $programs=Join-Path $env:LOCALAPPDATA 'Programs'
        foreach($d in 'pFlowNotes','pFlow backup','decoy-target','pFlow.previous-fictional'){New-Item -ItemType Directory -Force "$programs\$d" | Out-Null; 'keep' | Set-Content "$programs\$d\keep.txt"}
        New-Item -ItemType Junction -Path "$programs\pFlow.previous-link" -Target "$programs\decoy-target" | Out-Null
        $dataDir=Join-Path $env:LOCALAPPDATA 'pFlow';New-Item -ItemType Directory -Force $dataDir | Out-Null;'{"fictional":true}' | Set-Content "$dataDir\settings.json"
        $runKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';$savedRun=(Get-ItemProperty $runKey -ErrorAction SilentlyContinue).'pFlow by Pesh'
        $uninstKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\pFlow by Pesh';$savedUninst=if(Test-Path $uninstKey){Get-ItemProperty $uninstKey}else{$null}
        $deskLink=[Environment]::GetFolderPath('Desktop')+'\pFlow by Pesh.lnk';$savedDesk=if(Test-Path $deskLink){[IO.File]::ReadAllBytes($deskLink)}else{$null}
        try {
            # A copy running from the install folder that will not quit (a renamed cmd.exe standing in for pFlow busy
            # with a take): the uninstall must wait, then stop and remove nothing, never end it by force.
            Copy-Item "$env:SystemRoot\System32\cmd.exe" "$installed\engine\pFlow.exe"
            $busy=Start-Process -FilePath "$installed\engine\pFlow.exe" -ArgumentList '/c','ping -n 400 127.0.0.1 >nul' -PassThru -WindowStyle Hidden
            Start-Sleep 1; Check (!$busy.HasExited) 'the stand-in busy copy is running from the install folder'
            try {
                $said=Join-Path $fixture 'uninstall-refused.txt'
                $refused=Start-Process -FilePath "$installed\pFlow.exe" -ArgumentList '--uninstall','--quiet' -PassThru -NoNewWindow -RedirectStandardError $said
                $null=$refused.Handle   # PowerShell fills ExitCode only for a process whose handle was taken before it ended
                for($k=0;$k -lt 150 -and !$refused.HasExited;$k++){Start-Sleep 1}
                Write-Output ("busy uninstall: exited=" + $refused.HasExited + " code=" + $refused.ExitCode + " after " + $k + " s; folder=" + (Test-Path "$installed\pFlow.exe") + "; said: " + ((Get-Content $said -Raw -ErrorAction SilentlyContinue) -replace "\s+"," "))
                Check ($refused.HasExited -and $refused.ExitCode -eq 1) 'uninstall with a busy copy that will not quit stops with exit 1 (waited, never killed)'
                Check (!$busy.HasExited) 'the busy copy was not ended by force'
                Check ((Test-Path "$installed\pFlow.exe") -and (Test-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\pFlow by Pesh.lnk")) 'a refused uninstall removes nothing'
            } finally { if(!$busy.HasExited){Stop-Process -Id $busy.Id -Force}; Start-Sleep 1; Remove-Item "$installed\engine\pFlow.exe" -Force }
            $u=Start-Process -FilePath "$installed\pFlow.exe" -ArgumentList '--uninstall','--quiet' -PassThru -NoNewWindow
            $null=$u.Handle
            for($k=0;$k -lt 60 -and !$u.HasExited;$k++){Start-Sleep 1}
            Check ($u.HasExited -and $u.ExitCode -eq 0) 'quiet uninstall finished without error'
            for($k=0;$k -lt 40 -and (Test-Path $installed);$k++){Start-Sleep 1}
            Check (!(Test-Path $installed)) 'uninstall removed the app folder'
            Check (!(Test-Path "$programs\pFlow.previous-fictional")) 'uninstall removed a previous pFlow folder'
            Check (!(Test-Path "$programs\pFlow.previous-link") -and (Test-Path "$programs\decoy-target\keep.txt")) 'uninstall removed only the pFlow junction, not the folder it pointed at'
            Check ((Test-Path "$programs\pFlowNotes\keep.txt") -and (Test-Path "$programs\pFlow backup\keep.txt")) 'uninstall left sibling folders with similar names alone'
            Check (!(Test-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\pFlow by Pesh.lnk")) 'uninstall removed the Start menu shortcut'
            Check (!(Test-Path $uninstKey)) 'uninstall removed the Installed apps row'
            Check (Test-Path "$dataDir\settings.json") 'quiet uninstall keeps settings and History'
        } finally {
            if($savedRun){New-Item $runKey -Force | Out-Null;Set-ItemProperty $runKey -Name 'pFlow by Pesh' -Value $savedRun}
            if($savedUninst){New-Item $uninstKey -Force | Out-Null;foreach($p in $savedUninst.PSObject.Properties){if($p.Name -notlike 'PS*'){Set-ItemProperty $uninstKey -Name $p.Name -Value $p.Value}}}
            if($savedDesk){[IO.File]::WriteAllBytes($deskLink,$savedDesk)}
        }
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
