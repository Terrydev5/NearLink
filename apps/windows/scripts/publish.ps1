param([string]$OutputDirectory = "")
$ErrorActionPreference = "Stop"
$windowsRoot = Split-Path $PSScriptRoot -Parent
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $windowsRoot "artifacts/win-x64" }
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
Push-Location $windowsRoot
try {
    dotnet publish NearLink.Windows.csproj -c Release -r win-x64 --self-contained true -p:Platform=x64 -o $OutputDirectory
    if ($LASTEXITCODE -ne 0) { throw "Windows publication failed ($LASTEXITCODE)." }
    Copy-Item (Join-Path $PSScriptRoot "configure-firewall.ps1") $OutputDirectory -Force
    Copy-Item (Join-Path $windowsRoot "README.md") $OutputDirectory -Force
    Write-Host "Published to $OutputDirectory. Copy the entire directory, not only the EXE."
} finally { Pop-Location }
