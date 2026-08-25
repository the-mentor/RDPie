# RDPie
RDP Server for macOS 

## Network exposure

By default `rdpied` only binds loopback (127.0.0.1) — an RDP client must be
on the same machine. Do not expose port 3389 directly to the internet;
put it behind a VPN, Tailscale, or an SSH tunnel instead. `RDPIE_BIND_ALL=1`
widens the bind to all interfaces (see `docs/running-phase-3.md`) and
should only be used on a network you trust.
