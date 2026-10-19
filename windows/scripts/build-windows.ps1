param([switch]$UseBundledEngine, [ValidateSet('arm64','x64','x86')][string]$Architecture)
$ErrorActionPreference = 'Stop'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$root = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\WindowsArchitecture.ps1"
$arch = if ($Architecture) { $Architecture } else { Get-PFlowArchitecture }
$rid = "win-$arch"
$engine = Join-Path $root "engine\$rid"
if (!$UseBundledEngine) {
    $cache = Join-Path $env:LOCALAPPDATA 'pFlowBuild\whisper'
    New-Item -ItemType Directory -Force $cache | Out-Null
    $archive = Join-Path $cache 'source.tar.gz'
    if (!(Test-Path $archive)) { Invoke-WebRequest 'https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v1.9.5.tar.gz' -OutFile $archive }
    if ((Get-FileHash $archive -Algorithm SHA256).Hash -ne 'ff1a9053feb509ff9d7729703355541ae9690073a6b1c40eb692c962e0dc1720') { throw 'Whisper source checksum mismatch.' }
    if (!(Test-Path "$cache\whisper.cpp-1.9.5")) { tar -xf $archive -C $cache; if ($LASTEXITCODE) { throw 'Could not extract Whisper.' } }
    $platform = @{arm64='ARM64';x64='x64';x86='Win32'}[$arch]
    $compiler = if ($arch -eq 'arm64') { @('-T','ClangCL','-DGGML_CPU_ARM_ARCH=armv8-a') } else { @() }
    cmake -S "$root\native" -DPFLOW_WHISPER_SOURCE="$cache\whisper.cpp-1.9.5" -B "$cache\worker-$arch" -A $platform @compiler -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DGGML_BACKEND_DL=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_CURL=OFF -DGGML_SSE42=OFF -DGGML_AVX=OFF -DGGML_AVX2=OFF -DGGML_BMI2=OFF -DGGML_FMA=OFF -DGGML_F16C=OFF
    if ($LASTEXITCODE) { throw 'Whisper configuration failed.' }
    cmake --build "$cache\worker-$arch" --config Release --target whisper-cli pflow-whisper -j 4
    if ($LASTEXITCODE) { throw 'Whisper build failed.' }
    New-Item -ItemType Directory -Force $engine | Out-Null
    Copy-Item "$cache\worker-$arch\bin\Release\whisper-cli.exe" $engine -Force
    Copy-Item "$cache\worker-$arch\bin\Release\pflow-whisper.exe" $engine -Force
}
if (!(Test-Path "$engine\whisper-cli.exe") -or !(Test-Path "$engine\pflow-whisper.exe")) { throw "Missing CPU engine for $rid." }
if ($arch -ne 'x86' -and !(Test-Path "$root\text-engine\$rid\llama-completion.exe")) { & "$PSScriptRoot\prepare-text-engine.ps1" -Architecture $arch }
dotnet run --project "$root\PFlow.Tests" -c Release
if ($LASTEXITCODE) { throw 'Core checks failed.' }
dotnet publish "$root\PFlow.App" -c Release -r $rid --self-contained true -p:RuntimeFrameworkVersion=10.0.13 -o "$root\dist\$rid"
if ($LASTEXITCODE) { throw 'Windows app build failed.' }
Copy-Item "$engine\*" "$root\dist\$rid\engine" -Force
Copy-Item "$PSScriptRoot\install-windows.ps1","$PSScriptRoot\WindowsArchitecture.ps1" "$root\dist\$rid"
Assert-PFlowArchitecture "$root\dist\$rid" $arch
Write-Output "Published $root\dist\$rid"
