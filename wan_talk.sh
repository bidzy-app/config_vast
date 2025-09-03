#!/bin/bash
set -e

if [ -z "${HF_TOKEN}" ]; then
    echo "HF_TOKEN is not set. Exiting."
    exit 1
fi

# Define model URLs
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

CUSTOM_NODES=(
    "https://github.com/kijai/ComfyUI-WanVideoWrapper"
    "https://github.com/kijai/ComfyUI-KJNodes"
    "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite"
    "https://github.com/christian-byrne/audio-separation-nodes-comfyui"
)

PYTHON_PACKAGES=(
    #"opencv-python==4.7.0.72"
)

NODES=(
    "https://github.com/ltdrdata/ComfyUI-Manager"
)

# Function to create directories
function create_directories() {
    echo "[INFO] Creating directories..."
    mkdir -p /workspace/ComfyUI/models/diffusion_models
    mkdir -p /workspace/ComfyUI/models/vae
    mkdir -p /workspace/ComfyUI/models/text_encoders
    mkdir -p /workspace/ComfyUI/models/clip_vision
    mkdir -p /workspace/ComfyUI/models/loras
    mkdir -p /workspace/ComfyUI/custom_nodes
}

# Function to download models
function download_models() {
    local dir="$1"
    shift
    local urls=("$@")
    mkdir -p "$dir"
    for url in "${urls[@]}"; do
        echo "[INFO] Downloading: $url"
        wget --header="Authorization: Bearer $HF_TOKEN" -nc -P "$dir" "$url"
    done
}

# Function to install custom nodes
function install_custom_nodes() {
    cd /workspace/ComfyUI/custom_nodes
    for repo in "${CUSTOM_NODES[@]}"; do
        local dir="${repo##*/}"
        if [ ! -d "$dir" ]; then
            echo "[INFO] Cloning: $repo"
            git clone "$repo"
            if [ -f "$dir/requirements.txt" ]; then
                cd "$dir"
                pip install -r requirements.txt || true
                cd ..
            fi
        else
            echo "[INFO] Node already exists: $dir"
        fi
    done
}

# Function to install Python packages
function install_python_packages() {
    if [ ${#PYTHON_PACKAGES[@]} -gt 0 ]; then
        echo "[INFO] Installing Python packages..."
        pip install "${PYTHON_PACKAGES[@]}"
    fi
}

# Function to install nodes
function install_nodes() {
    for repo in "${NODES[@]}"; do
        local dir="${repo##*/}"
        local path="/workspace/ComfyUI/custom_nodes/${dir}"
        if [ ! -d "$path" ]; then
            echo "[INFO] Cloning node: $repo"
            git clone "$repo" "$path"
        else
            echo "[INFO] Node already exists: $dir"
        fi
    done
}

# Main provisioning function
function provisioning_start() {
    create_directories
    install_python_packages
    install_nodes
    download_models "/workspace/ComfyUI/models/diffusion_models" "${DIFFUSION_MODELS[@]}"
    download_models "/workspace/ComfyUI/models/vae" "${VAE_MODELS[@]}"
    download_models "/workspace/ComfyUI/models/text_encoders" "${TEXT_ENCODERS[@]}"
    download_models "/workspace/ComfyUI/models/clip_vision" "${CLIP_VISION_MODELS[@]}"
    download_models "/workspace/ComfyUI/models/loras" "${LORA_MODELS[@]}"
    install_custom_nodes
    echo "[INFO] Custom provisioning complete!"
}

provisioning_start