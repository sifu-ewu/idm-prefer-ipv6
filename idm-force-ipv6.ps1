<#
.SYNOPSIS
  Force Internet Download Manager to use IPv6 for specific hosts.

.DESCRIPTION
  IDM supports IPv6 but always prefers IPv4 when a host has both. Windows
  lets a hosts-file entry override DNS, so pinning only the IPv6 address
  for a host hides its IPv4 address from IDM (and every other program).

  Entries written by this script are tagged "# idm-ipv6" so -Remove can
  undo them cleanly without touching anything else in the hosts file.

.EXAMPLE
  .\idm-force-ipv6.ps1 files.example.com cdn.example.com
  .\idm-force-ipv6.ps1 -Remove files.example.com
  .\idm-force-ipv6.ps1 -Remove            # removes every idm-ipv6 entry
  .\idm-force-ipv6.ps1 -List
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]] $Hosts,
    [switch] $Remove,
    [switch] $List
)

$Tag       = '# idm-ipv6'
$HostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Re-launch elevated if needed (hosts file is admin-only).
if (-not (Test-Admin)) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Remove) { $argList += '-Remove' }
    if ($List)   { $argList += '-List' }
    $argList += $Hosts
    Start-Process powershell -Verb RunAs -Wait -ArgumentList $argList
    return
}

$lines = Get-Content $HostsPath -ErrorAction Stop

if ($List) {
    $lines | Where-Object { $_ -like "*$Tag*" }
    if (-not ($lines | Where-Object { $_ -like "*$Tag*" })) { "no idm-ipv6 entries" }
    return
}

if ($Remove) {
    if ($Hosts) {
        $keep = $lines | Where-Object {
            if ($_ -notlike "*$Tag*") { return $true }
            $name = ($_ -split '\s+')[1]
            return $name -notin $Hosts
        }
    } else {
        $keep = $lines | Where-Object { $_ -notlike "*$Tag*" }
    }
    Set-Content -Path $HostsPath -Value $keep -Encoding ASCII
    ipconfig /flushdns | Out-Null
    "removed idm-ipv6 entries" + $(if ($Hosts) { " for: $($Hosts -join ', ')" })
    return
}

if (-not $Hosts) { Write-Error "Give one or more hostnames, or use -List / -Remove."; return }

$added = @()
foreach ($h in $Hosts) {
    $h = $h.Trim().ToLower()
    if (-not $h) { continue }
    $aaaa = Resolve-DnsName $h -Type AAAA -ErrorAction SilentlyContinue |
            Where-Object { $_.Type -eq 'AAAA' } | Select-Object -ExpandProperty IPAddress
    if (-not $aaaa) { Write-Warning "$h has no IPv6 (AAAA) address - skipped"; continue }

    # Drop any previous idm-ipv6 entry for this host, then add fresh ones.
    $lines = $lines | Where-Object { -not ($_ -like "*$Tag*" -and (($_ -split '\s+')[1]) -eq $h) }
    foreach ($ip in $aaaa) { $lines += "$ip`t$h`t$Tag" }
    $added += "$h -> $($aaaa -join ', ')"
}

if ($added) {
    Set-Content -Path $HostsPath -Value $lines -Encoding ASCII
    ipconfig /flushdns | Out-Null
    "pinned to IPv6:"; $added | ForEach-Object { "  $_" }
    "Restart IDM (or wait a minute) so it re-resolves the hosts."
}
