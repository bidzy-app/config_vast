#!/bin/bash
set -e

# Проверка токена HuggingFace
if [ -z "${HF_TOKEN}" ]; then
    echo "HF_TOKEN is not set. Exiting."
    exit 1
fi

# Директории для моделей и кастомных узлов
WORKSPACE_DIR="${WORKSPACE:-/workspace}"
COMFY_DIR="${WORKSPACE_DIR}/ComfyUI"
mkdir -p "${COMFY_DIR}/models"/{diffusion_models,vae,text_encoders,clip_vision,loras}
mkdir -p "${COMFY_DIR}/custom_nodes"

# Узлы ComfyUI
CUSTOM_NODES=(
    "https://github.com/kijai/ComfyUI-WanVideoWrapper"
    "https://github.com/kijai/ComfyUI-KJNodes"
    "https://github.com/kijai/ComfyUI-VideoHelperSuite"
    "https://github.com/christian-byrne/audio-separation-nodes-comfyui"
    "https://github.com/ltdrdata/ComfyUI-Manager"
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

PYTHON_PACKAGES=(
    "opencv-python-headless==4.7.0.72"
    "diffusers"
    "comfy"
    "librosa"
    "gitpython"
    "numpy<2"
)

# Функция скачивания моделей
function download_models() {
    local dir="$1"
    shift
    mkdir -p "$dir"
    for url in "$@"; do
        echo "[INFO] Downloading: $url"
        wget --header="Authorization: Bearer $HF_TOKEN" -qnc --show-progress -P "$dir" "$url"
    done
}

# Скачивание кастомных узлов
function install_custom_nodes() {
    cd "${COMFY_DIR}/custom_nodes"
    for repo in "${CUSTOM_NODES[@]}"; do
        local dir="${repo##*/}"
        if [ ! -d "$dir" ]; then
            echo "[INFO] Cloning: $repo"
            git clone "$repo"
            if [ -f "$dir/requirements.txt" ]; then
                micromamba -n comfyui run pip install -r "$dir/requirements.txt" || true
            fi
        else
            echo "[INFO] Node already exists: $dir"
        fi
    done
}

# Установка Python пакетов
function install_python_packages() {
    if [ ${#PYTHON_PACKAGES[@]} -gt 0 ]; then
        echo "[INFO] Installing additional Python packages..."
        micromamba -n comfyui run pip install "${PYTHON_PACKAGES[@]}"
    fi
}

echo "[INFO] Starting provisioning..."
install_python_packages
install_custom_nodes
download_models "${COMFY_DIR}/models/diffusion_models" "${DIFFUSION_MODELS[@]}"
download_models "${COMFY_DIR}/models/vae" "${VAE_MODELS[@]}"
download_models "${COMFY_DIR}/models/text_encoders" "${TEXT_ENCODERS[@]}"
download_models "${COMFY_DIR}/models/clip_vision" "${CLIP_VISION_MODELS[@]}"
download_models "${COMFY_DIR}/models/loras" "${LORA_MODELS[@]}"
echo "[INFO] Provisioning complete. You can now start ComfyUI."
