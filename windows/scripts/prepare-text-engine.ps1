$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$arch=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
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
