<#
.SYNOPSIS
  Turn the prefer-IPv6 DNS filter (for IDM) on or off.

.DESCRIPTION
  on      start the filter, make it start at every logon, and point the
          network adapter at it (127.0.0.1 / ::1 first, your normal DNS
          servers kept as fallback). Asks for admin once (UAC).
  off     restore the adapter to normal DHCP DNS and stop the filter.
          The logon task stays but is disabled, so "on" is instant later.
  status  show whether it is running and whether IPv4 is being filtered.
  remove  same as off, plus deletes the logon task.

.EXAMPLE
  .\idm-ipv6.ps1 on
  .\idm-ipv6.ps1 off
  .\idm-ipv6.ps1 status
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('on', 'off', 'status', 'remove')]
    [string] $Action = 'status',
    [string] $Adapter = 'Ethernet'
)

$ErrorActionPreference = 'Stop'
$Here     = Split-Path -Parent $PSCommandPath
$TaskName = 'PreferIPv6DNS'
$Script   = Join-Path $Here 'prefer_ipv6_dns.py'
$Config   = Join-Path $Here 'config.json'
$TestHost = 'speed.cloudflare.com'   # dual-stack host used for the live check

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FilterProcess {
    Get-CimInstance Win32_Process -Filter "Name = 'pythonw.exe' OR Name = 'python.exe'" |
        Where-Object { $_.CommandLine -like "*prefer_ipv6_dns.py*" }
}

function Initialize-Config {
    # First run only: upstreams = the DNS servers the adapter uses today, plus Cloudflare as a last resort.
    if (Test-Path $Config) { return }
    $v4 = @((Get-DnsClientServerAddress -InterfaceAlias $Adapter -AddressFamily IPv4).ServerAddresses) |
          Where-Object { $_ -and $_ -ne '127.0.0.1' }
    $v6 = @((Get-DnsClientServerAddress -InterfaceAlias $Adapter -AddressFamily IPv6).ServerAddresses) |
          Where-Object { $_ -and $_ -ne '::1' -and $_ -notlike 'fec0:*' } | Select-Object -Unique
    $up = @($v4) + @($v6) + @('1.1.1.1', '2606:4700:4700::1111') | Select-Object -Unique
    @{ listen = @('127.0.0.1', '::1'); port = 53; upstreams = $up; timeout = 2.0 } |
        ConvertTo-Json | Set-Content $Config -Encoding ASCII
}

function Get-Upstreams {
    (Get-Content $Config | ConvertFrom-Json).upstreams
}

function Show-Status {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    "logon task : " + $(if ($task) { $task.State } else { 'not registered' })
    "filter     : " + $(if (Get-FilterProcess) { 'running' } else { 'not running' })
    Get-DnsClientServerAddress -InterfaceAlias $Adapter | Where-Object ServerAddresses | ForEach-Object {
        "{0,-11}: {1}" -f "DNS $(if ($_.AddressFamily -eq 2) { 'IPv4' } else { 'IPv6' })", ($_.ServerAddresses -join ', ')
    }
    Clear-DnsClientCache
    $a = Resolve-DnsName $TestHost -Type A -ErrorAction SilentlyContinue | Where-Object Type -eq 'A'
    "IPv4 filter: " + $(if ($a) { "OFF ($TestHost still returns IPv4)" } else { "ON  ($TestHost returns IPv6 only)" })
}

if ($Action -eq 'status') { Show-Status; return }

# Adapter DNS changes need admin: re-run this script elevated, then show status here.
if (-not (Test-Admin)) {
    Start-Process powershell -Verb RunAs -Wait -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", $Action, '-Adapter', $Adapter)
    Start-Sleep -Seconds 1
    Show-Status
    return
}

# ------------------------------------------------------------------ elevated --
switch ($Action) {
    'on' {
        Initialize-Config
        python -m pip install --user --quiet -r (Join-Path $Here 'requirements.txt')
        $pythonw  = (Get-Command pythonw).Source
        $act      = New-ScheduledTaskAction -Execute $pythonw -Argument "`"$Script`"" -WorkingDirectory $Here
        $trig     = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -RestartCount 3 `
                        -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew -Hidden
        Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trig -Settings $settings `
            -User $env:USERNAME -Force | Out-Null
        Enable-ScheduledTask -TaskName $TaskName | Out-Null
        if (-not (Get-FilterProcess)) { Start-ScheduledTask -TaskName $TaskName; Start-Sleep -Seconds 2 }
        if (-not (Get-FilterProcess)) { throw "filter did not start - see $Here\prefer_ipv6_dns.log" }

        $up = Get-Upstreams
        $servers = @('127.0.0.1') + @($up | Where-Object { $_ -notlike '*:*' }) +
                   @('::1')       + @($up | Where-Object { $_ -like '*:*' })
        Set-DnsClientServerAddress -InterfaceAlias $Adapter -ServerAddresses $servers
    }
    { $_ -in 'off', 'remove' } {
        Set-DnsClientServerAddress -InterfaceAlias $Adapter -ResetServerAddresses
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Get-FilterProcess | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        if ($Action -eq 'remove') {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        } else {
            Disable-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Out-Null
        }
    }
}
Clear-DnsClientCache
