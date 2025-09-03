#!/bin/bash

# Этот файл должен выполняться в init.sh (CPU provisioning stage)
# GPU запустится только после завершения всех установок

if [ -z "${HF_TOKEN}" ]; then
    echo "HF_TOKEN is not set. Exiting."
    exit 1
fi

CUSTOM_NODES=(
    "https://github.com/kijai/ComfyUI-WanVideoWrapper"
    "https://github.com/kijai/ComfyUI-KJNodes"
    "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite"
    "https://github.com/christian-byrne/audio-separation-nodes-comfyui"
    "https://github.com/ltdrdata/ComfyUI-Manager"
)

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
    # "opencv-python==4.7.0.72"
)

### Вспомогательные функции ###

function provisioning_print_header() {
    printf "\n##############################################\n"
    printf "#      Provisioning container (CPU stage)     #\n"
    printf "##############################################\n\n"
}

function provisioning_print_end() {
    printf "\nProvisioning complete: Web UI will start now (GPU stage)\n\n"
}

function create_directories() {
    mkdir -p /workspace/ComfyUI/models/{diffusion_models,vae,text_encoders,clip_vision,loras}
    mkdir -p /workspace/ComfyUI/custom_nodes
}

function provisioning_download() {
    local dir="$1"
    shift
    mkdir -p "$dir"
    for url in "$@"; do
        echo "[INFO] Downloading: $url"
        wget --header="Authorization: Bearer $HF_TOKEN" -qnc --content-disposition -P "$dir" "$url"
    done
}

function install_custom_nodes() {
    cd /workspace/ComfyUI/custom_nodes
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

function install_python_packages() {
    if [ ${#PYTHON_PACKAGES[@]} -gt 0 ]; then
        micromamba -n comfyui run pip install "${PYTHON_PACKAGES[@]}"
    fi
}

### Основной запуск ###

function provisioning_start() {
    provisioning_print_header
    create_directories
    install_python_packages
    install_custom_nodes
    provisioning_download "/workspace/ComfyUI/models/diffusion_models" "${DIFFUSION_MODELS[@]}"
    provisioning_download "/workspace/ComfyUI/models/vae" "${VAE_MODELS[@]}"
    provisioning_download "/workspace/ComfyUI/models/text_encoders" "${TEXT_ENCODERS[@]}"
    provisioning_download "/workspace/ComfyUI/models/clip_vision" "${CLIP_VISION_MODELS[@]}"
    provisioning_download "/workspace/ComfyUI/models/loras" "${LORA_MODELS[@]}"
    provisioning_print_end
}

provisioning_start
