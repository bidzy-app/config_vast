#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "[start_server_udp25] ERROR on line $LINENO"; exit 1' ERR

BASE_DIR="${WORKSPACE_DIR:-${WORKSPACE:-/workspace}}"
WORKSPACE_DIR="$BASE_DIR"
SERVER_DIR="$WORKSPACE_DIR/vast-pyworker"
ENV_PATH="$WORKSPACE_DIR/worker-env"
DEBUG_LOG="$WORKSPACE_DIR/debug.log"
PYWORKER_LOG="$WORKSPACE_DIR/pyworker.log"

REPORT_ADDR="${REPORT_ADDR:-https://cloud.vast.ai/api/v0,https://run.vast.ai}"
USE_SSL="${USE_SSL:-false}"
WORKER_PORT="${WORKER_PORT:-3000}"
INTERNAL_PORT="${INTERNAL_PORT:-18188}"

mkdir -p "$WORKSPACE_DIR"
cd "$WORKSPACE_DIR"

printf -v VAST_VAR "VAST_TCP_PORT_%s" "$WORKER_PORT"
export "$VAST_VAR"="$WORKER_PORT"
export UNSECURED=false

exec &> >(tee -a "$DEBUG_LOG")

echo "start_server_udp25.sh"; date

echo_var() { echo "$1: ${!1}"; }
for v in BACKEND REPORT_ADDR WORKER_PORT INTERNAL_PORT WORKSPACE_DIR SERVER_DIR ENV_PATH DEBUG_LOG PYWORKER_LOG MODEL_LOG USE_SSL; do
    echo_var "$v" || true
done

[ -z "${BACKEND:-}" ] && echo "BACKEND must be set!" && exit 1
[ -z "${MODEL_LOG:-}" ] && echo "MODEL_LOG must be set!" && exit 1
if [ "$BACKEND" = "comfyui" ] && [ -z "${COMFY_MODEL:-}" ]; then
    echo "For comfyui backend, COMFY_MODEL must be set!" && exit 1
fi

if ! command -v uv >/dev/null 2>&1; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
    [ -f "$HOME/.local/bin/env" ] && source "$HOME/.local/bin/env" || true
    export PATH="$HOME/.local/bin:$PATH"
fi

if [ ! -d "$SERVER_DIR" ]; then
    git clone "${PYWORKER_REPO:-https://github.com/vast-ai/pyworker}" "$SERVER_DIR"
fi

if [ -n "${PYWORKER_REF:-}" ]; then
    (
        cd "$SERVER_DIR" && git fetch --all && git checkout "$PYWORKER_REF" && git reset --hard "origin/${PYWORKER_REF}" || true
    )
fi

if [ ! -d "$ENV_PATH" ]; then
    echo "setting up venv at $ENV_PATH"
    uv venv --python-preference only-managed "$ENV_PATH" -p 3.10
    source "$ENV_PATH/bin/activate"
    uv pip install -r "${SERVER_DIR}/requirements.txt"
    touch ~/.no_auto_tmux
else
    [ -f "$HOME/.local/bin/env" ] && source "$HOME/.local/bin/env" || true
    source "$ENV_PATH/bin/activate"
    echo "environment activated: $VIRTUAL_ENV"
fi

[ ! -d "$SERVER_DIR/workers/$BACKEND" ] && echo "$BACKEND not supported!" && exit 1

export REPORT_ADDR WORKER_PORT USE_SSL UNSECURED
cd "$SERVER_DIR"

echo "launching PyWorker server"
[ -e "$MODEL_LOG" ] && cat "$MODEL_LOG" >> "$MODEL_LOG.old" && : > "$MODEL_LOG"
python3 -m "workers.$BACKEND.server" |& tee -a "$PYWORKER_LOG"
echo "launching PyWorker server done"