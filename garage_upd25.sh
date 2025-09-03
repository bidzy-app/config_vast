#!/bin/bash
set -e

# Централизованный лог провижининга
COMFY_ROOT="${COMFY_ROOT:-/opt/ComfyUI}"
PROVISION_LOG="$COMFY_ROOT/provisioning.log"

mkdir -p "$COMFY_ROOT"
exec > >(tee -a "$PROVISION_LOG") 2>&1

# Принимаем несколько имен переменных для токена
HF_TOKEN="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-${HUGGINGFACEHUB_API_TOKEN:-}}}"
if [ -z "${HF_TOKEN}" ]; then
echo "HF_TOKEN is not set. Continuing without authentication (public files only)."
else
echo "HF_TOKEN detected; will be used if anonymous download fails."
fi

# Кастомные ноды (пример)
CUSTOM_NODES=(
  "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite"
  "https://github.com/christian-byrne/audio-separation-nodes-comfyui"
  "https://github.com/kijai/ComfyUI-WanVideoWrapper"
  "https://github.com/kijai/ComfyUI-KJNodes.git"

)

# Модели
DIFFUSION_MODELS=(
  "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/InfiniteTalk/Wan2_1-InfiniTetalk-Single_fp16.safetensors"
  "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1-I2V-14B-480P_fp8_e4m3fn.safetensors"
)

VAE_MODELS=(
  "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1_VAE_bf16.safetensors"
)

TEXT_ENCODERS=(
  "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/umt5-xxl-enc-fp8_e4m3fn.safetensors"
)

CLIP_VISION_MODELS=(
  "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors"
)

LORA_MODELS=(
  "https://huggingface.co/lightx2v/Wan2.1-I2V-14B-480P-StepDistill-CfgDistill-Lightx2v/resolve/main/loras/Wan21_I2V_14B_lightx2v_cfg_step_distill_lora_rank64.safetensors"
)

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

provisioning_print_header() {
  printf "\n##############################################\n#      Provisioning container (CPU stage)     #\n##############################################\n\n"
}

provisioning_print_end() {
  printf "\nProvisioning complete: Web UI/worker will start now (GPU stage)\n\n"
}

create_directories() {
  mkdir -p \
    "$COMFY_ROOT/models/checkpoints" \
    "$COMFY_ROOT/models/vae" \
    "$COMFY_ROOT/models/text_encoders" \
    "$COMFY_ROOT/models/clip_vision" \
    "$COMFY_ROOT/models/loras" \
    "$COMFY_ROOT/custom_nodes"
}

provisioning_download() {
    local url="$1"
    local dest="$2"

    mkdir -p "$dest"
    log "Starting download: $url -> $dest"

    # Сначала пробуем анонимно
    if wget -nc --content-disposition --show-progress -P "$dest" "$url"; then
        log "Finished download (anon): $url"
        return 0
    fi

    # Если есть токен — пробуем с ним
    if [ -n "$HF_TOKEN" ]; then
        log "Retrying with token: $url"
        wget --header="Authorization: Bearer $HF_TOKEN" \
             -nc --content-disposition --show-progress -P "$dest" "$url"
        local rc=$?
        if [ $rc -ne 0 ]; then
            log "ERROR: download failed with token: $url (exit $rc)"
            return $rc
        fi
        log "Finished download (token): $url"
        return 0
    fi

    log "ERROR: download failed (anon) and no token available: $url"
    return 1
}


clone_custom_nodes() {
  mkdir -p "$COMFY_ROOT/custom_nodes"
  cd "$COMFY_ROOT/custom_nodes"
  for repo in "${CUSTOM_NODES[@]}"; do
    dir="${repo##*/}"; dir="${dir%.git}"
    if [ ! -d "$dir" ]; then
      log "Cloning: $repo"
      git clone "$repo" "$dir" --depth 1 2>&1 | tee -a "$PROVISION_LOG" || \
      git clone "$repo" "$dir" 2>&1 | tee -a "$PROVISION_LOG"
    else
      log "Node already exists: $dir — pulling updates"
      (cd "$dir" && git pull --ff-only 2>&1 | tee -a "$PROVISION_LOG" || true)
    fi

    # Проверка и установка requirements.txt, если он есть
    if [ -f "$dir/requirements.txt" ]; then
      log "Installing Python packages from $dir/requirements.txt"
      /opt/micromamba/envs/comfyui/bin/pip install --upgrade -r "$dir/requirements.txt"
    fi
  done
}

install_python_packages() {
  local PIP="/opt/micromamba/envs/comfyui/bin/pip"
  echo "[INFO] Installing additional Python packages (pip)..."
  "$PIP" install --upgrade --no-cache-dir \
    "numpy<2,>=1.26.4" \
    "opencv-python-headless==4.7.0.72" \
    diffusers \
    librosa \
    GitPython \
    "imageio[ffmpeg]" \
    imageio-ffmpeg \
    soundfile \
    av \
    "moviepy<2" \
    toml
}

verify_installations() {
  echo "[INFO] Verifying installations..."
  local PY="/opt/micromamba/envs/comfyui/bin/python"
  "$PY" - << 'PYEOF'
import numpy, diffusers, librosa, git, cv2, av, moviepy, toml
v = numpy.__version__
assert v.startswith('1.'), f'Incorrect NumPy version: {v}'
print('OK NumPy:', v)
print('OK diffusers, librosa, GitPython, cv2, av, moviepy, toml')
PYEOF
  echo "[INFO] All package verifications passed!"
}

provisioning_start() {
  provisioning_print_header
  create_directories
  clone_custom_nodes
  install_python_packages
  verify_installations
  # CORRECTED LINE BELOW
  for url in "${DIFFUSION_MODELS[@]}"; do provisioning_download "$url" "$COMFY_ROOT/models/checkpoints"; done
  for url in "${VAE_MODELS[@]}"; do provisioning_download "$url" "$COMFY_ROOT/models/vae"; done
  for url in "${TEXT_ENCODERS[@]}"; do provisioning_download "$url" "$COMFY_ROOT/models/text_encoders"; done
  for url in "${CLIP_VISION_MODELS[@]}"; do provisioning_download "$url" "$COMFY_ROOT/models/clip_vision"; done
  for url in "${LORA_MODELS[@]}"; do provisioning_download "$url" "$COMFY_ROOT/models/loras"; done
  provisioning_print_end
  log "Provisioning log saved to: $PROVISION_LOG"
}

provisioning_start