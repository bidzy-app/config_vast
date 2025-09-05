#!/bin/bash
set -e

# Централизованный лог провижининга
COMFY_ROOT="${COMFY_ROOT:-/opt/ComfyUI}"
PROVISION_LOG="$COMFY_ROOT/provisioning.log"

# --- NEW: Function to update the main ComfyUI repository ---
update_comfyui() {
    if [ -d "$COMFY_ROOT/.git" ]; then
        log "Updating existing ComfyUI repo..."
        (
            cd "$COMFY_ROOT"
            git fetch --all
            git reset --hard origin/master
            git submodule update --init --recursive
        ) || log "Could not update ComfyUI. Continuing with existing version."
    else
        log "ComfyUI is not a git repo. Removing and cloning fresh..."
        rm -rf "$COMFY_ROOT"
        git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFY_ROOT" --depth 1
        (cd "$COMFY_ROOT" && git submodule update --init --recursive)
    fi
}

log_comfy_version() {
    if [ -d "$COMFY_ROOT/.git" ]; then
        local version commit_date
        version=$(cd "$COMFY_ROOT" && git rev-parse --short HEAD)
        commit_date=$(cd "$COMFY_ROOT" && git log -1 --format=%cd --date=short)
        log "ComfyUI version: $version (date: $commit_date)"
    elif [ -f "$COMFY_ROOT/commit_hash.txt" ]; then
        local version
        version=$(cat "$COMFY_ROOT/commit_hash.txt")
        log "ComfyUI version (from commit_hash.txt): $version"
    else
        log "ComfyUI version: unknown (no git repo or commit_hash.txt)"
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
    "$COMFY_ROOT/models/diffusion_models" \
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

install_comfyui_requirements() {
    local PYTHON_BIN
    if [ -x "$COMFY_ROOT/python_embeded/python.exe" ]; then
        PYTHON_BIN="$COMFY_ROOT/python_embeded/python.exe"
    else
        PYTHON_BIN="/opt/micromamba/envs/comfyui/bin/python"
    fi

    log "Installing ComfyUI requirements with $PYTHON_BIN..."
    "$PYTHON_BIN" -s -m pip install --upgrade pip setuptools wheel
    "$PYTHON_BIN" -s -m pip install -r "$COMFY_ROOT/requirements.txt"
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
    local requirements=(
        "packaging"
        "librosa"
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
        "av"
        "comfy-cli"
        "xformers"
        "sageattention"
    )

    # Модули, которые всегда нужно переустанавливать
    local force_update=( "torch" "torchvision" "torchaudio" )

    local packages_to_install=("${force_update[@]}") # Сначала добавляем принудительные модули

    for req in "${requirements[@]}"; do
        if ! "$PYTHON_CMD" -c "
import sys
from importlib.metadata import version, PackageNotFoundError
from packaging.requirements import Requirement
try:
    req = Requirement(sys.argv[1])
    installed_version = version(req.name)
    if req.specifier.contains(installed_version):
        sys.exit(0)
except PackageNotFoundError:
    pass
except Exception:
    pass
sys.exit(1)
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
  update_comfyui
  log_comfy_version
  install_comfyui_requirements
  create_directories
  clone_custom_nodes
  install_python_packages
  for url in "${DIFFUSION_MODELS[@]}"; do provisioning_download "$url" "$COMFY_ROOT/models/diffusion_models"; done
  for url in "${VAE_MODELS[@]}"; do provisioning_download "$url" "$COMFY_ROOT/models/vae"; done
  for url in "${TEXT_ENCODERS[@]}"; do provisioning_download "$url" "$COMFY_ROOT/models/text_encoders"; done
  for url in "${CLIP_VISION_MODELS[@]}"; do provisioning_download "$url" "$COMFY_ROOT/models/clip_vision"; done
  for url in "${LORA_MODELS[@]}"; do provisioning_download "$url" "$COMFY_ROOT/models/loras"; done
  provisioning_print_end
  log "Provisioning log saved to: $PROVISION_LOG"
}

provisioning_start