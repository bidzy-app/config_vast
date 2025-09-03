#!/bin/bash
set -e

# --- new: central provisioning log (tee -> file and stdout) ---
PROVISION_LOG="/opt/ComfyUI/provisioning.log"
mkdir -p /opt/ComfyUI
# Redirect all stdout/stderr to both console and provisioning log
exec > >(tee -a "$PROVISION_LOG") 2>&1
# --- end new ---

if [ -z "${HF_TOKEN}" ]; then
    echo "HF_TOKEN is not set. Exiting."
    exit 1
fi

CUSTOM_NODES=(
    # "https://github.com/kijai/ComfyUI-WanVideoWrapper" # disabled
    "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite"
    "https://github.com/christian-byrne/audio-separation-nodes-comfyui"
    # "https://github.com/ltdrdata/ComfyUI-Manager" # disabled
)

DIFFUSION_MODELS=(
    "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/InfiniteTalk/Wan2_1-InfiniTetalk-Single_fp16.safetensors"
    "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1-I2V-14B-480P_fp8_e4m3fn.safetensors"
)

VAE_MODELS=("https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1_VAE_bf16.safetensors")
TEXT_ENCODERS=("https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/umt5-xxl-enc-fp8_e4m3fn.safetensors")
CLIP_VISION_MODELS=("https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors")
LORA_MODELS=("https://huggingface.co/lightx2v/Wan2.1-I2V-14B-480P-StepDistill-CfgDistill-Lightx2v/resolve/main/loras/Wan21_I2V_14B_lightx2v_cfg_step_distill_lora_rank64.safetensors")

function provisioning_print_header() {
    printf "\n##############################################\n#      Provisioning container (CPU stage)     #\n##############################################\n\n"
}

function provisioning_print_end() {
    printf "\nProvisioning complete: Web UI will start now (GPU stage)\n\n"
}

function create_directories() {
    mkdir -p /opt/ComfyUI/models/{diffusion_models,vae,text_encoders,clip_vision,loras} /opt/ComfyUI/custom_nodes
}

function log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

function provisioning_download() {
    local url="$1"; local dest="$2"
    mkdir -p "$dest"
    log "Starting download: $url -> $dest"
    # Do not use -q (quiet); write full wget output to tee so it lands in PROVISION_LOG
    wget --header="Authorization: Bearer $HF_TOKEN" -nc --content-disposition --show-progress -P "$dest" "$url" 2>&1 | tee -a "$PROVISION_LOG"
    local rc=${PIPESTATUS[0]:-0}
    if [ $rc -ne 0 ]; then
        log "ERROR: download failed: $url (exit $rc)"
        return $rc
    fi
    log "Finished download: $url"
}

function clone_custom_nodes() {
    mkdir -p /opt/ComfyUI/custom_nodes
    cd /opt/ComfyUI/custom_nodes
    for repo in "${CUSTOM_NODES[@]}"; do
        dir="${repo##*/}"; dir="${dir%.git}"
        if [ ! -d "$dir" ]; then
            log "Cloning: $repo"
            # show git output to log as well
            git clone "$repo" "$dir" --depth 1 2>&1 | tee -a "$PROVISION_LOG" || (git clone "$repo" "$dir" 2>&1 | tee -a "$PROVISION_LOG")
        else
            log "Node already exists: $dir — pulling updates"
            (cd "$dir" && git pull --ff-only 2>&1 | tee -a "$PROVISION_LOG" || true)
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
v = numpy.__version__   # <-- fixed: use string version
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

function provisioning_start() {
    provisioning_print_header
    create_directories
    clone_custom_nodes
    install_python_packages
    verify_installations
    for url in "${DIFFUSION_MODELS[@]}"; do provisioning_download "$url" "/opt/ComfyUI/models/diffusion_models"; done
    for url in "${VAE_MODELS[@]}"; do provisioning_download "$url" "/opt/ComfyUI/models/vae"; done
    for url in "${TEXT_ENCODERS[@]}"; do provisioning_download "$url" "/opt/ComfyUI/models/text_encoders"; done
    for url in "${CLIP_VISION_MODELS[@]}"; do provisioning_download "$url" "/opt/ComfyUI/models/clip_vision"; done
    for url in "${LORA_MODELS[@]}"; do provisioning_download "$url" "/opt/ComfyUI/models/loras"; done
    provisioning_print_end
    log "Provisioning log saved to: $PROVISION_LOG"
}

provisioning_start
