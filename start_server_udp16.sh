#!/bin/bash
set -e -o pipefail

# Директории по умолчанию
WORKSPACE_DIR="${WORKSPACE_DIR:-/opt}"
SERVER_DIR="$WORKSPACE_DIR/vast-pyworker"
ENV_PATH="$WORKSPACE_DIR/worker-env"
DEBUG_LOG="$WORKSPACE_DIR/debug.log"
PYWORKER_LOG="$WORKSPACE_DIR/pyworker.log"
REPORT_ADDR="${REPORT_ADDR:-https://cloud.vast.ai/api/v0,https://run.vast.ai}"
USE_SSL="${USE_SSL:-false}"   # default to false
WORKER_PORT="${WORKER_PORT:-3000}"
INTERNAL_PORT="${INTERNAL_PORT:-18188}"

mkdir -p "$WORKSPACE_DIR"
cd "$WORKSPACE_DIR"

# проброс внешнего TCP-порта
export VAST_TCP_PORT_${WORKER_PORT}=${INTERNAL_PORT}
export UNSECURED=false

exec &> >(tee -a "$DEBUG_LOG")

echo_var(){ echo "$1: ${!1}"; }

[ -z "$BACKEND" ] && echo "BACKEND must be set!" && exit 1
[ -z "$MODEL_LOG" ] && echo "MODEL_LOG must be set!" && exit 1
[ -z "$HF_TOKEN" ] && echo "HF_TOKEN must be set!" && exit 1
[ "$BACKEND" = "comfyui" ] && [ -z "$COMFY_MODEL" ] && echo "For comfyui backends, COMFY_MODEL must be set!" && exit 1

echo "start_server_udp15.sh"; date
for v in BACKEND REPORT_ADDR WORKER_PORT WORKSPACE_DIR SERVER_DIR ENV_PATH DEBUG_LOG PYWORKER_LOG MODEL_LOG; do echo_var "$v"; done

# setup environment
if [ ! -d "$ENV_PATH" ]; then
  echo "setting up venv"
  if ! which uv >/dev/null 2>&1; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
    [ -f ~/.local/bin/env ] && source ~/.local/bin/env || true
    export PATH="$HOME/.local/bin:$PATH"
  fi
  [[ ! -d $SERVER_DIR ]] && git clone "${PYWORKER_REPO:-https://github.com/vast-ai/pyworker}" "$SERVER_DIR"
  if [[ -n ${PYWORKER_REF:-} ]]; then (cd "$SERVER_DIR" && git checkout "$PYWORKER_REF"); fi
  uv venv --python-preference only-managed "$ENV_PATH" -p 3.10
  source "$ENV_PATH/bin/activate"
  uv pip install -r "${SERVER_DIR}/requirements.txt"
  touch ~/.no_auto_tmux
else
  [[ -f ~/.local/bin/env ]] && source ~/.local/bin/env || true
  source "$ENV_PATH/bin/activate"
  echo "environment activated"
  echo "venv: $VIRTUAL_ENV"
fi

[ ! -d "$SERVER_DIR/workers/$BACKEND" ] && echo "$BACKEND not supported!" && exit 1

export REPORT_ADDR WORKER_PORT USE_SSL UNSECURED
cd "$SERVER_DIR"

echo "launching PyWorker server"
[ -e "$MODEL_LOG" ] && cat "$MODEL_LOG" >> "$MODEL_LOG.old" && : > "$MODEL_LOG"
python3 -m "workers.$BACKEND.server" |& tee -a "$PYWORKER_LOG"
echo "launching PyWorker server done"