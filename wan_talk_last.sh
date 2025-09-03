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

# Add packages needed by custom nodes
PYTHON_PACKAGES=(
    "opencv-python-headless==4.7.0.72"
    "diffusers"
    "comfy"
    "librosa"
    "gitpython"
    "numpy<2"
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

# Ensure VAST_TCP_PORT_3000 exists to avoid pyworker KeyError
function ensure_worker_port_env() {
    if [ -z "${VAST_TCP_PORT_3000+x}" ]; then
        # try a few common candidate envs
        for candidate in 18288 18188 40440 40440; do
            varname="VAST_TCP_PORT_${candidate}"
            if [ ! -z "${!varname}" ]; then
                echo "[INFO] Setting VAST_TCP_PORT_3000=${!varname} (from ${varname})"
                echo "VAST_TCP_PORT_3000=${!varname}" >> /etc/environment || true
                export VAST_TCP_PORT_3000="${!varname}"
                return 0
            fi
        done
        echo "[WARN] VAST_TCP_PORT_3000 not found; pyworker may error"
    else
        echo "[INFO] VAST_TCP_PORT_3000 already set"
    fi
}

# Robust installer: try micromamba with retries on lock errors, fallback to pip
function safe_micromamba_install() {
    pkgs=("$@")
    if command -v micromamba >/dev/null 2>&1; then
        tries=0
        max=6
        wait_s=5
        while [ $tries -lt $max ]; do
            if micromamba -n comfyui run ${PIP_INSTALL} "${pkgs[@]}"; then
                return 0
            fi
            echo "[WARN] micromamba install failed, retrying in ${wait_s}s (try $((tries+1))/$max)..."
            sleep $wait_s
            tries=$((tries+1))
            wait_s=$((wait_s*2))
        done
        echo "[WARN] micromamba failed after retries, falling back to pip..."
    fi

    if command -v pip >/dev/null 2>&1; then
        pip install --no-cache-dir "${pkgs[@]}" || true
    else
        echo "[ERROR] pip not available to install packages: ${pkgs[*]}"
    fi
}

# Clone nodes only (no per-node pip yet)
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
            if [[ ${AUTO_UPDATE,,} != "false" ]]; then
                echo "[INFO] Updating node: $dir"
                ( cd "$dir" && git pull --quiet ) || true
            fi
        fi
    done
}

# After base packages installed, install node-specific requirements if present
function install_node_requirements() {
    cd /workspace/ComfyUI/custom_nodes
    for d in */ ; do
        [ -d "$d" ] || continue
        req="$d/requirements.txt"
        if [ -f "$req" ]; then
            echo "[INFO] Installing requirements for node $d"
            if command -v micromamba >/dev/null 2>&1; then
                micromamba -n comfyui run ${PIP_INSTALL} -r "$req" || true
            else
                pip install -r "$req" || true
            fi
        fi
    done
}

function install_python_packages() {
    if [ ${#PYTHON_PACKAGES[@]} -gt 0 ]; then
        echo "[INFO] Installing additional Python packages..."
        safe_micromamba_install "${PYTHON_PACKAGES[@]}"
    fi
}

### Основной запуск ###

function provisioning_start() {
    provisioning_print_header
    create_directories

    ensure_worker_port_env

    # clone nodes first (no installs) so files exist
    clone_custom_nodes

    # install base python packages (numpy<2, diffusers, comfy, librosa, cv2 headless ...)
    install_python_packages

    # then install per-node requirements (they may depend on base packages)
    install_node_requirements

    # download models
    provisioning_download "/workspace/ComfyUI/models/diffusion_models" "${DIFFUSION_MODELS[@]}"
    provisioning_download "/workspace/ComfyUI/models/vae" "${VAE_MODELS[@]}"
    provisioning_download "/workspace/ComfyUI/models/text_encoders" "${TEXT_ENCODERS[@]}"
    provisioning_download "/workspace/ComfyUI/models/clip_vision" "${CLIP_VISION_MODELS[@]}"
    provisioning_download "/workspace/ComfyUI/models/loras" "${LORA_MODELS[@]}"

    provisioning_print_end
}

provisioning_start
