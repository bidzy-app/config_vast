#!/bin/bash
set -e

# This file should be executed in init.sh (CPU provisioning stage)
# GPU will start only after all installations are complete

if [ -z "${HF_TOKEN}" ]; then
    echo "HF_TOKEN is not set. Exiting."
    exit 1
fi

CUSTOM_NODES=(
    # "https://github.com/kijai/ComfyUI-WanVideoWrapper"
    # "https://github.com/kijai/ComfyUI-KJNodes" # Temporarily removed due to incompatibility
    "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite"
    "https://github.com/christian-byrne/audio-separation-nodes-comfyui"
    # "https://github.com/ltdrdata/ComfyUI-Manager"
)

DIFFUSION_MODELS=(
    "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/InfiniteTalk/Wan2_1-InfiniTetalk-Single_fp16.safensors"
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

# Add packages needed by custom nodes with corrected versions
PYTHON_PACKAGES=(
    "numpy<2"
    "opencv-python-headless==4.7.0.72"
    "diffusers"
    "librosa"
    "GitPython"
)

### Helper Functions ###

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
    wget --header="Authorization: Bearer $HF_TOKEN" -qnc --content-disposition --show-progress -P "$2" "$1"
}

function clone_custom_nodes() {
    mkdir -p /workspace/ComfyUI/custom_nodes
    cd /workspace/ComfyUI/custom_nodes

    for repo in "${CUSTOM_NODES[@]}"; do
        dir="${repo##*/}"
        dir="${dir%.git}"

        if [ ! -d "$dir" ]; then
            echo "[INFO] Cloning: $repo"
            git clone "$repo" "$dir" --depth 1 || git clone "$repo" "$dir"
        else
            echo "[INFO] Node already exists: $dir"
            (cd "$dir" && git pull --ff-only || true)
        fi
    done
}

function install_python_packages() {
    local PIP="/opt/micromamba/envs/comfyui/bin/pip"
    echo "[INFO] Installing additional Python packages (direct pip)..."

    "$PIP" install --upgrade --no-cache-dir \
        "numpy<2,>=1.26.4" \
        "opencv-python-headless==4.7.0.72" \
        diffusers \
        librosa \
        GitPython \
        imageio[ffmpeg] \
        imageio-ffmpeg \
        soundfile \
        av \
        "moviepy<2" \
        toml
}

function verify_installations() {
    echo "[INFO] Verifying installations..."
    local PY="/opt/micromamba/envs/comfyui/bin/python"

    "$PY" - << 'PYEOF'
import numpy, diffusers, librosa, git, cv2, av, moviepy, toml
v = numpy.__version__
assert v.startswith('1.'), f'Incorrect NumPy version: {v}'
print('✅ NumPy version OK:', v)
print('✅ diffusers OK')
print('✅ librosa OK')
print('✅ GitPython OK')
print('✅ OpenCV (cv2) OK')
print('✅ PyAV OK')
print('✅ moviepy OK')
print('✅ toml OK')
PYEOF

    echo "[INFO] All package verifications passed!"
}

### Main Execution ###

function provisioning_start() {
    provisioning_print_header
    create_directories
    clone_custom_nodes
    
    # Install and then immediately verify
    install_python_packages
    verify_installations

    # Download models after environment is confirmed stable
    for url in "${DIFFUSION_MODELS[@]}"; do provisioning_download "$url" "/workspace/ComfyUI/models/diffusion_models"; done
    for url in "${VAE_MODELS[@]}"; do provisioning_download "$url" "/workspace/ComfyUI/models/vae"; done
    for url in "${TEXT_ENCODERS[@]}"; do provisioning_download "$url" "/workspace/ComfyUI/models/text_encoders"; done
    for url in "${CLIP_VISION_MODELS[@]}"; do provisioning_download "$url" "/workspace/ComfyUI/models/clip_vision"; done
    for url in "${LORA_MODELS[@]}"; do provisioning_download "$url" "/workspace/ComfyUI/models/loras"; done

    provisioning_print_end
}

provisioning_start