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

    if (( i % 10 == 0 )); then
        log "Still waiting... ($i/90)"
    fi

    sleep 1
done

if [[ ! -S "$SUP_SOCK" ]]; then
    log "Supervisor socket not found after 90 seconds."
    exit 1
fi
log "Supervisor is running."

# Останавливаем лишнее и чистим конфиги
log "Stopping services..."
supervisorctl stop comfyui caddy sshd syncthing || true

# Основная подготовка
log "Running provision script for wan_talk_ver3.6"
if curl -fsSL --retry 5 https://raw.githubusercontent.com/bidzy-app/config_vast/main/wan_talk_ver3.6.sh -o /tmp/provision.sh; then
  bash /tmp/provision.sh >>/var/log/onstart_provision.log 2>&1
else
  log "ERROR: Failed to download wan_talk_ver3.6.sh"
fi

# Запуск comfyui
log "Starting comfyui via supervisor"
supervisorctl start comfyui || log "WARN: comfyui did not start"

# UDP helper
log "Starting UDP21 helper"
curl -fsSL --retry 5 https://raw.githubusercontent.com/bidzy-app/config_vast/main/start_server_udp21.sh \
  | bash >>/var/log/onstart_udp21.log 2>&1 || log "WARN: udp21 script failed"

log "Bootstrap finished successfully"


