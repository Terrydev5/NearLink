# Run explicitly from an elevated PowerShell only when configuring the test PC.
# Rules are limited to this executable, Private networks, and the local subnet.
param([string]$Executable = (Join-Path $PSScriptRoot "NearLink.Windows.exe"))
$ErrorActionPreference = "Stop"
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Open PowerShell as administrator to configure firewall rules. NearLink itself runs as a normal user."
}
$programPath = (Resolve-Path $Executable).Path
foreach ($protocol in @("TCP", "UDP")) {
    $name = "NearLink-Private-$protocol"
    Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    $rule = @{
        Name = $name; DisplayName = "NearLink ($protocol, private local network)"
        Direction = "Inbound"; Action = "Allow"; Program = $programPath
        Profile = "Private"; RemoteAddress = "LocalSubnet"; Protocol = $protocol
    }
    if ($protocol -eq "UDP") { $rule.LocalPort = 5353 }
    New-NetFirewallRule @rule | Out-Null
}
Write-Host "NearLink is allowed on private local networks. The firewall remains enabled."
