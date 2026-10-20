param([Parameter(Mandatory=$true)][string]$Plan)
$ErrorActionPreference='Stop'
$job=Split-Path -Parent $Plan
$installed=$false; $previous=$null; $new=$null; $old=$null
try {
    # Self-contained .NET DLLs beside pFlow.exe break Windows PowerShell's compiler.
    Set-Location -LiteralPath $job
    [Environment]::CurrentDirectory=$job
    $data=Get-Content -LiteralPath $Plan -Raw | ConvertFrom-Json
    $expected=Join-Path $env:LOCALAPPDATA 'Programs\pFlow'
    if([IO.Path]::GetFullPath($data.destination) -ne $expected){throw 'Unexpected update destination.'}
    . "$PSScriptRoot\WindowsArchitecture.ps1"
    Assert-PFlowArchitecture $data.package
    $v=[Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $data.package 'pFlow.exe'))
    if("$($v.FileMajorPart).$($v.FileMinorPart).$($v.FileBuildPart)" -ne $data.version){throw 'The new application version does not match.'}
    $files=Get-Content -LiteralPath (Join-Path $data.package 'package-hashes.json') -Raw | ConvertFrom-Json
    foreach($file in $files){if((Get-PFlowFileSha256 (Join-Path $data.package $file.path)) -ne $file.sha256){throw 'The staged update is damaged.'}}
    $old=Get-Process -Id $data.processId -ErrorAction Stop
    if($old.StartTime.ToUniversalTime().Ticks -ne $data.startedTicks -or [PFlowNativeSystemInfo]::ProcessPath($old.Id) -ne (Join-Path $expected 'pFlow.exe')){throw 'The running application changed.'}
    $null=$old.Handle
    $models=Join-Path $expected 'models'
    if(Test-Path $models){Copy-Item -LiteralPath $models -Destination (Join-Path $data.package 'models') -Recurse}
    Set-Content -LiteralPath (Join-Path $job 'ready') -Value 'ready'
    $deadline=[DateTime]::UtcNow.AddMinutes(2)
    while(!$old.WaitForExit(200)) {
        if((Test-Path (Join-Path $job 'cancel')) -or [DateTime]::UtcNow -gt $deadline){throw 'The update was canceled before shutdown.'}
    }
    if(Test-Path (Join-Path $job 'cancel')){throw 'The update was canceled.'}
    $before=@(Get-ChildItem (Split-Path $expected -Parent) -Directory -Filter 'pFlow.previous-*' | ForEach-Object FullName)
    & "$PSScriptRoot\install-windows.ps1" -Source $data.package
    $installed=$true
    $previous=Get-ChildItem (Split-Path $expected -Parent) -Directory -Filter 'pFlow.previous-*' | Where-Object {$_.FullName -notin $before} | Select-Object -ExpandProperty FullName -First 1
    $new=Start-Process -FilePath (Join-Path $expected 'pFlow.exe') -PassThru
    if($new.WaitForExit(2000)){throw 'The updated application exited during startup.'}
    Set-Content -LiteralPath (Join-Path $job 'result') -Value 'installed'
    Remove-Item -LiteralPath (Join-Path $job 'update.zip'),$data.package -Recurse -Force -ErrorAction SilentlyContinue
} catch {
    ($_ | Out-String) | Set-Content -LiteralPath (Join-Path $job 'error.txt') -Encoding UTF8
    if($installed -and $previous -and (!$new -or $new.HasExited)) {
        $active=Get-Process pFlow -ErrorAction SilentlyContinue | Where-Object {[PFlowNativeSystemInfo]::ProcessPath($_.Id) -eq (Join-Path $expected 'pFlow.exe')}
        if(!$active) {
            Move-Item -LiteralPath $expected -Destination ($expected+'.failed-'+[Guid]::NewGuid().ToString('N'))
            Move-Item -LiteralPath $previous -Destination $expected
            Start-Process -FilePath (Join-Path $expected 'pFlow.exe')
        }
    }
    if($old -and $old.HasExited -and (Test-Path (Join-Path $expected 'pFlow.exe'))) {
        $active=Get-Process pFlow -ErrorAction SilentlyContinue | Where-Object {[PFlowNativeSystemInfo]::ProcessPath($_.Id) -eq (Join-Path $expected 'pFlow.exe')}
        if(!$active){Start-Process -FilePath (Join-Path $expected 'pFlow.exe')}
    }
    # The existing installer rolls back a failed folder replacement. Retain the
    # previous folder and this job on all failures; never kill a running process.
    Set-Content -LiteralPath (Join-Path $job 'result') -Value 'Update failed. The previous application folder was kept.'
    exit 1
}
