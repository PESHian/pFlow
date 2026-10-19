param([Parameter(Mandatory=$true)][ValidateSet('arm64','x64','x86')][string]$Architecture)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$rid="win-$Architecture"
$fixture=Join-Path $env:RUNNER_TEMP ('pflow update fictional '+[Guid]::NewGuid().ToString('N'))
$originalLocal=$env:LOCALAPPDATA;$originalRoaming=$env:APPDATA
$passed=0
function Check([bool]$value,[string]$name){if(!$value){throw "FAIL: $name"};$script:passed++;Write-Output "PASS: $name"}
function Wait-File([string]$path){$until=[DateTime]::UtcNow.AddSeconds(45);while(!(Test-Path $path) -and [DateTime]::UtcNow -lt $until){Start-Sleep -Milliseconds 100};if(!(Test-Path $path)){throw "Missing fixture signal: $(Split-Path $path -Leaf)"}}
try {
    foreach($version in @('0.1.10','0.1.11')){
        dotnet publish "$root\fixtures\UpdaterApp" -c Release -r $rid --self-contained true -p:RuntimeFrameworkVersion=10.0.13 -p:Version=$version -o "$fixture\binaries\$version" > "$root\dist\stub-$version-$Architecture.log"
        if($LASTEXITCODE){throw 'Could not build the controlled updater fixture.'}
    }
    foreach($scenario in @('success','cancel','corrupt','startup-failure')) {
        $case=Join-Path $fixture $scenario
        $env:LOCALAPPDATA=Join-Path $case 'Local';$env:APPDATA=Join-Path $case 'Roaming'
        $env:PFLOW_UPDATER_TEST_STARTED=Join-Path $case 'started-';$env:PFLOW_UPDATER_TEST_STOP=Join-Path $case 'stop-'
        $env:PFLOW_UPDATER_TEST_FAIL=if($scenario -eq 'startup-failure'){'0.1.11'}else{''}
        $installed=Join-Path $env:LOCALAPPDATA 'Programs\pFlow'
        New-Item -ItemType Directory -Force $installed | Out-Null
        Copy-Item "$fixture\binaries\0.1.10\*" $installed -Recurse
        New-Item -ItemType Directory -Force "$installed\models","$env:LOCALAPPDATA\pFlow" | Out-Null
        [IO.File]::WriteAllText("$installed\models\fictional-model.txt",'Private fictional model marker.')
        [IO.File]::WriteAllText("$env:LOCALAPPDATA\pFlow\history.json",'["Fictional dictation."]')
        $history=(Get-FileHash "$env:LOCALAPPDATA\pFlow\history.json").Hash
        $job=Join-Path $case 'job';$package=Join-Path $job 'package'
        New-Item -ItemType Directory -Force $package | Out-Null
        Copy-Item "$fixture\binaries\0.1.11\*" $package -Recurse
        Copy-Item "$root\dist\$rid\engine" $package -Recurse
        $manifest=@(Get-ChildItem $package -Recurse -File | ForEach-Object { @{path=$_.FullName.Substring($package.Length+1).Replace('\','/');sha256=(Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()} })
        $manifest | ConvertTo-Json | Set-Content "$package\package-hashes.json" -Encoding UTF8
        if($scenario -eq 'corrupt'){Add-Content "$package\pFlow.dll" 'fictional damage'}
        Copy-Item "$PSScriptRoot\update-install.ps1","$PSScriptRoot\install-windows.ps1","$PSScriptRoot\WindowsArchitecture.ps1" $job
        $old=Start-Process "$installed\pFlow.exe" -PassThru
        Wait-File ($env:PFLOW_UPDATER_TEST_STARTED+'0.1.10')
        @{package=$package;destination=$installed;version='0.1.11';processId=$old.Id;startedTicks=$old.StartTime.ToUniversalTime().Ticks}|ConvertTo-Json|Set-Content "$job\plan.json" -Encoding UTF8
        $arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$job+'\update-install.ps1" -Plan "'+$job+'\plan.json"'
        $helper=Start-Process "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $arguments -PassThru
        try {
            if($scenario -eq 'corrupt') {
                Check ($helper.WaitForExit(45000) -and $helper.ExitCode -ne 0 -and !$old.HasExited) 'damaged staged file keeps original process running'
            } else {
                Wait-File "$job\ready"
                Check (!$old.HasExited) "$scenario waits for graceful application exit"
                if($scenario -eq 'cancel'){Set-Content "$job\cancel" 'cancel'}
                else {Set-Content ($env:PFLOW_UPDATER_TEST_STOP+'0.1.10') 'stop';Check ($old.WaitForExit(10000)) "$scenario old application exits normally"}
                Check ($helper.WaitForExit(45000)) "$scenario helper finishes without killing any process"
                if($scenario -eq 'success') {
                    Check ($helper.ExitCode -eq 0) 'verified update installed and restarted'
                    Wait-File ($env:PFLOW_UPDATER_TEST_STARTED+'0.1.11')
                    Check ([Diagnostics.FileVersionInfo]::GetVersionInfo("$installed\pFlow.exe").FileBuildPart -eq 11) 'new application version installed'
                } elseif($scenario -eq 'cancel') {
                    Check ($helper.ExitCode -ne 0 -and !$old.HasExited) 'cancel keeps original application alive'
                } else {
                    Check ($helper.ExitCode -ne 0) 'failed new startup reported'
                    Check ([Diagnostics.FileVersionInfo]::GetVersionInfo("$installed\pFlow.exe").FileBuildPart -eq 10) 'failed new startup restores previous application'
                    $until=[DateTime]::UtcNow.AddSeconds(10)
                    do {Start-Sleep -Milliseconds 100;$restored=Get-Process pFlow -ErrorAction SilentlyContinue | Where-Object {try{$_.Path -eq "$installed\pFlow.exe"}catch{$false}}}while(!$restored -and [DateTime]::UtcNow -lt $until)
                    Check ([bool]$restored) 'previous application relaunched after rollback'
                }
            }
            Check ((Get-FileHash "$env:LOCALAPPDATA\pFlow\history.json").Hash -eq $history) "$scenario keeps private fictional history"
            Check ([IO.File]::ReadAllText("$installed\models\fictional-model.txt") -eq 'Private fictional model marker.') "$scenario keeps existing model bytes"
        } finally {
            foreach($v in @('0.1.10','0.1.11')){Set-Content ($env:PFLOW_UPDATER_TEST_STOP+$v) 'stop'}
            $running=Get-Process pFlow -ErrorAction SilentlyContinue|Where-Object{try{$_.Path -eq "$installed\pFlow.exe"}catch{$false}}
            foreach($process in $running){if(!$process.WaitForExit(5000)){throw 'Owned test fixture did not stop; no process was killed.'}}
            $helper.Dispose();$old.Dispose()
        }
    }
    Write-Output "$passed controlled updater process/filesystem checks passed ($rid). No microphone or user clipboard was used."
} finally {
    $env:LOCALAPPDATA=$originalLocal;$env:APPDATA=$originalRoaming
    Remove-Item Env:PFLOW_UPDATER_TEST_STARTED,Env:PFLOW_UPDATER_TEST_STOP,Env:PFLOW_UPDATER_TEST_FAIL -ErrorAction SilentlyContinue
    if(Test-Path $fixture){Remove-Item $fixture -Recurse -Force}
}
