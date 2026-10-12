# EpicVM direct streams

EpicVM launches paired gaming VMs and MultiSeat seats through the Windows host's
Moonlight Web path. The public base page at `https://epicbriiiii.zapto.org/`
remains the owner's WindowsStream page. EpicVM resources use
`/EpicVM/<resource>/` on that same host.

## Launch and authorization

The portal's VM console and native-game links lead to
`/EpicVM/stream-launch/<resource>` on KVM2. The dashboard checks the portal
user's VM assignment or seat ownership and signs a 60-second, one-use grant.
The browser posts it to the Windows host gateway. The gateway sets a
resource-scoped, secure session cookie, then Caddy authenticates each HTTP
request before forwarding the EpicVM user header to that resource's private
Moonlight Web instance. The WindowsStream password and personal launcher
credentials are not placed in seat accounts.

Private state is under `%LOCALAPPDATA%\EpicVM\direct-streams` on the Windows
host. The dashboard receives only the signing key and route manifest under
`/opt/blobe-vm/private` on KVM2. Never copy the instance `data.json`, signing
key, cookies, or pairing records into the repository or logs.

## Lifecycle

`scripts/supervise_host_direct_streams.py` checks the KVM2 paired-instance
inventory every 30 seconds. It imports newly paired gaming VMs and seats,
starts their host-local Moonlight processes, registers their Caddy and portal
routes, and restarts a missing process. A quarantined seat is disabled and its
stream process stopped; its Windows account and profile remain reusable.
`scripts/Start-EpicVMDirectStreams.ps1` starts the supervisor. WindowsStream's
start script also calls it. `scripts/Install-EpicVMDirectStreamsStartup.ps1`
installs the `EpicVM Direct Streams` logon task with a 15-second delay and
disables the old Startup shortcut. Run the installer elevated on the host.
The task starts the supervisor in the user's session. The supervisor validates
and starts the shared Caddy gateway when its admin listener is missing and no
Caddy process is running. An existing process without its listener is reported
for inspection rather than replaced.

The firewall rule `EpicVM Direct Streams WebRTC UDP` permits the Moonlight Web
executable on UDP ports 40900-41199. The supervisor refuses to allocate a
stream outside that range. The host router did not expose UPnP mappings during
setup, so ICE may use STUN or TURN according to the bundled configuration.

## Checks and recovery

- Check that the local gateway listens on 8090, and that each enabled route's
  `localPort` in `routes.json` listens on loopback.
- Probe public authorization with `scripts/probe_host_stream_gateway.py` and
  the private key path. The `--host-check` option also queries a paired host.
- Caddy imports the generated `caddy-routes.caddy` from the WindowsStream
  Caddyfile. Validate Caddy before a reload.
- An unpaired or unreachable guest may have a stream page but cannot pass the
  paired-host readiness check. Repair its Sunshine/Moonlight pairing first.
- A portal account or VM assignment change prevents a fresh EpicVM grant.
  Existing browser stream cookies expire after eight hours; stopping a seat
  also removes its route and stream process within the supervisor's next poll.

The original KVM2 Moonlight bundles remain available for repair, while EpicVM's
normal launch path uses the Windows host routes.

## Local network mode

The desktop card offers Open over local network only for a host enabled in
`/opt/blobe-vm/private/local-streams.json`. Example (after gateway verification):

```json
{"epic-pc":{"enabled":true,"origin":"https://lan.epicvm.techexplore.us:8443"}}
```

Both opening options POST to the existing desktop endpoint. The local option
then uses `?connection=local` on the same authenticated stream-launch route.
The dashboard rechecks seat ownership and signs the existing one-use grant.
The launcher probes the configured local origin for five seconds before
submitting it; browser local-network permission may be required. On failure,
Use normal connection requests a fresh grant for the same stream and seat.
No grant is placed in a shareable URL. Sharing a stream-launch URL still
requires the recipient's own account and resource assignment.

Some routers filter public DNS answers containing private addresses. The host's
current router returns an empty answer for the LAN hostname even though
Cloudflare and Google resolve it correctly. On affected devices, enable Secure
DNS using Cloudflare or Google in the browser, or allow this hostname in the
router's DNS settings. Do not disable TLS verification. The normal connection
remains available when local DNS or reachability fails.

Gateway setup:

1. Reserve the host's Ethernet IP in the router. The current IP is 192.168.1.178;
   DHCP reservation has not been verified. Publish a DNS-only A record for
   lan.epicvm.techexplore.us pointing to that IP.
2. Install a dedicated Caddy Windows binary with dns.providers.cloudflare in
   the private stream root as caddy-lan.exe. Keep the public Caddy untouched.
3. Store a token with DNS Edit and Zone Read on techexplore.us in the private
   stream root as lan-dns.token. Use API Proxy injection; do not print it.
4. Run Configure-EpicVMLocalGateway.ps1 elevated with -Address 192.168.1.178.
   The separate gateway binds only that address on 8443. Its firewall rule
   permits TCP from LocalSubnet; no new router forwarding is needed.
5. Verify trusted HTTPS, renewal configuration, unauthenticated stream denial,
   and an authorized launch. Then enable the host's local-streams.json entry.

Start-EpicVMDirectStreams.ps1 starts the dedicated LAN gateway when configured;
the supervisor recovers it and reloads route changes independently. DNS-01 lets
Caddy renew a trusted certificate for a private LAN address automatically.
Keep the DNS token outside the repo. Do not enable an origin with a self-signed
certificate, a missing token, or an unverified gateway.

Both normal and local viewers show their selected WebRTC connection and RTT when stats are
available. LAN connected requires host candidates with private IPv4 addresses
on the same /24, conservatively matching this host network. Masked candidate
addresses or another subnet produce Direct video connection rather than an
unsupported LAN claim; relay candidates show Video uses a relay. RTT is a
network round trip, not complete input-to-display latency. Switching connection
does not change video quality or bypass authentication. A second-device
comparison is still required before claiming a latency improvement.

The same candidate-pair RTT measurement is used on both paths. WebSocket
fallback displays the streamer's browser RTT when reported, or RTT unavailable.

## Stream access revocation

The host gateway validates portal-issued grants and sessions against the portal
authority. Password changes, disabled/rejected/deleted accounts, removed resource
access and administrator credential changes invalidate existing stream access.
HTTP authorization uses a two-second lease; active sessions are checked every
five seconds. Denial closes the affected viewer process and its transports.
The supervisor restarts the viewer for a fresh authorized connection, preserving
the Windows desktop and apps. Multiple clients on that resource disconnect
together. Portal validation outages fail closed, including for LAN streams.

Session tracking persists in the private nonce database. Keep that database and
its directory restricted to the host operator, SYSTEM and Administrators.
Deploy `dashboard/direct_stream.py`, `dashboard/direct_stream_auth.py` and the
host copies of `host_stream_gateway.py`/`direct_stream_auth.py` together. Restart
the gateway and enabled viewer processes once when upgrading from the legacy
version, because existing transports were not tracked. Preserve Windows seats.

The default authority is `https://techexplore.us/EpicVM/api/stream/validate`;
alternate deployments must configure `--authority` with their trusted HTTPS
portal. The probe requires `--grant-file PATH` containing a fresh grant issued
with the current account revision. Keep the file private and remove it afterward.
