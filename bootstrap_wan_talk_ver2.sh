#!/usr/bin/env bash
set -Eeuo pipefail

log() { printf '%s %s\n' "$(date -u +'%F %T UTC')" "$*"; }
trap 'log "ERROR: bootstrap failed on line $LINENO"' ERR

# Логи
mkdir -p /var/log
exec >>/var/log/onstart_bootstrap.log 2>&1

log "Bootstrap started"

# Базовая инициализация образа и ожидание supervisor
/opt/ai-dock/bin/init.sh
for i in {1..60}; do
  [[ -S /var/run/supervisor.sock ]] && break
  sleep 1
done

# Останавливаем лишнее и чистим конфиги
supervisorctl stop caddy sshd syncthing || true
supervisorctl stop comfyui || true

if [[ -d /etc/supervisor/supervisord/conf.d ]]; then
  rm -f \
    /etc/supervisor/supervisord/conf.d/caddy.conf \
    /etc/supervisor/supervisord/conf.d/quicktunnel.conf \
    /etc/supervisor/supervisord/conf.d/syncthing.conf || true
fi

supervisorctl reread || true
supervisorctl update || true
pkill -f 'cloudflared|caddy|syncthing' 2>/dev/null || true

# Основная подготовка
log "Running provision script"
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

log "Bootstrap finished"