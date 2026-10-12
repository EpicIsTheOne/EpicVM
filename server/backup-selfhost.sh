#!/usr/bin/env bash
set -euo pipefail
umask 077
[[ $# -eq 1 ]] || { echo 'Usage: backup-selfhost.sh NEW_BACKUP_PATH.tar.gz' >&2; exit 2; }
[[ ! -e "$1" ]] || { echo 'Backup path already exists.' >&2; exit 1; }
destination=$(realpath -m -- "$1")
case "$destination" in /opt/epicvm-selfhost/*) echo 'Store backups outside the installation directory.' >&2; exit 1;; esac
cd /opt/epicvm-selfhost
docker compose stop portal
trap 'docker compose start portal >/dev/null' EXIT
tar -czf "$destination" -- .env compose.selfhost.yaml Caddyfile.selfhost state
chmod 600 "$destination"
echo 'Private offline backup created. It contains credentials and certificates if stored in the state directory. Keep it private.'
