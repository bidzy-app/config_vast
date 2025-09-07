#!/usr/bin/env bash
set -Eeuo pipefail

log() { printf '%s %s\n' "$(date -u +'%F %T UTC')" "$*"; }
trap 'log "ERROR: bootstrap failed on line $LINENO"' ERR

# Логи в этот файл будут писаться благодаря команде в onstart
log "Bootstrap started inside the script"

# Ждем запуска supervisor, который был запущен командой onstart
log "Waiting for supervisor socket..."
for i in {1..60}; do
  [[ -S /var/run/supervisor.sock ]] && break
  log "Waiting... ($i/60)"
  sleep 1
done

if ! [[ -S /var/run/supervisor.sock ]]; then
    log "ERROR: Supervisor socket not found after 60 seconds."
    exit 1
fi
log "Supervisor is running."

# Останавливаем лишнее и чистим конфиги
log "Stopping services..."
supervisorctl stop comfyui caddy sshd syncthing || true

# Основная подготовка
log "Running provision script for wan_talk_ver3.4"
if curl -fsSL --retry 5 https://raw.githubusercontent.com/bidzy-app/config_vast/main/wan_talk_ver3.4.sh -o /tmp/provision.sh; then
  bash /tmp/provision.sh >>/var/log/onstart_provision.log 2>&1
else
  log "ERROR: Failed to download wan_talk_ver3.4.sh"
fi

# Запуск comfyui
log "Starting comfyui via supervisor"
supervisorctl start comfyui || log "WARN: comfyui did not start"

# UDP helper
log "Starting UDP20 helper"
curl -fsSL --retry 5 https://raw.githubusercontent.com/bidzy-app/config_vast/main/start_server_udp20.sh \
  | bash >>/var/log/onstart_udp20.log 2>&1 || log "WARN: udp20 script failed"

log "Bootstrap finished successfully"