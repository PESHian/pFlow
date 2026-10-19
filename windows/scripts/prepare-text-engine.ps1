param([ValidateSet('arm64','x64')][string]$Architecture)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\WindowsArchitecture.ps1"
$arch=if($Architecture){$Architecture}else{Get-PFlowArchitecture}
$hashes=@{arm64='c94f661ef26262ab3c02a679eac3e73ead91676db161dc7b57f8966d9eecbf9d';x64='79b143075ab87fb5aff6f8f8ca80500a984f4120b5199fa9f9b70b284f17428e'}
if(!$hashes.ContainsKey($arch)) {throw "Unsupported architecture: $arch"}
$cache=Join-Path $env:LOCALAPPDATA "pFlowBuild\llama-b11716-$arch"
New-Item -ItemType Directory -Force $cache | Out-Null
$archive="$cache\engine.zip"
Invoke-WebRequest -UseBasicParsing "https://github.com/ggml-org/llama.cpp/releases/download/b11716/llama-b11716-bin-win-cpu-$arch.zip" -OutFile $archive
if((Get-FileHash $archive -Algorithm SHA256).Hash -ne $hashes[$arch]) {throw 'Text engine checksum mismatch.'}
Expand-Archive $archive "$cache\unpacked" -Force
$destination="$root\text-engine\win-$arch"
New-Item -ItemType Directory -Force $destination | Out-Null
Get-ChildItem "$cache\unpacked" -File -Recurse | Where-Object {$_.Extension -eq '.dll' -or $_.Name -eq 'llama-completion.exe' -or $_.Name -like '*LICENSE*' -or $_.Name -like '*NOTICE*'} | Copy-Item -Destination $destination -Force
if(!(Test-Path "$destination\llama-completion.exe")) {throw 'The text engine archive layout was not recognized.'}
# The upstream CPU DLLs need Microsoft's CRT even on PCs without Visual Studio.
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs=& $vswhere -latest -products '*' -property installationPath
if(!$vs) {throw 'Visual Studio redistributable files were not found.'}
$crt=$null
foreach($version in (Get-ChildItem "$vs\VC\Redist\MSVC" -Directory | Sort-Object Name -Descending)) {
    $target=Join-Path $version.FullName $arch
    if(Test-Path $target) {$crt=Get-ChildItem $target -Directory -Filter 'Microsoft.VC*.CRT' | Select-Object -First 1}
    if($crt){break}
}
if(!$crt){throw "The app-local C++ runtime for $arch is missing."}
Get-ChildItem $crt.FullName -Filter '*.dll' -File | Where-Object { (Get-PFlowExecutableArchitecture $_.FullName) -eq $arch } | Copy-Item -Destination $destination -Force
@'
Microsoft Visual C++ runtime redistributable files
Copyright Microsoft Corporation. All rights reserved.
These unmodified files are distributed as app-local dependencies of llama.cpp.
They remain subject to Microsoft's terms, separately from pFlow's MIT license.
Redistributable file list and terms:
https://learn.microsoft.com/visualstudio/releases/2022/redistribution
https://learn.microsoft.com/cpp/windows/redistributing-visual-cpp-files
'@ | Set-Content "$destination\Microsoft-CRT-NOTICE.txt" -Encoding UTF8
