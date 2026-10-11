# EpicVM local network mode, October 11, 2026

## Implementation and deployment

Implemented the explicit Open over local network desktop action. It calls the same authenticated desktop launch POST as the normal action, preserving seat reuse, then selects the local stream-launch handoff. The dashboard rechecks assignment/ownership and uses the existing sixty-second one-use grant, resource-scoped cookie, and authenticated Caddy routes. User-supplied origins are ignored.

Per-host settings live in /opt/blobe-vm/private/local-streams.json. Only enabled HTTPS origins expose the local button. A five-second local-health check precedes grant redemption. Failed reachability offers Use normal connection, which requests a fresh grant for the same stream without a seat-creation POST. Unconfigured local launches offer the same fallback.

The local viewer samples selected WebRTC candidate stats and network RTT. LAN connected requires direct host candidates with private IPv4 addresses on the same /24; relay candidates show Video uses a relay. Masked addresses, VPN ranges, or other subnets are not claimed to be LAN. This conservative detection may leave a real LAN stream labeled Direct video connection. RTT does not measure complete input-to-display latency.

Added a dedicated gateway installer and startup script. It uses a separate Caddy process, binds the host Ethernet address on port 8443, permits inbound TCP from LocalSubnet, keeps its admin listener on loopback port 2020, imports existing authenticated stream routes, and renews certificates using Cloudflare DNS-01. The supervisor starts/reloads it independently; failure cannot block the public gateway.

## Current activation state: enabled, router local DNS entry verified

At 18:40 UTC the user saved a router IPv4 DNS entry mapping
lan.epicvm.techexplore.us to 192.168.1.178. A direct query to 192.168.1.1
now returns that address. Ordinary hostname-based HTTPS health returned 200
with certificate verification enabled, without an address override. The live
authenticated gateway probe also passed using ordinary DNS, including stream
page access and cross-resource denial. The earlier DNS failure below describes
the state before this router entry was saved. Second-device streaming and DHCP
reservation remain unverified.

### Follow-up: missing admin button and rejected stream launch

The admin account had no explicit desktop grant rows and used the
host-gaming response fallback. That response omitted localConnectionAvailable.
Added the flag to that response and deployed only shared_games.py after checking
the live baseline hash. Nine host-gaming tests passed, including a new regression
for the admin fallback and disabled local configuration.

The active viewer's stored client certificate matched EpicVMWeb (3) in the
owner's Apollo state. Its permission mask was 50331648 (view/list only), and
the live stream log reported Permission denied. Matched the certificate to its
exact UUID and restored the existing launch/input mask 0x07001F00 through
Apollo's authenticated API. Other client permissions were unchanged; the old
mask was saved privately for rollback. No Windows seat was ended or recreated.

Browser probes through the dedicated automation wrapper reached videoReady=true
and a 1920x1080 canvas on both normal and local origins. The LAN viewer displayed
Direct video connection; it did not establish a second-device LAN latency
comparison. The test viewer was navigated away afterward, leaving the seat
running. Audio and physical input still need the user's hands-on check.

DNS-only A record lan.epicvm.techexplore.us -> 192.168.1.178 was created (record 0595769f24241606d461e1cec399520a). Dedicated Caddy binary downloaded through KVM2 with verified HTTPS; dns.providers.cloudflare was confirmed. The direct Windows download failed certificate validation and was not used.

The user added the Cloudflare token to API Proxy. It was retrieved privately, zone read was verified, and the token was stored with access limited to Epic and SYSTEM. The elevated installer configured the dedicated gateway and LocalSubnet firewall rule. Windows PowerShell incorrectly treated successful Caddy stderr validation logs as errors; the installer now checks a redirected subprocess exit code.

Let’s Encrypt issued the trusted certificate using DNS-01. Verified HTTPS health and OPTIONS responses, CORS/private-network access headers, unauthenticated stream rejection (401), authenticated stream page access, resource-scoped cookies, and cross-resource denial. Local redirects retain connection parameters. Invalid grants and repeated redemption are rejected (403), including replay from the local gateway to the public gateway. TLS verification was retained throughout; local HTTP probes supplied the known address while preserving hostname verification.

Both dashboard and host local-gateway settings are enabled. Live backend fixture requests verified the local handoff and normal fallback for the same route without creating a seat. Public gateway authentication probes still pass, public portal returns 200, and blobedash is healthy. Automatic renewal is configured, but a future renewal has not been observed.

The current router DNS server (192.168.1.1) returns NOERROR with no A records for this hostname. Cloudflare (1.1.1.1) and Google (8.8.8.8) return 192.168.1.178. Clearing the Windows DNS cache did not fix it; unmodified automation Chrome showed ERR_NAME_NOT_RESOLVED. The local failure message now explains enabling Secure DNS with Cloudflare/Google or allowing the hostname in router DNS settings. Normal connection remains available. No system DNS or router settings were changed, and the browser workaround has not been applied or tested on a friend's device.

Remaining external verification:

1. Confirm or create a router DHCP reservation for 192.168.1.178; current Ethernet assignment was observed, reservation was not verified.
2. Apply the DNS workaround on an affected device or allow the hostname at the router.
3. Use another device on that LAN for WebRTC connection verification and a like-for-like latency comparison. No performance improvement is currently claimed.

## Verification

29 targeted Python tests passed across test_local_stream, direct-stream authorization, recovery, supervisor, and host-gaming tests. They cover configured origin validation, ownership rejection, ignored injected destinations, local probe/fallback, disabled-mode handling, normal launch behavior, existing grant authorization, repeatable viewer patch, and seat-preserving launch/recovery.

Two Node tests passed for selected-pair LAN/relay classification and address parsing. Node syntax check, PowerShell installer parse, Vite build, and scoped git diff --check passed.

Dedicated automation Chrome used only C:\Users\Epic\bin\browser-harness.cmd. Actual built frontend fixture displayed the local action and same-desktop explanation. Clicking it called the usual launch path and navigated to the fixture stream with connection=local. Jev judged the option and its explanation visible (DONE, confidence 1.0, 179ms); deterministic URL checks were independent. The first background mouse click made no change; current DOM was reobserved and focus emulation enabled before the successful check. No production seat was created by these fixture checks.

## Deployment and rollback

Backup: /opt/blobe-vm/backups/lan-20261011T173827Z. Live backend hashes were checked against downloaded originals before replacing only dashboard/direct_stream.py and dashboard/shared_games.py. Only scoped SharedGames source and the new frontend asset were copied. Existing index metadata and scripts were preserved; the asset reference was swapped atomically. Container blobedash restarted and returned healthy.

Frontend asset: index-CeDfvcjZ.js. Public portal, asset, and account-check endpoint returned HTTP 200; fetched asset SHA-256 matched the built file. Live backend now confirms local_stream_origin('epic-pc') is the configured HTTPS origin, exposing the local option. The activation backend copy was gated on its previous SHA-256; prior source and disabled config were saved under the backup's activation directory. Two focused local-launch tests passed after adding the DNS guidance; installer syntax and scoped diff checks passed.

Five enabled host viewers received the network status module. Their stream.js originals were preserved as stream.js.before-lan-20261011. The watcher restarted hidden; stream processes were not stopped. No accounts/profiles or router settings changed. No commits or pushes.

Rollback application changes by restoring the two backend originals and prior frontend index from the backup, then restarting blobedash. Old assets remain present. Disable or remove the isolated local-gateway configuration if subsequently activated; the public Caddy remains independent.
