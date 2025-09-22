#!/usr/bin/env bash
# start_server_udp26.sh — обновлено: прямой comfyui-бэкенд на 18188, единый MODEL_LOG
set -Eeuo pipefail
trap 'echo "[start_server_udp26] ERROR on line $LINENO" >&2; exit 1' ERR

BASE_DIR="${WORKSPACE_DIR:-${WORKSPACE:-/workspace}}"
WORKSPACE_DIR="$BASE_DIR"
SERVER_DIR="${SERVER_DIR:-$WORKSPACE_DIR/vast-pyworker}"
ENV_PATH="${ENV_PATH:-$WORKSPACE_DIR/worker-env}"
DEBUG_LOG="${DEBUG_LOG:-$WORKSPACE_DIR/debug.log}"
PYWORKER_LOG="${PYWORKER_LOG:-$WORKSPACE_DIR/pyworker.log}"

REPORT_ADDR="${REPORT_ADDR:-https://cloud.vast.ai/api/v0,https://run.vast.ai}"
USE_SSL="${USE_SSL:-false}"
WORKER_PORT="${WORKER_PORT:-3000}"
MODEL_SERVER_URL="${MODEL_SERVER_URL:-http://127.0.0.1:18188}"

mkdir -p "$WORKSPACE_DIR"
cd "$WORKSPACE_DIR"

# Подготовим переменные
: "${BACKEND:=comfyui}"
: "${MODEL_LOG:=/workspace/logtail.log}"
if [ "$BACKEND" = "comfyui" ] && [ -z "${COMFY_MODEL:-}" ]; then
  export COMFY_MODEL="wan_talk_ver4.2"  # значение по умолчанию
fi

# Экспорт WAN-порта, чтобы оркестратор его «видел»
printf -v VAST_VAR "VAST_TCP_PORT_%s" "$WORKER_PORT"
export "$VAST_VAR"="$WORKER_PORT"
export UNSECURED="${UNSECURED:-false}"

exec &> >(tee -a "$DEBUG_LOG")

echo "start_server_udp26.sh"; date
echo "BACKEND=$BACKEND"
echo "MODEL_SERVER_URL=$MODEL_SERVER_URL"
echo "WORKER_PORT=$WORKER_PORT"
echo "MODEL_LOG=$MODEL_LOG"
echo "SERVER_DIR=$SERVER_DIR"
echo "ENV_PATH=$ENV_PATH"

# Проверим доступность ComfyUI, чтобы не падать впустую
if ! curl -fsS -m 5 "$MODEL_SERVER_URL/system_stats" >/dev/null; then
  echo "[WARN] $MODEL_SERVER_URL/system_stats не отвечает — PyWorker всё равно стартуем, но это может помешать ModelLoaded"
fi

# Установщик uv (fallback на venv+pip)
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
      # shellcheck source=/dev/null
      source "$ENV_PATH/bin/activate"
      uv pip install -r "${SERVER_DIR}/requirements.txt"
    else
      python3 -m venv "$ENV_PATH"
      # shellcheck source=/dev/null
      source "$ENV_PATH/bin/activate"
      pip install --upgrade pip
      pip install -r "${SERVER_DIR}/requirements.txt"
    fi
    touch ~/.no_auto_tmux || true
  else
    [ -f "$HOME/.local/bin/env" ] && source "$HOME/.local/bin/env" || true
    # shellcheck source=/dev/null
    source "$ENV_PATH/bin/activate"
    echo "environment activated: $VIRTUAL_ENV"
  fi
}

ensure_repo_and_env

[ ! -d "$SERVER_DIR/workers/$BACKEND" ] && echo "$BACKEND not supported!" && exit 1

# Единый лог с ComfyUI — сбросим, чтобы PyWorker поймал свежий 'To see the GUI go to:'
if [ -e "$MODEL_LOG" ]; then
  cat "$MODEL_LOG" >> "$MODEL_LOG.old" || true
  : > "$MODEL_LOG" || true
fi

export REPORT_ADDR WORKER_PORT USE_SSL UNSECURED MODEL_LOG MODEL_SERVER_URL COMFY_MODEL
cd "$SERVER_DIR"

echo "launching PyWorker server (workers.$BACKEND.server)"
python3 -m "workers.$BACKEND.server" |& tee -a "$PYWORKER_LOG"
echo "launching PyWorker server done"