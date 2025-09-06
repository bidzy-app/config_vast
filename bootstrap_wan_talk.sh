#!/usr/bin/env bash
set -Eeuo pipefail

log() {
    printf '%s %s\n' "$(date -u +'%F %T UTC')" "$*"
}

# Логи (по желанию)
mkdir -p /var/log
exec >>/var/log/onstart_bootstrap.log 2>&1

trap 'log "ERROR: onstart bootstrap failed on line $LINENO"' ERR

log "Bootstrap started"

# Базовая инициализация образа и ожидание supervisor
/opt/ai-dock/bin/init.sh || true &

for i in {1..30}; do
    [[ -S /var/run/supervisor.sock ]] && break
    sleep 1
done

# Останавливаем сервисы, чистим конфиги
supervisorctl stop caddy sshd syncthing || true
supervisorctl stop comfyui || true

if [[ -d /etc/supervisor/supervisord/conf.d ]]; then
    rm -f /etc/supervisor/supervisord/conf.d/caddy.conf \
          /etc/supervisor/supervisord/conf.d/quicktunnel.conf \
          /etc/supervisor/supervisord/conf.d/syncthing.conf || true
fi

supervisorctl reread || true
supervisorctl update || true
pkill -f 'cloudflared|caddy|syncthing' 2>/dev/null || true

# Основная подготовка
log "Running provision script"
curl -fsSL --retry 5 https://raw.githubusercontent.com/bidzy-app/config_vast/main/wan_talk_ver3.4.sh -o /tmp/provision.sh
bash /tmp/provision.sh

# Запуск comfyui
log "Starting comfyui via supervisor"
supervisorctl start comfyui || true

# Доп. сервер/туннель (если требуется)
log "Starting UDP20 helper"
curl -fsSL --retry 5 https://raw.githubusercontent.com/bidzy-app/config_vast/main/start_server_udp20.sh | bash

log "Bootstrap finished"
