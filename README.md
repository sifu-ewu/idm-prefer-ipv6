# idm-prefer-ipv6

Make Internet Download Manager (IDM) download over IPv6 whenever a host supports it.

IDM can connect over IPv6, but when a host has both IPv4 and IPv6 addresses it
always picks IPv4. There is no setting for this. This repo works around it with a
tiny local DNS filter that hides a host's IPv4 address whenever the host also has
an IPv6 one. IDM then sees only IPv6 for dual-stack hosts and still gets IPv4 for
hosts that have nothing else.

## How it works

`prefer_ipv6_dns.py` is a small DNS forwarder listening on `127.0.0.1` and `::1`.

| Incoming query | What the filter does |
|---|---|
| `A` (IPv4) for a host that has `AAAA` records | answers "no records" |
| `A` for a host with no `AAAA` | forwards the `A` query unchanged |
| anything else (`AAAA`, `MX`, `TXT`, ...) | forwards unchanged |

`idm-ipv6.ps1` runs the filter as a hidden logon task and points your network
adapter at it, keeping your normal DNS servers as fallbacks so name resolution
keeps working even if the filter is stopped.

## Requirements

- Windows 10 or 11
- Python 3.10+ on `PATH` (`python` and `pythonw`)
- The `dnspython` package (installed automatically on first `on`)

## Usage

```powershell
git clone https://github.com/sifu-ewu/idm-prefer-ipv6.git
cd idm-prefer-ipv6

.\idm-ipv6.ps1 on       # start filter, register logon task, repoint DNS (one UAC prompt)
.\idm-ipv6.ps1 status   # is it running, is IPv4 being filtered
.\idm-ipv6.ps1 off      # restore DHCP DNS, stop filter (task stays, disabled)
.\idm-ipv6.ps1 remove   # off, plus delete the logon task
```

Restart IDM after turning the filter on or off so it re-resolves hosts.

If your adapter is not called `Ethernet`, pass it: `.\idm-ipv6.ps1 on -Adapter "Wi-Fi"`.

On first `on` the script writes `config.json` with the DNS servers your adapter
uses at that moment plus Cloudflare as a last resort. Edit it if you want
different upstreams, then run `on` again.

### Verify

```powershell
Resolve-DnsName speed.cloudflare.com          # should list only AAAA records
Get-NetTCPConnection -OwningProcess (Get-Process IDMan).Id -State Established | Select RemoteAddress
```

While IDM downloads from a dual-stack host you should see `2xxx:` addresses only.

## Per-host alternative: `idm-force-ipv6.ps1`

If you would rather not filter DNS for the whole PC, pin individual hosts to
their IPv6 addresses in the hosts file instead:

```powershell
.\idm-force-ipv6.ps1 files.example.com        # pin one or more hosts
.\idm-force-ipv6.ps1 -List
.\idm-force-ipv6.ps1 -Remove files.example.com
.\idm-force-ipv6.ps1 -Remove                   # remove every entry this script added
```

Entries are tagged `# idm-ipv6` so removal never touches anything else in the
hosts file. The address is fixed when you run it, so re-run if the host moves.

## Caveats

- The filter affects every program on the PC, not only IDM. Browsers already
  prefer IPv6, so in practice nothing changes for them.
- A host that advertises IPv6 but whose IPv6 side is broken will fail instead of
  falling back to IPv4, because Windows never sees the IPv4 address. Run
  `.\idm-ipv6.ps1 off` and it is back to normal.
- The download server is often a different hostname from the website. A site
  can be reachable over IPv6 while its file servers are IPv4 only. Check with
  `Resolve-DnsName <download-host> -Type AAAA`.

## License

MIT
