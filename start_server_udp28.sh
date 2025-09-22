#!/usr/bin/env bash
# start_server_udp27.sh — прямой comfyui-бэкенд на 18188, единый MODEL_LOG, автоподбор COMFY_MODEL
set -Eeuo pipefail
trap 'echo "[start_server_udp27] ERROR on line $LINENO" >&2; exit 1' ERR

BASE_DIR="${WORKSPACE_DIR:-${WORKSPACE:-/workspace}}"
WORKSPACE_DIR="$BASE_DIR"
SERVER_DIR="${SERVER_DIR:-$WORKSPACE_DIR/vast-pyworker}"
ENV_PATH="${ENV_PATH:-$WORKSPACE_DIR/worker-env}"
DEBUG_LOG="${DEBUG_LOG:-$WORKSPACE_DIR/debug.log}"
PYWORKER_LOG="${PYWORKER_LOG:-$WORKSPACE_DIR/pyworker.log}"

REPORT_ADDR="${REPORT_ADDR:-http://127.0.0.1}"
USE_SSL="${USE_SSL:-false}"
WORKER_PORT="${WORKER_PORT:-3000}"
MODEL_SERVER_URL="${MODEL_SERVER_URL:-http://127.0.0.1:18188}"

mkdir -p "$WORKSPACE_DIR"
cd "$WORKSPACE_DIR"

: "${BACKEND:=comfyui}"
: "${MODEL_LOG:=/workspace/logtail.log}"

# Экспорт WAN-порта, чтобы оркестратор его «видел»
printf -v VAST_VAR "VAST_TCP_PORT_%s" "$WORKER_PORT"
export "$VAST_VAR"="$WORKER_PORT"
export UNSECURED="${UNSECURED:-false}"

exec &> >(tee -a "$DEBUG_LOG")

echo "start_server_udp27.sh"; date
echo "BACKEND=$BACKEND"
echo "MODEL_SERVER_URL=$MODEL_SERVER_URL"
echo "WORKER_PORT=$WORKER_PORT"
echo "MODEL_LOG=$MODEL_LOG"
echo "SERVER_DIR=$SERVER_DIR"
echo "ENV_PATH=$ENV_PATH"

if ! curl -fsS -m 5 "$MODEL_SERVER_URL/system_stats" >/dev/null; then
  echo "[WARN] $MODEL_SERVER_URL/system_stats не отвечает — PyWorker всё равно стартуем, но это может помешать ModelLoaded"
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

# Автоподбор COMFY_MODEL, если не задан или задан неверно
if [ "$BACKEND" = "comfyui" ]; then
  WF_DIR="$SERVER_DIR/workers/comfyui/misc/default_workflows"
  if [ -z "${COMFY_MODEL:-}" ] || [ ! -f "$WF_DIR/${COMFY_MODEL}.json" ]; then
    mapfile -t WF_LIST < <(ls -1 "$WF_DIR"/*.json 2>/dev/null | xargs -I{} basename "{}" .json || true)
    if [ ${#WF_LIST[@]} -gt 0 ]; then
      PICK=""
      for n in "${WF_LIST[@]}"; do
        [[ -z "$PICK" && "$n" =~ [Ff][Ll][Uu][Xx] ]] && PICK="$n"
      done
      if [ -z "$PICK" ]; then
        for n in "${WF_LIST[@]}"; do
          [[ -z "$PICK" && "$n" =~ [Ss][Dd][Xx][Ll] ]] && PICK="$n"
        done
      fi
      [ -z "$PICK" ] && PICK="${WF_LIST[0]}"
      export COMFY_MODEL="$PICK"
      echo "[INFO] COMFY_MODEL auto-selected: $COMFY_MODEL"
    else
      echo "[WARN] No default workflows in $WF_DIR — continuing without COMFY_MODEL"
    fi
  else
    echo "[INFO] COMFY_MODEL preset: $COMFY_MODEL"
  fi
fi

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