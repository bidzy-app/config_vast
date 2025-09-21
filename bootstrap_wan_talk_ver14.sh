#!/usr/bin/env bash
set -Eeuo pipefail

log() { printf '%s %s\n' "$(date -u +'%F %T UTC')" "$*"; }
trap 'log "ERROR: bootstrap failed on line $LINENO"' ERR

log "Bootstrap started"

SUP_SOCK=${SUP_SOCK:-/var/run/supervisor.sock}
log "Waiting for supervisor socket at $SUP_SOCK ..."
for i in {1..90}; do
    [[ -S "$SUP_SOCK" ]] && break
    (( i % 10 == 0 )) && log "Still waiting... ($i/90)"
    sleep 1
done
[[ ! -S "$SUP_SOCK" ]] && { log "Supervisor socket not found after 90 seconds."; exit 1; }
log "Supervisor is running."

log "Stopping services..."
supervisorctl stop comfyui caddy sshd syncthing || true

log "Running provision script for wan_talk_ver4.0"
if curl -fsSL --retry 5 https://raw.githubusercontent.com/bidzy-app/config_vast/main/wan_talk_ver4.0.sh -o /tmp/provision.sh; then
  bash /tmp/provision.sh >>/var/log/onstart_provision.log 2>&1
else
  log "ERROR: Failed to download wan_talk_ver4.0.sh"
fi

log "Starting comfyui via supervisor"
supervisorctl start comfyui || log "WARN: comfyui did not start"

# Авто‑хил портов: если внешняя публикация идёт на INTERNAL_PORT, а Comfy слушает на COMFYUI_PORT — проксируем.
INTERNAL_PORT="${INTERNAL_PORT:-8188}"
COMFYUI_PORT="${COMFYUI_PORT:-18188}"
if [[ "$INTERNAL_PORT" != "$COMFYUI_PORT" ]]; then
  log "Port mismatch: INTERNAL_PORT=$INTERNAL_PORT, COMFYUI_PORT=$COMFYUI_PORT. Starting local proxy..."
  bash -lc '
    set -Eeuo pipefail
    command -v socat >/dev/null 2>&1 || (apt-get update -y >/dev/null 2>&1 && apt-get install -y socat >/dev/null 2>&1)
    nohup socat TCP-LISTEN:'"$INTERNAL_PORT"',fork,reuseaddr TCP:127.0.0.1:'"$COMFYUI_PORT"' >/var/log/port'"$INTERNAL_PORT"'_proxy.log 2>&1 &
  ' || log "WARN: proxy setup failed"
fi

log "Starting UDP22 helper"
curl -fsSL --retry 5 https://raw.githubusercontent.com/bidzy-app/config_vast/main/start_server_udp22.sh \
  | bash >>/var/log/onstart_udp22.log 2>&1 || log "WARN: udp22 script failed"

log "Bootstrap finished successfully"