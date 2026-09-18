"""
Prefer-IPv6 DNS filter.

A tiny local DNS forwarder that makes IPv4-preferring programs (IDM) use
IPv6 whenever a host has it:

  * A (IPv4) query  -> ask upstream for AAAA first.
                       AAAA exists  -> answer "no A records" (NOERROR, empty)
                       no AAAA      -> forward the A query unchanged
  * everything else -> forwarded unchanged

Config lives in config.json next to this file (written by install.ps1).
Run with --verbose to log every filtered name.
"""
import argparse
import json
import logging
import logging.handlers
import socket
import socketserver
import struct
import sys
import threading
from pathlib import Path

import dns.flags
import dns.message
import dns.rdatatype

HERE = Path(__file__).resolve().parent
CONFIG = json.loads((HERE / "config.json").read_text())

LISTEN = CONFIG.get("listen", ["127.0.0.1", "::1"])
PORT = int(CONFIG.get("port", 53))
UPSTREAMS = CONFIG["upstreams"]          # list of IP strings, tried in order
TIMEOUT = float(CONFIG.get("timeout", 2.0))

log = logging.getLogger("prefer-ipv6-dns")


# ----------------------------------------------------------------- upstream --

def _upstream_addr(ip):
    fam = socket.AF_INET6 if ":" in ip else socket.AF_INET
    return fam, (ip, 53)


def forward_udp(wire):
    """Send raw DNS bytes to the first upstream that answers; return raw reply."""
    for ip in UPSTREAMS:
        fam, addr = _upstream_addr(ip)
        try:
            with socket.socket(fam, socket.SOCK_DGRAM) as s:
                s.settimeout(TIMEOUT)
                s.sendto(wire, addr)
                return s.recv(65535)
        except OSError as e:
            log.debug("upstream %s failed: %s", ip, e)
    raise OSError("all upstreams failed")


def forward_tcp(wire):
    for ip in UPSTREAMS:
        fam, addr = _upstream_addr(ip)
        try:
            with socket.create_connection(addr, timeout=TIMEOUT) as s:
                s.sendall(struct.pack("!H", len(wire)) + wire)
                hdr = _recv_exact(s, 2)
                return _recv_exact(s, struct.unpack("!H", hdr)[0])
        except OSError as e:
            log.debug("upstream %s (tcp) failed: %s", ip, e)
    raise OSError("all upstreams failed")


def _recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise OSError("connection closed")
        buf += chunk
    return buf


def forward(wire, via_tcp):
    """Forward; if a UDP reply is truncated, retry over TCP."""
    if via_tcp:
        return forward_tcp(wire)
    reply = forward_udp(wire)
    if dns.message.from_wire(reply).flags & dns.flags.TC:
        return forward_tcp(wire)
    return reply


# ------------------------------------------------------------------- filter --

def has_ipv6(name):
    q = dns.message.make_query(name, dns.rdatatype.AAAA)
    try:
        reply = dns.message.from_wire(forward(q.to_wire(), via_tcp=False))
    except Exception as e:                       # noqa: BLE001
        log.debug("AAAA probe for %s failed: %s", name, e)
        return False
    return any(rr.rdtype == dns.rdatatype.AAAA for rr in reply.answer)


def resolve(wire, via_tcp):
    """Return raw response bytes for a raw query."""
    try:
        query = dns.message.from_wire(wire)
    except Exception:                            # noqa: BLE001
        return forward(wire, via_tcp)            # not parseable, pass through

    if len(query.question) == 1 and query.question[0].rdtype == dns.rdatatype.A:
        name = query.question[0].name
        if has_ipv6(name):
            log.info("filtered A for %s (has AAAA)", name.to_text(omit_final_dot=True))
            resp = dns.message.make_response(query)
            resp.flags |= dns.flags.RA
            resp.set_rcode(dns.rcode.NOERROR)
            return resp.to_wire()

    return forward(wire, via_tcp)


# ------------------------------------------------------------------ servers --

class UDPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        wire, sock = self.request
        try:
            sock.sendto(resolve(wire, via_tcp=False), self.client_address)
        except Exception as e:                   # noqa: BLE001
            log.warning("udp query failed: %s", e)


class TCPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            hdr = _recv_exact(self.request, 2)
            wire = _recv_exact(self.request, struct.unpack("!H", hdr)[0])
            reply = resolve(wire, via_tcp=True)
            self.request.sendall(struct.pack("!H", len(reply)) + reply)
        except Exception as e:                   # noqa: BLE001
            log.warning("tcp query failed: %s", e)


def make_server(cls, handler, addr):
    fam = socket.AF_INET6 if ":" in addr else socket.AF_INET

    class Srv(cls):
        address_family = fam
        allow_reuse_address = True
        daemon_threads = True

    return Srv((addr, PORT), handler)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--verbose", action="store_true", help="log every filtered name")
    args = ap.parse_args()

    handler = logging.handlers.RotatingFileHandler(
        HERE / "prefer_ipv6_dns.log", maxBytes=512_000, backupCount=1, encoding="utf-8")
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    log.addHandler(handler)
    log.setLevel(logging.INFO if args.verbose else logging.WARNING)
    if sys.stderr:                               # absent under pythonw
        log.addHandler(logging.StreamHandler(sys.stderr))

    servers = []
    for addr in LISTEN:
        for cls, h in ((socketserver.ThreadingUDPServer, UDPHandler),
                       (socketserver.ThreadingTCPServer, TCPHandler)):
            srv = make_server(cls, h, addr)
            threading.Thread(target=srv.serve_forever, daemon=True).start()
            servers.append(srv)

    log.warning("listening on %s port %d, upstreams %s", LISTEN, PORT, UPSTREAMS)
    try:
        threading.Event().wait()
    finally:
        for srv in servers:
            srv.shutdown()


if __name__ == "__main__":
    main()
