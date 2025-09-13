#!/usr/bin/env bash
set -Eeuo pipefail

log() {
    printf '%s %s\n' "$(date -u +'%F %T UTC')" "$*"
}

trap 'log "ERROR: bootstrap failed on line $LINENO"' ERR

log "Bootstrap (wan_talk) started"

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

# Останавливаем все лишние сервисы (чтобы не мешались)
log "Stopping unnecessary services..."
supervisorctl stop comfyui caddy sshd syncthing || true

# Основная подготовка окружения (ComfyUI + модели/ноды через wan_talk_ver3.8.sh)
log "Running provision script (wan_talk_ver3.8.sh)"
if curl -fsSL --retry 5 https://raw.githubusercontent.com/bidzy-app/config_vast/main/wan_talk_ver3.8.sh -o /tmp/provision.sh; then
  bash /tmp/provision.sh >>/var/log/onstart_provision.log 2>&1
else
  log "ERROR: Failed to download wan_talk_ver3.8.sh"
fi

# ⚡ Запускаем PyWorker воркер wan_talk (через UDP helper)
log "Starting wan_talk PyWorker (start_server_udp23.sh)"
if curl -fsSL --retry 5 https://raw.githubusercontent.com/bidzy-app/config_vast/main/start_server_udp23.sh -o /tmp/start_server_udp23.sh; then
  chmod +x /tmp/start_server_udp23.sh
  bash /tmp/start_server_udp23.sh >>/var/log/onstart_udp23.log 2>&1 &
else
  log "ERROR: Failed to download start_server_udp23.sh"
fi

log "Bootstrap finished successfully (wan_talk is launching)"