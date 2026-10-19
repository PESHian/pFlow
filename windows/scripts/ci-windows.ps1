param([Parameter(Mandatory=$true)][ValidateSet('arm64','x64','x86')][string]$Architecture)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Split-Path $PSScriptRoot -Parent
$rid = "win-$Architecture"
& "$PSScriptRoot\build-windows.ps1" -Architecture $Architecture
$dist = "$root\dist\$rid"
$checks = "$root\dist\checks-$Architecture"
dotnet publish "$root\PFlow.WindowsTests" -c Release -r $rid --self-contained true -p:RuntimeFrameworkVersion=10.0.13 -o $checks
if ($LASTEXITCODE) { throw 'Native check build failed.' }
& "$checks\PFlow.WindowsTests.exe"
if ($LASTEXITCODE) { throw 'Architecture ABI/private clipboard checks failed.' }
# Keep model weights outside the payload; the universal ZIP stores one shared copy.
$shared = "$root\dist\shared\models"
New-Item -ItemType Directory -Force $shared | Out-Null
$model = "$shared\ggml-small.bin"
Invoke-WebRequest -UseBasicParsing 'https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small.bin' -OutFile $model
if ((Get-Item $model).Length -ne 487601967 -or (Get-FileHash $model -Algorithm SHA256).Hash -ne '1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b') { throw 'Pinned speech model verification failed.' }
New-Item -ItemType Directory -Force "$dist\models" | Out-Null
Copy-Item $model "$dist\models\ggml-small.bin"
$audio = "$env:LOCALAPPDATA\pFlowBuild\whisper\whisper.cpp-1.9.5\samples\jfk.wav"
& "$checks\PFlow.WindowsTests.exe" --architecture-speech $dist $audio
if ($LASTEXITCODE) { throw 'Native offline transcription/reuse checks failed.' }
Remove-Item "$dist\models\ggml-small.bin"
if ($Architecture -ne 'x86') {
    & "$dist\text-engine\llama-completion.exe" --version
    if ($LASTEXITCODE) { throw 'Bundled optional text engine could not load.' }
}
$packages = (dotnet nuget locals global-packages --list).Split(' ',2)[1].Trim()
foreach ($name in @('microsoft.netcore.app.runtime','microsoft.windowsdesktop.app.runtime')) {
    $package = Join-Path $packages "$name.$rid\10.0.13"
    Get-ChildItem $package -File | Where-Object { $_.Name -match 'LICENSE|NOTICE' } | ForEach-Object {
        Copy-Item $_.FullName "$dist\Licenses\$name-$($_.Name)"
    }
}
"pFlow 0.1.9; $rid; source $env:GITHUB_SHA; .NET 10.0.13; native CPU baseline" | Set-Content "$dist\BUILD.txt" -Encoding ASCII
if (Get-ChildItem $dist -Filter '*.pdb' -Recurse) { throw 'Debug symbols must not be distributed.' }
Write-Output "PASS: $rid native ABI, private clipboard, saved-audio CPU transcription and resident reuse."
