#!/usr/bin/env bash
# Bounded separate-server installation. Uses published images; never builds on a VPS.
set -euo pipefail
umask 077
if [[ $# -ne 6 ]]; then
  echo 'Usage: setup-selfhost.sh PORTAL_IMAGE CADDY_IMAGE PORTAL_HOST STREAM_HOST WINDOWS_TAILSCALE_IP ADMIN_NAME' >&2
  exit 2
fi
portal_image=$1; caddy_image=$2; portal_host=$3; stream_host=$4; host_address=$5; admin_name=$6
for image in "$portal_image" "$caddy_image"; do
  [[ "$image" =~ ^[a-zA-Z0-9./:_-]+@sha256:[a-f0-9]{64}$ ]] || { echo 'Use verified digest-pinned release images.' >&2; exit 2; }
done
for hostname in "$portal_host" "$stream_host"; do
  [[ "$hostname" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+[a-zA-Z0-9]$ ]] || { echo 'Use DNS hostnames without schemes or paths.' >&2; exit 2; }
done
[[ "$host_address" =~ ^100\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Use the Windows host Tailscale IPv4 address.' >&2; exit 2; }
[[ "$admin_name" =~ ^[a-zA-Z0-9_]{3,32}$ ]] || { echo 'Use an administrator name with 3-32 letters, numbers or underscores.' >&2; exit 2; }
command -v docker >/dev/null
docker compose version >/dev/null
destination=/opt/epicvm-selfhost
if [[ -e "$destination" ]]; then
  echo 'An existing installation was found. Its accounts and proxy settings were preserved. Use its repair/update path.' >&2
  exit 1
fi
if command -v ss >/dev/null && ss -Hlt '( sport = :80 or sport = :443 )' | read -r _; then
  echo 'Ports 80/443 are occupied. Use the existing proxy integration described in the guide.' >&2
  exit 1
fi
mkdir -p "$destination/state"
script_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cp -- "$script_root/compose.selfhost.yaml" "$script_root/Caddyfile.selfhost" "$destination/"
cat > "$destination/server-configuration.json" <<EOF
{"layout":"separate-server","portalOrigin":"https://$portal_host","publicOrigin":"https://$stream_host","hostId":"initial-host","displayName":"Initial Windows host","agentUrl":"http://$host_address:8765"}
EOF
cat > "$destination/.env" <<EOF
EPICVM_SERVER_IMAGE=$portal_image
EPICVM_CADDY_IMAGE=$caddy_image
EPICVM_SETUP_ROOT=$destination/state
EPICVM_PORTAL_HOST=$portal_host
EOF
docker pull "$portal_image"
docker pull "$caddy_image"
docker run --rm -it --user 0:0 --volume "$destination/state:/state" --volume "$destination/server-configuration.json:/configuration.json:ro" "$portal_image" \
  python /package/scripts/initialize_portal.py --root /state --configuration /configuration.json --admin "$admin_name"
chown -R 999:999 "$destination/state"
chmod -R go-rwx "$destination/state"
cd -- "$destination"
docker compose config --quiet
docker compose up -d --wait --wait-timeout 120
echo "Portal installed at https://$portal_host/EpicVM. Continue Windows host setup. Streaming has not been verified."
