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

# Остановим потенциально мешающие сервисы
log "Stopping services..."
supervisorctl stop comfyui caddy sshd syncthing || true

# CPU-этап: подготовка окружения/моделей/нод
log "Running provision script for wan_talk_ver4.1"
if curl -fsSL --retry 5 https://raw.githubusercontent.com/bidzy-app/config_vast/main/wan_talk_ver4.1.sh -o /tmp/provision.sh; then
  bash /tmp/provision.sh >>/var/log/onstart_provision.log 2>&1
else
  log "ERROR: Failed to download wan_talk_ver4.1.sh"
fi

# GPU-этап: запускаем ComfyUI
log "Starting comfyui via supervisor"
supervisorctl start comfyui || log "WARN: comfyui did not start"

# Дадим пару секунд на старт
sleep 2

# Универсальный экспорт портов наружу через socat.
# Открываем оба варианта внутреннего порта (18188 и 8188) и шлём на COMFYUI_PORT (по умолчанию 18188).
COMFYUI_PORT="${COMFYUI_PORT:-18188}"

ensure_iface_proxy() {
  local SRC_PORT="$1" DST_PORT="$2"

  # Пакеты для сети/прокси
  if ! command -v socat >/dev/null 2>&1 || ! command -v ip >/dev/null 2>&1; then
    log "Installing networking tools (socat, iproute2, net-tools)"
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y socat iproute2 net-tools >/dev/null 2>&1 || true
  fi

  # Первый глобальный IPv4 адрес контейнера
  local IFACE_IP
  IFACE_IP="$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)"

  if [[ -z "$IFACE_IP" ]]; then
    log "WARN: could not determine container interface IP; skipping proxy for ${SRC_PORT}"
    return 0
  fi

  # Уже слушает на интерфейсе?
  if (netstat -tulnp 2>/dev/null || ss -ltnp 2>/dev/null) | grep -qE "${IFACE_IP}:${SRC_PORT}\b"; then
    log "Proxy already listening on ${IFACE_IP}:${SRC_PORT}"
    return 0
  fi

  # Запускаем прокси: IFACE_IP:SRC_PORT -> 127.0.0.1:DST_PORT
  log "Starting iface proxy ${IFACE_IP}:${SRC_PORT} -> 127.0.0.1:${DST_PORT}"
  nohup socat TCP-LISTEN:${SRC_PORT},bind="${IFACE_IP}",fork,reuseaddr TCP:127.0.0.1:${DST_PORT} \
    >/var/log/port${SRC_PORT}_iface_proxy.log 2>&1 &
}

# Всегда открываем 18188 -> COMFYUI_PORT (обычно 18188)
ensure_iface_proxy 18188 "${COMFYUI_PORT}"
# И дублируем 8188 -> COMFYUI_PORT (если провайдер внезапно маппит внешний 18188 на внутренний 8188)
ensure_iface_proxy 8188 "${COMFYUI_PORT}"

# Доп. сервис воркера/телеметрии (опционально)
log "Starting UDP helper"
if curl -fsSL --retry 5 https://raw.githubusercontent.com/bidzy-app/config_vast/main/start_server_udp24.sh -o /tmp/start_udp.sh; then
  bash /tmp/start_udp.sh >>/var/log/onstart_udp22.log 2>&1 || log "WARN: udp helper script failed"
else
  log "WARN: failed to download start_server_udp24.sh"
fi

# Немного диагностики в лог
log "Sockets listening on 18188/8188 (if available):"
(netstat -tulnp 2>/dev/null || ss -ltnp 2>/dev/null) | egrep ':18188|:8188' || true

log "Bootstrap finished successfully"