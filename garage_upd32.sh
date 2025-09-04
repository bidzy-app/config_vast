#!/bin/bash
set -e

# Централизованный лог провижининга
COMFY_ROOT="${COMFY_ROOT:-/opt/ComfyUI}"
PROVISION_LOG="$COMFY_ROOT/provisioning.log"

# --- NEW: Function to update the main ComfyUI repository ---
update_comfyui() {
    if [ -d "$COMFY_ROOT/.git" ]; then
        log "Attempting to update ComfyUI..."
        (cd "$COMFY_ROOT" && git pull --ff-only) || log "Could not update ComfyUI. Continuing with existing version."
    else
        log "ComfyUI is not a git repository, skipping update."
    fi
}

mkdir -p "$COMFY_ROOT"
exec > >(tee -a "$PROVISION_LOG") 2>&1

HF_TOKEN="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-${HUGGINGFACEHUB_API_TOKEN:-}}}"
if [ -z "${HF_TOKEN}" ]; then
  echo "HF_TOKEN is not set. Continuing without authentication (public files only)."
else
  echo "HF_TOKEN detected; will be used if anonymous download fails."
fi

# Кастомные ноды
CUSTOM_NODES=(
  "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite"
  "https://github.com/christian-byrne/audio-separation-nodes-comfyui"
  "https://github.com/kijai/ComfyUI-WanVideoWrapper"
  "https://github.com/kijai/ComfyUI-KJNodes.git"
)

# Модели
DIFFUSION_MODELS=(
  "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/InfiniteTalk/Wan2_1-InfiniTetalk-Single_fp16.safensors"
  "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1-I2V-14B-480P_fp8_e4m3fn.safensors"
)
VAE_MODELS=("https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1_VAE_bf16.safensors")
TEXT_ENCODERS=("https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/umt5-xxl-enc-fp8_e4m3fn.safensors")
CLIP_VISION_MODELS=("https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safensors")
LORA_MODELS=("https://huggingface.co/lightx2v/Wan2.1-I2V-14B-480P-StepDistill-CfgDistill-Lightx2v/resolve/main/loras/Wan21_I2V_14B_lightx2v_cfg_step_distill_lora_rank64.safetensors")

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }

provisioning_print_header() {
  printf "\n##############################################\n#      Provisioning container (CPU stage)      #\n##############################################\n\n"
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
  if wget -nc --content-disposition --show-progress -P "$dest" "$url"; then
    log "Finished download (anon): $url"
    return 0
  fi
  if [ -n "$HF_TOKEN" ]; then
    log "Retrying with token: $url"
    wget --header="Authorization: Bearer $HF_TOKEN" \
         -nc --content-disposition --show-progress -P "$dest" "$url"
  fi
}

clone_custom_nodes() {
  mkdir -p "$COMFY_ROOT/custom_nodes"
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
  done
}

# --- ОБНОВЛЁННАЯ И МОДЕРНИЗИРОВАННАЯ ФУНКЦИЯ УСТАНОВКИ МОДУЛЕЙ ---
install_python_packages() {
    local PIP="/opt/micromamba/envs/comfyui/bin/pip"
    local PYTHON_CMD
    PYTHON_CMD="$(dirname "$PIP")/python"

    log "Проверка необходимых Python-модулей..."

    # Список всех необходимых модулей с версиями
    # packaging добавлен для быстрой и современной проверки версий
    # numpy закреплен для избежания проблем с NumPy 2.0
    local requirements=(
        "packaging"
        "librosa==0.10.2"
        "torchaudio>=2.3.0"
        "numpy==1.26.4"
        "moviepy"
        "pillow>=10.3.0"
        "scipy"
        "color-matcher"
        "matplotlib"
        "huggingface_hub"
        "mss"
        "opencv-python"
        "ftfy"
        "accelerate>=1.2.1"
        "einops"
        "diffusers>=0.33.0"
        "peft>=0.17.0"
        "sentencepiece>=0.2.0"
        "protobuf"
        "pyloudnorm"
        "gguf>=0.14.0"
        "imageio-ffmpeg"
    )

    local packages_to_install=()
    for req in "${requirements[@]}"; do
        # --- NEW: Modern, fast, and reliable package version check ---
        # This uses Python's modern 'packaging' and 'importlib.metadata' libraries,
        # which are much faster and more reliable than the legacy 'pkg_resources'.
        if ! "$PYTHON_CMD" -c "
import sys
from importlib.metadata import version, PackageNotFoundError
from packaging.requirements import Requirement
try:
    req = Requirement(sys.argv[1])
    installed_version = version(req.name)
    if req.specifier.contains(installed_version):
        sys.exit(0) # Success: package is installed and version is correct
except PackageNotFoundError:
    pass # Package not found, needs installation
except Exception:
    pass # Any other error, assume it needs installation
sys.exit(1) # Failure: package needs to be installed or updated
" "$req"; then
            log "-> Требуется установка/обновление: '$req'."
            packages_to_install+=("$req")
        else
            log "-> Модуль уже установлен: '$req'."
        fi
    done

    if [ ${#packages_to_install[@]} -gt 0 ]; then
        log "Установка/обновление ${#packages_to_install[@]} модулей..."
        "$PIP" install --upgrade --no-cache-dir "${packages_to_install[@]}"
    else
        log "Все Python-модули уже установлены и соответствуют требованиям. ✨"
    fi
}

provisioning_start() {
  provisioning_print_header
  # --- NEW: Update ComfyUI before installing dependencies ---
  update_comfyui
  create_directories
  clone_custom_nodes
  install_python_packages
  for url in "${DIFFUSION_MODELS[@]}"; do provisioning_download "$url" "$COMFY_ROOT/models/checkpoints"; done
  for url in "${VAE_MODELS[@]}"; do provisioning_download "$url" "$COMFY_ROOT/models/vae"; done
  for url in "${TEXT_ENCODERS[@]}"; do provisioning_download "$url" "$COMFY_ROOT/models/text_encoders"; done
  for url in "${CLIP_VISION_MODELS[@]}"; do provisioning_download "$url" "$COMFY_ROOT/models/clip_vision"; done
  for url in "${LORA_MODELS[@]}"; do provisioning_download "$url" "$COMFY_ROOT/models/loras"; done
  provisioning_print_end
  log "Provisioning log saved to: $PROVISION_LOG"
}

provisioning_start