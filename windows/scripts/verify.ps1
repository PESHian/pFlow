$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
dotnet run --project "$root\PFlow.Tests" -c Release
if ($LASTEXITCODE) { throw 'Core checks failed.' }
dotnet build "$root\PFlow.App" -c Release
if ($LASTEXITCODE) { throw 'WPF build failed.' }
