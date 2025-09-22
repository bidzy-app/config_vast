#!/usr/bin/env bash
# bootstrap_wan_talk_ver26.sh
set -Eeuo pipefail
log(){ printf '%s %s\n' "$(date -u +'%F %T UTC')" "$*"; }
trap 'log "ERROR: bootstrap failed on line $LINENO"' ERR

SUP_SOCK=${SUP_SOCK:-/var/run/supervisor.sock}
COMFY_ROOT="${COMFY_REAL_ROOT:-${COMFY_ROOT:-/opt/ComfyUI}}"
DEFAULT_COMFY_PORT="${COMFYUI_PORT:-18188}"
WAIT_SUP_SECS="${WAIT_SUP_SECS:-90}"
WAIT_COMFY_READY_SECS="${WAIT_COMFY_READY_SECS:-900}"
START_PYWORKER="${START_PYWORKER:-1}"                 # включено по умолчанию
MODEL_LOG_PATH="${MODEL_LOG_PATH:-/workspace/logtail.log}"

have(){ command -v "$1" >/dev/null 2>&1; }

ensure_tools(){
  if ! have curl; then apt-get update -y >/dev/null 2>&1 || true; apt-get install -y curl >/dev/null 2>&1 || true; fi
  if ! have socat; then apt-get update -y >/dev/null 2>&1 || true; apt-get install -y socat net-tools iproute2 >/dev/null 2>&1 || true; fi
  if ! have python3; then apt-get update -y >/dev/null 2>&1 || true; apt-get install -y python3 python3-venv python3-requests git >/dev/null 2>&1 || true; fi
  dpkg -s python3-venv >/dev/null 2>&1 || (apt-get update -y >/dev/null 2>&1 && apt-get install -y python3-venv >/dev/null 2>&1) || true
  dpkg -s python3-requests >/dev/null 2>&1 || (apt-get update -y >/dev/null 2>&1 && apt-get install -y python3-requests >/dev/null 2>&1) || true
  have git || (apt-get update -y >/dev/null 2>&1 && apt-get install -y git >/dev/null 2>&1) || true
}

fix_loop_symlink(){ local p="$1"; if [ -L "$p" ]; then local tgt; tgt="$(readlink "$p" || true)"; if [ "$tgt" = "$p" ]; then log "Fixing self-symlink: $p"; unlink "$p" || true; mkdir -p "$p"; chown -R root:root "$p" || true; chmod 2775 "$p" || true; fi; fi; }
fix_all_symlinks(){ fix_loop_symlink "$COMFY_ROOT"; fix_loop_symlink "/opt/serverless"; mkdir -p /opt/serverless/providers || true; fix_loop_symlink "/opt/serverless/providers"; fix_loop_symlink "/opt/serverless/providers/runpod"; }

python_bin(){ if [ -x /opt/micromamba/envs/comfyui/bin/python ]; then echo "/opt/micromamba/envs/comfyui/bin/python"; elif have python3; then echo "python3"; else echo "python"; fi; }

start_comfy_supervisor(){ log "Starting comfyui via supervisor"; supervisorctl start comfyui || log "WARN: comfyui did not start by supervisor"; }
start_comfy_manual(){
  local port="$1"
  mkdir -p "$COMFY_ROOT"
  cd "$COMFY_ROOT" 2>/dev/null || cd /opt/ComfyUI || true
  local PY; PY="$(python_bin)"
  log "Starting ComfyUI manually on 0.0.0.0:${port} using: $PY"
  nohup "$PY" -u main.py --listen 127.0.0.1 --disable-auto-launch --port "$port" >/var/log/comfyui.manual.log 2>&1 & disown || true
  sleep 3
}

curl_code(){ curl -s -m 5 -o /dev/null -w "%{http_code}" "$1" || true; }

wait_comfy_ready_pick_port(){
  local tout="$1" t0 now code p; t0="$(date +%s)"
  while true; do
    for p in 18188 8188; do
      code="$(curl_code "http://127.0.0.1:${p}/system_stats")"
      [ "$code" = "200" ] && { echo "$p"; return 0; }
    done
    now="$(date +%s)"; [ $((now - t0)) -ge "$tout" ] && { echo ""; return 1; }
    sleep 2
  done
}

ensure_iface_proxy(){ local SRC="$1" DST="$2"; [ -z "$SRC" ] || [ -z "$DST" ] && return 0
  if (ss -ltnp 2>/dev/null || netstat -tulpn 2>/dev/null) | grep -qE ":${SRC}\b"; then log "Proxy/listener already present on :${SRC}"; return 0; fi
  log "Starting TCP proxy 0.0.0.0:${SRC} -> 127.0.0.1:${DST}"
  nohup socat TCP-LISTEN:"${SRC}",fork,reuseaddr TCP:127.0.0.1:"${DST}" >/var/log/port${SRC}_proxy.log 2>&1 & disown || true
  sleep 1
}

print_listeners(){ log "Sockets listening (18188/8188/18288, 3000):"; (ss -ltnp 2>/dev/null || netstat -tulpn 2>/dev/null) | egrep ':18188|:8188|:18288|:3000' || true; }

setup_logtail(){
  mkdir -p "$(dirname "$MODEL_LOG_PATH")"
  pkill -f "tail -n +0 -F" 2>/dev/null || true
  ( tail -n +0 -F /var/log/supervisor/*comfyui* /var/log/comfyui.manual.log 2>/dev/null || true ) >> "$MODEL_LOG_PATH" &
  export MODEL_LOG="$MODEL_LOG_PATH"
  echo "export MODEL_LOG=$MODEL_LOG_PATH" >/etc/profile.d/model_log.sh; chmod 644 /etc/profile.d/model_log.sh || true
  sleep 1
  log "[INFO] checking 'To see the GUI go to:' in MODEL_LOG"
  grep -F "To see the GUI go to:" -n "$MODEL_LOG_PATH" | tail -n 3 || log "[WARN] not found yet — will appear after UI start"
}

start_wrapper_shim(){
  if (ss -ltnp 2>/dev/null || netstat -tulpn 2>/dev/null) | grep -qE ':18288\b'; then log "Wrapper shim: port 18288 already in use, skipping"; return 0; fi
  cat >/usr/local/bin/comfyui_wrapper_shim.py <<'PY'
#!/usr/bin/env python3
import json, time
from http.server import BaseHTTPRequestHandler, HTTPServer
import requests
COMFY = "http://127.0.0.1:18188"
class Handler(BaseHTTPRequestHandler):
    def _send(self, code=200, obj=None):
        self.send_response(code); self.send_header("Content-Type","application/json"); self.end_headers()
        if obj is None: obj={"status":"success"}
        try: self.wfile.write(json.dumps(obj).encode("utf-8"))
        except BrokenPipeError: pass
    def log_message(self, fmt, *args): return
    def do_GET(self):
        if self.path=="/health": self._send(200,{"ok":True})
        else: self._send(404,{"error":"not found"})
    def do_POST(self):
        length=int(self.headers.get("Content-Length","0") or "0")
        raw=self.rfile.read(length) if length else b"{}"
        try: data=json.loads((raw or b"{}").decode("utf-8"))
        except Exception: data={}
        if self.path in ("/runsync","/run"):
            wf=(data.get("input") or {}).get("workflow_json")
            if wf:
                try:
                    r=requests.post(f"{COMFY}/prompt", json={"prompt":wf,"client_id":"pyworker-shim"}, timeout=300); r.raise_for_status()
                    pid=(r.json() or {}).get("prompt_id",""); t0=time.time()
                    while time.time()-t0<8 and pid:
                        h=requests.get(f"{COMFY}/history/{pid}", timeout=5)
                        if h.ok and h.text and h.text!="{}": break
                        time.sleep(1)
                except Exception: pass
            self._send(200,{"status":"success"})
        else: self._send(404,{"error":"not found"})
def main():
    srv=HTTPServer(("127.0.0.1",18288),Handler); print("shim listening on 127.0.0.1:18288 ->",COMFY,flush=True)
    try: srv.serve_forever()
    except KeyboardInterrupt: pass
if __name__=="__main__": main()
PY
  chmod +x /usr/local/bin/comfyui_wrapper_shim.py
  nohup /usr/local/bin/comfyui_wrapper_shim.py >/var/log/comfy_shim.log 2>&1 & disown || true
  sleep 1
  curl -fsS -m 3 http://127.0.0.1:18288/health >/dev/null && log "Wrapper shim is up on 18288" || log "WARN: wrapper shim health failed"
}

maybe_start_pyworker(){
  if [ "${START_PYWORKER:-1}" != "1" ]; then log "PyWorker start skipped (set START_PYWORKER=1 to enable)"; return 0; fi
  : "${BACKEND:=comfyui}"
  : "${WORKER_PORT:=3000}"
  : "${MODEL_LOG:=${MODEL_LOG_PATH:-/workspace/logtail.log}}"
  : "${USE_SSL:=false}"
  : "${UNSECURED:=false}"
  : "${INTERNAL_PORT:=18188}"
  : "${MODEL_SERVER_URL:=http://127.0.0.1:${INTERNAL_PORT}}"
  : "${REPORT_ADDR:=}"   # выключаем отчёты

  # если уже слушает — не стартуем второй раз
  if (ss -ltnp 2>/dev/null || netstat -tulpn 2>/dev/null) | grep -qE ":${WORKER_PORT}\b"; then
    log "PyWorker already listening on :${WORKER_PORT}, skipping"; return 0; fi

  local URL="${PYWORKER_START_URL:-https://raw.githubusercontent.com/bidzy-app/config_vast/main/start_server_udp29.sh}"
  log "Starting PyWorker via $URL"
  if curl -fsSL --retry 5 "$URL" -o /tmp/start_udp.sh; then
    chmod +x /tmp/start_udp.sh
    export BACKEND WORKER_PORT MODEL_LOG USE_SSL UNSECURED MODEL_SERVER_URL REPORT_ADDR
    local VAST_VAR; printf -v VAST_VAR "VAST_TCP_PORT_%s" "$WORKER_PORT"; export "$VAST_VAR"="$WORKER_PORT"
    {
      echo "== pyworker env =="; echo "BACKEND=$BACKEND"; echo "MODEL_SERVER_URL=$MODEL_SERVER_URL"; echo "WORKER_PORT=$WORKER_PORT"; echo "MODEL_LOG=$MODEL_LOG"; echo "$VAST_VAR=${!VAST_VAR}"
    } >> /var/log/onstart_udp28.log 2>&1 || true
    nohup /tmp/start_udp.sh >> /var/log/onstart_udp28.log 2>&1 & disown || true
  else
    log "WARN: failed to download ${URL##*/}; using local fallback"
    # локальный fallback — положим стартер сами
    cat >/usr/local/bin/start_server_udp29.sh <<'SH'
PLACEHOLDER_START_SERVER_UDP29
SH
    sed -n '1,$p' /usr/local/bin/start_server_udp29.sh >/dev/null 2>&1 || true
    chmod +x /usr/local/bin/start_server_udp29.sh
    nohup /usr/local/bin/start_server_udp29.sh >> /var/log/onstart_udp29.log 2>&1 & disown || true
  fi
}

fetch_and_run_provision(){
  # ваш CPU‑provisioner с Wan2.1 моделями
  local URL="${PROVISION_URL:-https://raw.githubusercontent.com/bidzy-app/config_vast/main/wan_talk_ver4.3.sh}"
  log "Running provision script: $URL"
  if curl -fsSL --retry 5 "$URL" -o /tmp/provision.sh; then
    bash /tmp/provision.sh >>/var/log/onstart_provision.log 2>&1 || log "WARN: provision returned non-zero"
  else
    log "ERROR: Failed to download provision script"
  fi
}

main(){
  ensure_tools; fix_all_symlinks
  log "Waiting for supervisor socket at $SUP_SOCK (up to ${WAIT_SUP_SECS}s)..."
  for i in $(seq 1 "$WAIT_SUP_SECS"); do [[ -S "$SUP_SOCK" ]] && break; (( i % 10 == 0 )) && log "Still waiting... ($i/${WAIT_SUP_SECS})"; sleep 1; done

  if [[ -S "$SUP_SOCK" ]]; then log "Supervisor is running; stop interfering services (wrapper/serverless)"; supervisorctl stop comfyui_rp_api serverless || true
  else log "Supervisor socket not found — will use manual ComfyUI start later"; fi

  fetch_and_run_provision

  if [[ -S "$SUP_SOCK" ]]; then start_comfy_supervisor; else start_comfy_manual "$DEFAULT_COMFY_PORT"; fi

  log "Waiting for ComfyUI readiness (18188/8188, timeout=${WAIT_COMFY_READY_SECS}s)..."
  INTERNAL_PORT="$(wait_comfy_ready_pick_port "$WAIT_COMFY_READY_SECS" || true)"
  if [ -z "$INTERNAL_PORT" ]; then log "ERROR: ComfyUI didn't become ready"; print_listeners; exit 1; fi
  log "ComfyUI is ready on 127.0.0.1:${INTERNAL_PORT}"

  ensure_iface_proxy 18188 "$INTERNAL_PORT"
  ensure_iface_proxy 8188  "$INTERNAL_PORT"

  start_wrapper_shim
  setup_logtail
  print_listeners
  maybe_start_pyworker
  log "Bootstrap finished successfully"
}
main "$@"