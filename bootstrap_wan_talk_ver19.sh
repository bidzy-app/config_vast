#!/usr/bin/env bash
set -Eeuo pipefail

log() { printf '%s %s\n' "$(date -u +'%F %T UTC')" "$*"; }
trap 'log "ERROR: bootstrap failed on line $LINENO"' ERR

log "Bootstrap started"

SUP_SOCK=${SUP_SOCK:-/var/run/supervisor.sock}
COMFY_ROOT="${COMFY_REAL_ROOT:-${COMFY_ROOT:-/opt/ComfyUI}}"
DEFAULT_COMFY_PORT="${COMFYUI_PORT:-18188}"
WAIT_SUP_SECS="${WAIT_SUP_SECS:-90}"
WAIT_COMFY_READY_SECS="${WAIT_COMFY_READY_SECS:-900}"  # до 15 минут

have_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_tools() {
  if ! have_cmd curl; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y curl >/dev/null 2>&1 || true
  fi
}

fix_self_symlink() {
  # Чиним петлящий /opt/ComfyUI -> /opt/ComfyUI (ELOOP)
  if [ -L "$COMFY_ROOT" ]; then
    local tgt
    tgt="$(readlink "$COMFY_ROOT" || true)"
    if [ "$tgt" = "$COMFY_ROOT" ]; then
      log "Fixing self symlink at $COMFY_ROOT"
      unlink "$COMFY_ROOT" || true
      mkdir -p "$COMFY_ROOT"
      chown -R root:root "$COMFY_ROOT" || true
      chmod 2775 "$COMFY_ROOT" || true
    fi
  fi
}

fetch_and_run_provision() {
  local URL="https://raw.githubusercontent.com/bidzy-app/config_vast/main/wan_talk_ver4.2.sh"
  log "Running provision script for wan_talk_ver4.2"
  if curl -fsSL --retry 5 "$URL" -o /tmp/provision.sh; then
    bash /tmp/provision.sh >>/var/log/onstart_provision.log 2>&1 || log "WARN: provision returned non-zero"
  else
    log "ERROR: Failed to download $URL"
  fi
}

stop_services_via_supervisor() {
  log "Stopping services via supervisorctl..."
  supervisorctl stop comfyui caddy sshd syncthing || true
}

start_comfy_via_supervisor() {
  log "Starting comfyui via supervisor"
  supervisorctl start comfyui || log "WARN: comfyui did not start by supervisor"
}

python_bin() {
  if [ -x /opt/micromamba/envs/comfyui/bin/python ]; then
    echo "/opt/micromamba/envs/comfyui/bin/python"
  elif have_cmd python3; then
    echo "python3"
  else
    echo "python"
  fi
}

start_comfy_manually() {
  local port="$1"
  mkdir -p "$COMFY_ROOT"
  fix_self_symlink
  cd "$COMFY_ROOT" || cd /opt/ComfyUI || true
  local PY; PY="$(python_bin)"
  log "Starting ComfyUI manually on 0.0.0.0:${port} using: $PY"
  nohup "$PY" -u main.py --listen 0.0.0.0 --port "$port" >/var/log/comfyui.manual.log 2>&1 & disown || true
  sleep 3
}

curl_code() {
  local url="$1"
  curl -s -m 5 -o /dev/null -w "%{http_code}" "$url" || true
}

wait_comfy_ready_pick_port() {
  local tout="$1"
  local t0 now code p
  t0="$(date +%s)"
  while true; do
    for p in 18188 8188; do
      code="$(curl_code "http://127.0.0.1:${p}/system_stats")"
      if [ "$code" = "200" ]; then
        echo "$p"
        return 0
      fi
    done
    now="$(date +%s)"
    if [ $((now - t0)) -ge "$tout" ]; then
      echo ""
      return 1
    fi
    sleep 2
  done
}

ensure_iface_proxy() {
  # ensure_iface_proxy <SRC_PORT> <DST_PORT>
  local SRC_PORT="$1" DST_PORT="$2"
  [ -z "$SRC_PORT" ] && return 0
  [ -z "$DST_PORT" ] && return 0
  # Уже слушает?
  if (ss -ltnp 2>/dev/null || netstat -tulpn 2>/dev/null) | grep -qE ":${SRC_PORT}\b"; then
    log "Proxy/listener already present on :${SRC_PORT}"
    return 0
  fi
  if ! have_cmd socat; then
    log "Installing socat + net-tools"
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y socat net-tools iproute2 >/dev/null 2>&1 || true
  fi
  log "Starting TCP proxy 0.0.0.0:${SRC_PORT} -> 127.0.0.1:${DST_PORT}"
  nohup socat TCP-LISTEN:"${SRC_PORT}",fork,reuseaddr TCP:127.0.0.1:"${DST_PORT}" >/var/log/port${SRC_PORT}_proxy.log 2>&1 & disown || true
  sleep 1
}

print_listeners() {
  log "Sockets listening (18188/8188, 3000):"
  (ss -ltnp 2>/dev/null || netstat -tulpn 2>/dev/null) | egrep ':18188|:8188|:3000' || true
}

maybe_start_pyworker() {
  if [ "${START_PYWORKER:-0}" != "1" ]; then
    log "PyWorker start skipped (set START_PYWORKER=1 to enable)"
    return 0
  fi
  local URL="https://raw.githubusercontent.com/bidzy-app/config_vast/main/start_server_udp25.sh"
  log "Starting PyWorker (optional)"
  if curl -fsSL --retry 5 "$URL" -o /tmp/start_udp.sh; then
    export UNSECURED="${UNSECURED:-true}"
    bash /tmp/start_udp.sh >> /var/log/onstart_udp25.log 2>&1 || log "WARN: pyworker script failed"
  else
    log "WARN: failed to download $URL"
  fi
}

main() {
  ensure_tools
  fix_self_symlink

  log "Waiting for supervisor socket at $SUP_SOCK (up to ${WAIT_SUP_SECS}s)..."
  for i in $(seq 1 "$WAIT_SUP_SECS"); do
    [[ -S "$SUP_SOCK" ]] && break
    (( i % 10 == 0 )) && log "Still waiting... ($i/${WAIT_SUP_SECS})"
    sleep 1
  done

  if [[ -S "$SUP_SOCK" ]]; then
    log "Supervisor is running."
    stop_services_via_supervisor
  else
    log "Supervisor socket not found — will use manual ComfyUI start"
  fi

  fetch_and_run_provision

  if [[ -S "$SUP_SOCK" ]]; then
    start_comfy_via_supervisor
  else
    start_comfy_manually "$DEFAULT_COMFY_PORT"
  fi

  log "Waiting for ComfyUI readiness (18188/8188, timeout=${WAIT_COMFY_READY_SECS}s)..."
  INTERNAL_PORT="$(wait_comfy_ready_pick_port "$WAIT_COMFY_READY_SECS" || true)"
  if [ -z "$INTERNAL_PORT" ]; then
    log "ERROR: ComfyUI didn't become ready on 127.0.0.1:18188/8188 within timeout"
    print_listeners
    exit 1
  fi
  log "ComfyUI is ready on 127.0.0.1:${INTERNAL_PORT}"

  # Публикуем два общеизвестных порта наружу, маршрутизируем на реальный внутренний:
  ensure_iface_proxy 18188 "$INTERNAL_PORT"
  ensure_iface_proxy 8188 "$INTERNAL_PORT"

  print_listeners
  maybe_start_pyworker

  log "Bootstrap finished successfully"
}

main "$@"