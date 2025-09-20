#!/usr/bin/env bash
set -Eeuo pipefail

log() {
    printf '%s %s\n' "$(date -u +'%F %T UTC')" "$*"
}

trap 'log "ERROR: bootstrap failed on line $LINENO"' ERR

log "Bootstrap started"

SUP_SOCK=${SUP_SOCK:-/var/run/supervisor.sock}
log "Waiting for supervisor socket at $SUP_SOCK ..."

for i in {1..90}; do
    if [[ -S "$SUP_SOCK" ]]; then
        break
    fi
    (( i % 10 == 0 )) && log "Still waiting... ($i/90)"
    sleep 1
done

if [[ ! -S "$SUP_SOCK" ]]; then
    log "Supervisor socket not found after 90 seconds."
    exit 1
fi
log "Supervisor is running."

# Останавливаем лишнее
log "Stopping services..."
supervisorctl stop comfyui caddy sshd syncthing || true

# Основная подготовка (CPU stage)
log "Running provision script for wan_talk_ver4.0"
if curl -fsSL --retry 5 https://raw.githubusercontent.com/bidzy-app/config_vast/main/wan_talk_ver4.0.sh -o /tmp/provision.sh; then
  bash /tmp/provision.sh >>/var/log/onstart_provision.log 2>&1
else
  log "ERROR: Failed to download wan_talk_ver4.0.sh"
fi

# Запуск comfyui (GPU stage)
log "Starting comfyui via supervisor"
supervisorctl start comfyui || log "WARN: comfyui did not start"

# UDP helper (опционален)
log "Starting UDP22 helper"
curl -fsSL --retry 5 https://raw.githubusercontent.com/bidzy-app/config_vast/main/start_server_udp22.sh \
  | bash >>/var/log/onstart_udp22.log 2>&1 || log "WARN: udp22 script failed"

log "Bootstrap finished successfully"