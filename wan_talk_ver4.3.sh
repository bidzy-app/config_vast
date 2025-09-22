#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[provision] ERROR on line $LINENO" >&2' ERR
umask 022

log(){ echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }

RUN_USER="$(awk -F= '/^\s*user=/{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' /etc/supervisor/conf.d/comfyui.conf 2>/dev/null || true)"
[ -z "$RUN_USER" ] && RUN_USER="$(id -un 1000 2>/dev/null || echo root)"
RUN_GROUP="$(id -gn "$RUN_USER" 2>/dev/null || echo "$RUN_USER")"

ensure_paths(){
  BASE_DIR="${WORKSPACE_DIR:-${WORKSPACE:-/workspace}}"
  mkdir -p "$BASE_DIR"; chmod 755 "$BASE_DIR" || true; chown "$RUN_USER":"$RUN_GROUP" "$BASE_DIR" || true
  LINK_PATH="/opt/ComfyUI"
  if [ -L "$LINK_PATH" ] || { [ -e "$LINK_PATH" ] && [ ! -d "$LINK_PATH" ]; }; then rm -f "$LINK_PATH"; fi
  mkdir -p "$LINK_PATH"; chown -R "$RUN_USER":"$RUN_GROUP" "$LINK_PATH" || true; chmod -R u+rwX,g+rX "$LINK_PATH" || true
  COMFY_ROOT="$LINK_PATH"
}
ensure_paths

PROVISION_LOG="$COMFY_ROOT/provisioning.log"
mkdir -p "$COMFY_ROOT"; exec > >(tee -a "$PROVISION_LOG") 2>&1

HF_TOKEN="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-${HUGGINGFACEHUB_API_TOKEN:-}}}"
[ -z "$HF_TOKEN" ] && log "HF_TOKEN is not set. Continuing without authentication."

# Модели WAN 2.1 — дефолты (можно переопределить переменными *_URL_1, *_URL_2 и т.п.)
DIFFUSION_MODELS_DEFAULT=(
  "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/InfiniteTalk/Wan2_1-InfiniTetalk-Single_fp16.safetensors?download=true"
  "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1-I2V-14B-480P_fp8_e4m3fn.safetensors"
)
VAE_MODELS_DEFAULT=("https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1_VAE_bf16.safetensors")
TEXT_ENCODERS_DEFAULT=("https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/umt5-xxl-enc-fp8_e4m3fn.safetensors")
CLIP_VISION_MODELS_DEFAULT=("https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors")
LORA_MODELS_DEFAULT=("https://huggingface.co/lightx2v/Wan2.1-I2V-14B-480P-StepDistill-CfgDistill-Lightx2v/resolve/main/loras/Wan21_I2V_14B_lightx2v_cfg_step_distill_lora_rank64.safetensors")

# Соберём массивы из env (если заданы) или возьмём дефолты
collect_urls(){
  local prefix="$1" ; shift
  local -n out_arr="$1" ; shift
  local -a defaults=( "$@" )
  local i=1 val
  out_arr=()
  while true; do
    val="$(eval echo "\${${prefix}_URL_${i}:-}")"
    [ -z "$val" ] && break
    out_arr+=("$val"); i=$((i+1))
  done
  [ ${#out_arr[@]} -eq 0 ] && out_arr=( "${defaults[@]}" )
}

declare -a DIFFUSION_MODELS VAE_MODELS TEXT_ENCODERS CLIP_VISION_MODELS LORA_MODELS
collect_urls DIFFUSION DIFFUSION_MODELS "${DIFFUSION_MODELS_DEFAULT[@]}"
collect_urls VAE VAE_MODELS "${VAE_MODELS_DEFAULT[@]}"
collect_urls TEXT_ENCODERS TEXT_ENCODERS "${TEXT_ENCODERS_DEFAULT[@]}"
collect_urls CLIP_VISION CLIP_VISION_MODELS "${CLIP_VISION_MODELS_DEFAULT[@]}"
collect_urls LORA LORA_MODELS "${LORA_MODELS_DEFAULT[@]}"

CUSTOM_NODES=(
  "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite"
  "https://github.com/christian-byrne/audio-separation-nodes-comfyui"
  "https://github.com/kijai/ComfyUI-WanVideoWrapper"
  "https://github.com/kijai/ComfyUI-KJNodes.git"
)

create_directories(){
  mkdir -p \
    "$COMFY_ROOT/models/checkpoints" \
    "$COMFY_ROOT/models/diffusion_models" \
    "$COMFY_ROOT/models/vae" \
    "$COMFY_ROOT/models/text_encoders" \
    "$COMFY_ROOT/models/clip_vision" \
    "$COMFY_ROOT/models/loras" \
    "$COMFY_ROOT/custom_nodes" \
    "$COMFY_ROOT/input" \
    "$COMFY_ROOT/output"
  chown -R "$RUN_USER":"$RUN_GROUP" "$COMFY_ROOT" || true
  chmod -R u+rwX,g+rX "$COMFY_ROOT" || true
}

provisioning_download(){
  local url="$1" dest="$2" bn
  mkdir -p "$dest"; chown "$RUN_USER":"$RUN_GROUP" "$dest" || true
  log "Starting download: $url -> $dest"
  bn="$(basename "${url%%\?*}")"
  # при наличии токена добавим заголовок
  if [ -n "$HF_TOKEN" ]; then
    curl -fL --retry 3 --retry-delay 2 -H "Authorization: Bearer $HF_TOKEN" -o "$dest/$bn" "$url" \
      || wget --header="Authorization: Bearer $HF_TOKEN" -nc --content-disposition -P "$dest" "$url"
  else
    curl -fL --retry 3 --retry-delay 2 -o "$dest/$bn" "$url" \
      || wget -nc --content-disposition -P "$dest" "$url"
  fi
}

update_comfyui(){
  if [ -d "$COMFY_ROOT/.git" ]; then
    log "Updating ComfyUI..."
    (cd "$COMFY_ROOT" && git fetch --all && git reset --hard origin/master && git submodule update --init --recursive) || log "WARN: update failed"
  else
    log "Cloning ComfyUI..."
    rm -rf "$COMFY_ROOT"
    git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFY_ROOT" --depth 1
    (cd "$COMFY_ROOT" && git submodule update --init --recursive || true)
  fi
  chown -R "$RUN_USER":"$RUN_GROUP" "$COMFY_ROOT" || true
  chmod -R u+rwX,g+rX "$COMFY_ROOT" || true
}

install_comfyui_requirements(){
  local PY="/opt/micromamba/envs/comfyui/bin/python"
  log "Installing ComfyUI requirements..."
  "$PY" -s -m pip install --upgrade pip setuptools wheel
  "$PY" -s -m pip install -r "$COMFY_ROOT/requirements.txt"
}

clone_custom_nodes(){
  mkdir -p "$COMFY_ROOT/custom_nodes"; chown "$RUN_USER":"$RUN_GROUP" "$COMFY_ROOT/custom_nodes" || true
  cd "$COMFY_ROOT/custom_nodes"
  for repo in "${CUSTOM_NODES[@]}"; do
    dir="${repo##*/}"; dir="${dir%.git}"
    if [ ! -d "$dir" ]; then
      log "Cloning: $repo"
      git clone "$repo" "$dir" --depth 1 || git clone "$repo" "$dir"
    else
      log "Node already exists: $dir — pulling updates"
      (cd "$dir" && git pull --ff-only || true)
    fi
    chown -R "$RUN_USER":"$RUN_GROUP" "$dir" || true
  done
}

install_python_packages(){
  local PIP="/opt/micromamba/envs/comfyui/bin/pip"
  log "Installing extra Python packages for Wan..."
  $PIP install --upgrade --no-cache-dir \
    packaging librosa "numpy==1.26.4" moviepy "pillow>=10.3.0" scipy \
    color-matcher matplotlib huggingface_hub mss opencv-python ftfy \
    "accelerate>=1.2.1" einops "diffusers>=0.33.0" "peft>=0.17.0" \
    "sentencepiece>=0.2.0" protobuf pyloudnorm "gguf>=0.14.0" imageio-ffmpeg \
    av comfy-cli sageattention
}

provision(){
  create_directories
  update_comfyui
  install_comfyui_requirements
  clone_custom_nodes
  install_python_packages

  for url in "${DIFFUSION_MODELS[@]}"; do provisioning_download "$url" "$COMFY_ROOT/models/diffusion_models"; done
  for url in "${VAE_MODELS[@]}"; do provisioning_download "$url" "$COMFY_ROOT/models/vae"; done
  for url in "${TEXT_ENCODERS[@]}"; do provisioning_download "$url" "$COMFY_ROOT/models/text_encoders"; done
  for url in "${CLIP_VISION_MODELS[@]}"; do provisioning_download "$url" "$COMFY_ROOT/models/clip_vision"; done
  for url in "${LORA_MODELS[@]}"; do provisioning_download "$url" "$COMFY_ROOT/models/loras"; done

  log "Downloads summary:"
  find "$COMFY_ROOT/models" -maxdepth 2 -type f -printf "%p\n" | sed 's#^# - #'

  echo; echo "Provisioning complete: Web UI/worker will start now (GPU stage)"; echo
  log "Provisioning log saved to: $PROVISION_LOG"
}
provision