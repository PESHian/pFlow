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
    # The baseline worker uses nothing newer than SSE2, so it runs on any processor. Without AVX2/FMA/F16C
    # ggml's F16 encoder runs scalar on x64: 11-13 times slower than the AVX2 build on the same source
    # (measured 2026-10-20). x64 therefore also gets pflow-whisper-avx2.exe; the app picks it at run time
    # when the processor has AVX2, FMA, F16C and BMI2 (PFlow.Core SpeechEngine.Choose).
    $baseline = @('-DGGML_SSE42=OFF','-DGGML_AVX=OFF','-DGGML_AVX2=OFF','-DGGML_BMI2=OFF','-DGGML_FMA=OFF','-DGGML_F16C=OFF')
    $avx2 = @('-DGGML_SSE42=ON','-DGGML_AVX=ON','-DGGML_AVX2=ON','-DGGML_BMI2=ON','-DGGML_FMA=ON','-DGGML_F16C=ON')
    $variants = @(@{Name='';Isa=$baseline}); if ($arch -eq 'x64') { $variants += @{Name='-avx2';Isa=$avx2} }
    New-Item -ItemType Directory -Force $engine | Out-Null
    foreach ($variant in $variants) {
        $build = "$cache\worker-$arch$($variant.Name)"
        cmake -S "$root\native" -DPFLOW_WHISPER_SOURCE="$cache\whisper.cpp-1.9.5" -B $build -A $platform @compiler -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DGGML_BACKEND_DL=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_CURL=OFF @($variant.Isa)
        if ($LASTEXITCODE) { throw 'Whisper configuration failed.' }
        cmake --build $build --config Release --target whisper-cli pflow-whisper -j 4
        if ($LASTEXITCODE) { throw 'Whisper build failed.' }
        if ($variant.Name -eq '') { Copy-Item "$build\bin\Release\whisper-cli.exe" $engine -Force }
        Copy-Item "$build\bin\Release\pflow-whisper.exe" "$engine\pflow-whisper$($variant.Name).exe" -Force
    }
}
if (!(Test-Path "$engine\whisper-cli.exe") -or !(Test-Path "$engine\pflow-whisper.exe")) { throw "Missing CPU engine for $rid." }
if ($arch -eq 'x64' -and !(Test-Path "$engine\pflow-whisper-avx2.exe")) { throw "Missing AVX2 speech worker for $rid." }
if ($arch -ne 'x86' -and !(Test-Path "$root\text-engine\$rid\llama-completion.exe")) { & "$PSScriptRoot\prepare-text-engine.ps1" -Architecture $arch }
dotnet run --project "$root\PFlow.Tests" -c Release
if ($LASTEXITCODE) { throw 'Core checks failed.' }
dotnet publish "$root\PFlow.App" -c Release -r $rid --self-contained true -p:RuntimeFrameworkVersion=10.0.13 -o "$root\dist\$rid"
if ($LASTEXITCODE) { throw 'Windows app build failed.' }
Copy-Item "$engine\*" "$root\dist\$rid\engine" -Force
Copy-Item "$PSScriptRoot\install-windows.ps1","$PSScriptRoot\WindowsArchitecture.ps1" "$root\dist\$rid"
Assert-PFlowArchitecture "$root\dist\$rid" $arch
# Windows shows these as the app and publisher in Task Manager, startup apps and file details.
$label = [Diagnostics.FileVersionInfo]::GetVersionInfo("$root\dist\$rid\pFlow.exe")
if ($label.ProductName -ne 'pFlow' -or $label.FileDescription -ne 'pFlow' -or $label.CompanyName -ne 'Pesh') { throw "Unexpected public app labels: $($label.ProductName) / $($label.FileDescription) / $($label.CompanyName)." }
Write-Output "Published $root\dist\$rid"
