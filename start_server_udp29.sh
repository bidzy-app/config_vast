#!/usr/bin/env bash
# start_server_udp29.sh — comfyui-бэкенд, единый MODEL_LOG, Wan‑friendly bench
set -Eeuo pipefail
trap 'echo "[start_server_udp29] ERROR on line $LINENO" >&2; exit 1' ERR

BASE_DIR="${WORKSPACE_DIR:-${WORKSPACE:-/workspace}}"
WORKSPACE_DIR="$BASE_DIR"
SERVER_DIR="${SERVER_DIR:-$WORKSPACE_DIR/vast-pyworker}"
ENV_PATH="${ENV_PATH:-$WORKSPACE_DIR/worker-env}"
DEBUG_LOG="${DEBUG_LOG:-$WORKSPACE_DIR/debug.log}"
PYWORKER_LOG="${PYWORKER_LOG:-$WORKSPACE_DIR/pyworker.log}"

REPORT_ADDR="${REPORT_ADDR:-}"        # пусто = не репортим в autoscaler
USE_SSL="${USE_SSL:-false}"
UNSECURED="${UNSECURED:-false}"
WORKER_PORT="${WORKER_PORT:-3000}"
MODEL_SERVER_URL="${MODEL_SERVER_URL:-http://127.0.0.1:18188}"

mkdir -p "$WORKSPACE_DIR"; cd "$WORKSPACE_DIR"

: "${BACKEND:=comfyui}"
: "${MODEL_LOG:=/workspace/logtail.log}"
: "${COMFY_MODEL:=wan_talk_ver4.3}"   # логическое имя для бенча

# Экспорт WAN-порта (для оркестратора)
printf -v VAST_VAR "VAST_TCP_PORT_%s" "$WORKER_PORT"; export "$VAST_VAR"="$WORKER_PORT"

exec &> >(tee -a "$DEBUG_LOG")

echo "start_server_udp29.sh"; date
echo "BACKEND=$BACKEND"
echo "MODEL_SERVER_URL=$MODEL_SERVER_URL"
echo "WORKER_PORT=$WORKER_PORT"
echo "MODEL_LOG=$MODEL_LOG"
echo "SERVER_DIR=$SERVER_DIR"
echo "ENV_PATH=$ENV_PATH"
echo "COMFY_MODEL=$COMFY_MODEL"

if ! curl -fsS -m 5 "$MODEL_SERVER_URL/system_stats" >/dev/null; then
  echo "[WARN] $MODEL_SERVER_URL/system_stats не отвечает — стартуем всё равно"
fi

ensure_uv(){
  if command -v uv >/dev/null 2>&1; then return 0; fi
  curl -LsSf https://astral.sh/uv/install.sh | sh
  [ -f "$HOME/.local/bin/env" ] && source "$HOME/.local/bin/env" || true
  export PATH="$HOME/.local/bin:$PATH"
}

ensure_repo_and_env(){
  if [ ! -d "$SERVER_DIR" ]; then
    git clone "${PYWORKER_REPO:-https://github.com/vast-ai/pyworker}" "$SERVER_DIR"
  fi
  if [ -n "${PYWORKER_REF:-}" ]; then
    ( cd "$SERVER_DIR" && git fetch --all && git checkout "$PYWORKER_REF" && git reset --hard "origin/${PYWORKER_REF}" ) || true
  fi
  if [ ! -d "$ENV_PATH" ]; then
    echo "setting up venv at $ENV_PATH"
    if ensure_uv; then
      uv venv --python-preference only-managed "$ENV_PATH" -p 3.10
      source "$ENV_PATH/bin/activate"
      uv pip install -r "${SERVER_DIR}/requirements.txt"
    else
      python3 -m venv "$ENV_PATH"; source "$ENV_PATH/bin/activate"
      pip install --upgrade pip; pip install -r "${SERVER_DIR}/requirements.txt"
    fi
    touch ~/.no_auto_tmux || true
  else
    [ -f "$HOME/.local/bin/env" ] && source "$HOME/.local/bin/env" || true
    source "$ENV_PATH/bin/activate"
    echo "environment activated: $VIRTUAL_ENV"
  fi
}
ensure_repo_and_env

[ ! -d "$SERVER_DIR/workers/$BACKEND" ] && echo "$BACKEND not supported!" && exit 1

# Подготовим безопасный дефолтный workflow под названием wan_talk_ver4.3 (без моделей)
WF_DIR="$SERVER_DIR/workers/comfyui/misc/default_workflows"
mkdir -p "$WF_DIR"
if [ ! -f "$WF_DIR/wan_talk_ver4.3.json" ]; then
  cat >"$WF_DIR/wan_talk_ver4.3.json" <<'JSON'
{
  "3": { "class_type": "LoadImage", "_meta": {"title": "Load Image"}, "inputs": {"image": "example.png"} },
  "4": { "class_type": "SaveImage", "_meta": {"title": "Save Image"}, "inputs": {"images": ["3", 0]} }
}
JSON
fi

# Если COMFY_MODEL указан, но файла нет — принудительно используем наш безопасный
if [ ! -f "$WF_DIR/${COMFY_MODEL}.json" ]; then
  echo "[INFO] COMFY_MODEL '${COMFY_MODEL}' not found in $WF_DIR, switching to wan_talk_ver4.3"
  COMFY_MODEL="wan_talk_ver4.3"
fi
echo "[INFO] COMFY_MODEL selected: $COMFY_MODEL"

# Сбросим MODEL_LOG, чтобы PyWorker поймал свежие строки
if [ -e "$MODEL_LOG" ]; then cat "$MODEL_LOG" >> "$MODEL_LOG.old" || true; : > "$MODEL_LOG" || true; fi

export REPORT_ADDR WORKER_PORT USE_SSL UNSECURED MODEL_LOG MODEL_SERVER_URL COMFY_MODEL
cd "$SERVER_DIR"

echo "launching PyWorker server (workers.$BACKEND.server)"
python3 -m "workers.$BACKEND.server" |& tee -a "$PYWORKER_LOG"
echo "launching PyWorker server done"