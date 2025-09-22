#!/usr/bin/env bash
# bootstrap_wan_talk_ver20.sh
set -Eeuo pipefail
log(){ printf '%s %s\n' "$(date -u +'%F %T UTC')" "$*"; }
trap 'log "ERROR: bootstrap failed on line $LINENO"' ERR

SUP_SOCK=${SUP_SOCK:-/var/run/supervisor.sock}
COMFY_ROOT="${COMFY_REAL_ROOT:-${COMFY_ROOT:-/opt/ComfyUI}}"
DEFAULT_COMFY_PORT="${COMFYUI_PORT:-18188}"
WAIT_SUP_SECS="${WAIT_SUP_SECS:-90}"
WAIT_COMFY_READY_SECS="${WAIT_COMFY_READY_SECS:-900}"    # до 15 минут
START_PYWORKER="${START_PYWORKER:-0}"                   # 1 = запускать PyWorker
MODEL_LOG_PATH="${MODEL_LOG_PATH:-/workspace/logtail.log}"

have(){ command -v "$1" >/dev/null 2>&1; }

ensure_tools(){
  if ! have curl; then apt-get update -y >/dev/null 2>&1 || true; apt-get install -y curl >/dev/null 2>&1 || true; fi
  if ! have socat; then apt-get update -y >/dev/null 2>&1 || true; apt-get install -y socat net-tools iproute2 >/dev/null 2>&1 || true; fi
}

fix_loop_symlink(){
  local p="$1"
  if [ -L "$p" ]; then
    local tgt; tgt="$(readlink "$p" || true)"
    if [ "$tgt" = "$p" ]; then
      log "Fixing self-symlink: $p"
      unlink "$p" || true
      mkdir -p "$p"
      chown -R root:root "$p" || true
      chmod 2775 "$p" || true
    fi
  fi
}

fix_all_symlinks(){
  fix_loop_symlink "$COMFY_ROOT"
  fix_loop_symlink "/opt/serverless"
  mkdir -p /opt/serverless/providers || true
  fix_loop_symlink "/opt/serverless/providers"
  fix_loop_symlink "/opt/serverless/providers/runpod"
}

python_bin(){
  if [ -x /opt/micromamba/envs/comfyui/bin/python ]; then
    echo "/opt/micromamba/envs/comfyui/bin/python"
  elif have python3; then
    echo "python3"
  else
    echo "python"
  fi
}

start_comfy_supervisor(){
  log "Starting comfyui via supervisor"
  supervisorctl start comfyui || log "WARN: comfyui did not start by supervisor"
}

start_comfy_manual(){
  local port="$1"
  mkdir -p "$COMFY_ROOT"
  cd "$COMFY_ROOT" 2>/dev/null || cd /opt/ComfyUI || true
  local PY; PY="$(python_bin)"
  log "Starting ComfyUI manually on 0.0.0.0:${port} using: $PY"
  nohup "$PY" -u main.py --listen 0.0.0.0 --port "$port" >/var/log/comfyui.manual.log 2>&1 & disown || true
  sleep 3
}

curl_code(){ curl -s -m 5 -o /dev/null -w "%{http_code}" "$1" || true; }

wait_comfy_ready_pick_port(){
  local tout="$1" t0 now code p
  t0="$(date +%s)"
  while true; do
    for p in 18188 8188; do
      code="$(curl_code "http://127.0.0.1:${p}/system_stats")"
      if [ "$code" = "200" ]; then echo "$p"; return 0; fi
    done
    now="$(date +%s)"; if [ $((now - t0)) -ge "$tout" ]; then echo ""; return 1; fi
    sleep 2
  done
}

ensure_iface_proxy(){
  # ensure_iface_proxy <SRC_PORT> <DST_PORT>
  local SRC="$1" DST="$2"
  [ -z "$SRC" ] && return 0; [ -z "$DST" ] && return 0
  if (ss -ltnp 2>/dev/null || netstat -tulpn 2>/dev/null) | grep -qE ":${SRC}\b"; then
    log "Proxy/listener already present on :${SRC}"
    return 0
  fi
  log "Starting TCP proxy 0.0.0.0:${SRC} -> 127.0.0.1:${DST}"
  nohup socat TCP-LISTEN:"${SRC}",fork,reuseaddr TCP:127.0.0.1:"${DST}" >/var/log/port${SRC}_proxy.log 2>&1 & disown || true
  sleep 1
}

print_listeners(){
  log "Sockets listening (18188/8188, 3000):"
  (ss -ltnp 2>/dev/null || netstat -tulpn 2>/dev/null) | egrep ':18188|:8188|:3000' || true
}

setup_logtail(){
  mkdir -p "$(dirname "$MODEL_LOG_PATH")"
  pkill -f "tail -n +0 -F" 2>/dev/null || true
  # Подхватываем все супервизорные comfyui-логи и ручной лог
  ( tail -n +0 -F /var/log/supervisor/*comfyui* /var/log/comfyui.manual.log 2>/dev/null || true ) >> "$MODEL_LOG_PATH" &
  export MODEL_LOG="$MODEL_LOG_PATH"
  echo "export MODEL_LOG=$MODEL_LOG_PATH" >/etc/profile.d/model_log.sh
  chmod 644 /etc/profile.d/model_log.sh || true
  sleep 1
  log "[INFO] checking 'To see the GUI go to:' in MODEL_LOG"
  grep -F "To see the GUI go to:" -n "$MODEL_LOG_PATH" | tail -n 3 || log "[WARN] not found yet — will appear after UI start"
}

maybe_start_pyworker(){
  if [ "$START_PYWORKER" != "1" ]; then
    log "PyWorker start skipped (set START_PYWORKER=1 to enable)"
    return 0
  fi
  local URL="${PYWORKER_START_URL:-https://raw.githubusercontent.com/bidzy-app/config_vast/main/start_server_udp25.sh}"
  log "Starting PyWorker via $URL"
  if curl -fsSL --retry 5 "$URL" -o /tmp/start_udp.sh; then
    chmod +x /tmp/start_udp.sh
    # Заполняем базовые env (можно переопределить снаружи)
    export BACKEND="${BACKEND:-comfyui}"
    export COMFY_MODEL="${COMFY_MODEL:-wan_talk_ver4.2}"
    export WORKER_PORT="${WORKER_PORT:-3000}"
    export VAST_TCP_PORT_${WORKER_PORT:0:0}$WORKER_PORT="$WORKER_PORT" || true
    export MODEL_SERVER_URL="${MODEL_SERVER_URL:-http://127.0.0.1:18188}"
    export MODEL_LOG="${MODEL_LOG:-$MODEL_LOG_PATH}"
    export UNSECURED="${UNSECURED:-false}"
    nohup /tmp/start_udp.sh >> /var/log/onstart_udp25.log 2>&1 & disown || true
  else
    log "WARN: failed to download start_server_udp25.sh"
  fi
}

fetch_and_run_provision(){
  local URL="${PROVISION_URL:-https://raw.githubusercontent.com/bidzy-app/config_vast/main/wan_talk_ver4.2.sh}"
  log "Running provision script: $URL"
  if curl -fsSL --retry 5 "$URL" -o /tmp/provision.sh; then
    bash /tmp/provision.sh >>/var/log/onstart_provision.log 2>&1 || log "WARN: provision returned non-zero"
  else
    log "ERROR: Failed to download provision script"
  fi
}

main(){
  ensure_tools
  fix_all_symlinks

  log "Waiting for supervisor socket at $SUP_SOCK (up to ${WAIT_SUP_SECS}s)..."
  for i in $(seq 1 "$WAIT_SUP_SECS"); do
    [[ -S "$SUP_SOCK" ]] && break
    (( i % 10 == 0 )) && log "Still waiting... ($i/${WAIT_SUP_SECS})"
    sleep 1
  done

  if [[ -S "$SUP_SOCK" ]]; then
    log "Supervisor is running; stop interfering services (wrapper/serverless)"
    supervisorctl stop comfyui_rp_api serverless || true
  else
    log "Supervisor socket not found — will use manual ComfyUI start later"
  fi

  fetch_and_run_provision

  if [[ -S "$SUP_SOCK" ]]; then
    start_comfy_supervisor
  else
    start_comfy_manual "$DEFAULT_COMFY_PORT"
  fi

  log "Waiting for ComfyUI readiness (18188/8188, timeout=${WAIT_COMFY_READY_SECS}s)..."
  INTERNAL_PORT="$(wait_comfy_ready_pick_port "$WAIT_COMFY_READY_SECS" || true)"
  if [ -z "$INTERNAL_PORT" ]; then
    log "ERROR: ComfyUI didn't become ready on 127.0.0.1:18188/8188 within timeout"
    print_listeners
    exit 1
  fi
  log "ComfyUI is ready on 127.0.0.1:${INTERNAL_PORT}"

  # Публикуем оба общеизвестных порта наружу, маршрутизируем на реальный внутренний:
  ensure_iface_proxy 18188 "$INTERNAL_PORT"
  ensure_iface_proxy 8188  "$INTERNAL_PORT"

  setup_logtail
  print_listeners
  maybe_start_pyworker
  log "Bootstrap finished successfully"
}

main "$@"