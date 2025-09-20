#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[provision] ERROR on line $LINENO" >&2' ERR
umask 022

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

# Определяем пользователя, под которым будет работать comfyui (до ensure_paths)
RUN_USER="$(awk -F= '/^\s*user=/{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' /etc/supervisor/conf.d/comfyui.conf 2>/dev/null || true)"
[ -z "$RUN_USER" ] && RUN_USER="$(id -un 1000 2>/dev/null || echo root)"
RUN_GROUP="$(id -gn "$RUN_USER" 2>/dev/null || echo "$RUN_USER")"

# Нормализуем пути, устраняем ELOOP и настраиваем права
ensure_paths() {
    BASE_DIR="${WORKSPACE_DIR:-${WORKSPACE:-/workspace}}"
    mkdir -p "$BASE_DIR"

    chmod 755 "$BASE_DIR" || true
    chown "$RUN_USER":"$RUN_GROUP" "$BASE_DIR" || true

    REAL_ROOT="${COMFY_REAL_ROOT:-$BASE_DIR/ComfyUI}"
    LINK_PATH="/opt/ComfyUI"

    # Нормализуем пути
    RR="$(readlink -m "$REAL_ROOT")"
    LP="$(readlink -m "$LINK_PATH")"

    # Если REAL_ROOT фактически указывает на LINK_PATH — выберем отдельный реальный каталог,
    # чтобы не создавать цикл /opt <-> /workspace.
    if [ "$RR" = "$LP" ]; then
        REAL_ROOT="${BASE_DIR}/ComfyUI.real"
        RR="$(readlink -m "$REAL_ROOT")"
    fi

    # REAL_ROOT должен быть реальным каталогом, не симлинком
    [ -L "$REAL_ROOT" ] && rm -f "$REAL_ROOT"
    mkdir -p "$REAL_ROOT"
    chown -R "$RUN_USER":"$RUN_GROUP" "$REAL_ROOT" || true
    chmod -R u+rwX,g+rX "$REAL_ROOT" || true

    # Готовим /opt/ComfyUI:
    # - если мы выбрали /opt/ComfyUI в качестве реального корня, то просто убеждаемся, что это директория
    # - иначе создаём линк /opt/ComfyUI -> REAL_ROOT
    if [ "$RR" = "$LP" ]; then
        mkdir -p "$LINK_PATH"
    else
        if [ -L "$LINK_PATH" ] || { [ -e "$LINK_PATH" ] && [ ! -d "$LINK_PATH" ]; }; then
            rm -f "$LINK_PATH"
        fi
        [ ! -e "$LINK_PATH" ] && ln -sfn "$REAL_ROOT" "$LINK_PATH"
    fi

    COMFY_ROOT="$REAL_ROOT"
}

ensure_paths

PROVISION_LOG="$COMFY_ROOT/provisioning.log"
mkdir -p "$COMFY_ROOT"
exec > >(tee -a "$PROVISION_LOG") 2>&1

HF_TOKEN="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-${HUGGINGFACEHUB_API_TOKEN:-}}}"
if [ -z "${HF_TOKEN}" ]; then
    log "HF_TOKEN is not set. Continuing without authentication (public files only)."
else
    log "HF_TOKEN detected; will be used if anonymous download fails."
fi

# Модели для автозагрузки
DIFFUSION_MODELS=(
    "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/InfiniteTalk/Wan2_1-InfiniTetalk-Single_fp16.safetensors?download=true"
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

# Кастомные ноды
CUSTOM_NODES=(
    "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite"
    "https://github.com/christian-byrne/audio-separation-nodes-comfyui"
    "https://github.com/kijai/ComfyUI-WanVideoWrapper"
    "https://github.com/kijai/ComfyUI-KJNodes.git"
)

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
    chown -R "$RUN_USER":"$RUN_GROUP" "$COMFY_ROOT" || true
    chmod -R u+rwX,g+rX "$COMFY_ROOT" || true
}

provisioning_download() {
    local url="$1" dest="$2"
    mkdir -p "$dest"
    chown "$RUN_USER":"$RUN_GROUP" "$dest" || true
    log "Starting download: $url -> $dest"
    if wget -nc --content-disposition --show-progress -P "$dest" "$url"; then
        log "Finished download (anon): $url"
        return 0
    fi
    if [ -n "$HF_TOKEN" ]; then
        log "Retrying with token: $url"
        wget --header="Authorization: Bearer $HF_TOKEN" -nc --content-disposition --show-progress -P "$dest" "$url"
    fi
}

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
        log "Cloning fresh ComfyUI into $COMFY_ROOT"
        rm -rf "$COMFY_ROOT"
        git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFY_ROOT" --depth 1
        (cd "$COMFY_ROOT" && git submodule update --init --recursive)
    fi
    chown -R "$RUN_USER":"$RUN_GROUP" "$COMFY_ROOT" || true
    chmod -R u+rwX,g+rX "$COMFY_ROOT" || true
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
    chown "$RUN_USER":"$RUN_GROUP" "$COMFY_ROOT/custom_nodes" || true
    cd "$COMFY_ROOT/custom_nodes"
    for repo in "${CUSTOM_NODES[@]}"; do
        dir="${repo##*/}"
        dir="${dir%.git}"
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

install_python_packages() {
    local PIP="/opt/micromamba/envs/comfyui/bin/pip"
    local PYTHON_CMD
    PYTHON_CMD="$(dirname "$PIP")/python"

    log "Проверка необходимых Python-модулей..."

    local requirements=(
        "packaging" "librosa" "numpy==1.26.4" "moviepy" "pillow>=10.3.0" "scipy"
        "color-matcher" "matplotlib" "huggingface_hub" "mss" "opencv-python"
        "ftfy" "accelerate>=1.2.1" "einops" "diffusers>=0.33.0" "peft>=0.17.0"
        "sentencepiece>=0.2.0" "protobuf" "pyloudnorm" "gguf>=0.14.0" "imageio-ffmpeg"
        "av" "comfy-cli" "sageattention"
    )
    local force_update=("torch" "torchvision" "torchaudio" "xformers")

    local packages_to_install=("${force_update[@]}")

    for req in "${requirements[@]}"; do
        if ! "$PYTHON_CMD" - <<'PY' "$req"; then
import sys
from importlib.metadata import version, PackageNotFoundError
from packaging.requirements import Requirement
req = Requirement(sys.argv[1])
try:
    v = version(req.name)
    ok = req.specifier.contains(v) if req.specifier else True
    sys.exit(0 if ok else 1)
except PackageNotFoundError:
    sys.exit(1)
PY
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
        log "Все Python-модули уже установлены и соответствуют требованиям."
    fi
}

provisioning_start() {
    provisioning_print_header
    create_directories
    update_comfyui
    log_comfy_version
    install_comfyui_requirements
    clone_custom_nodes
    install_python_packages

    for url in "${DIFFUSION_MODELS[@]:-}"; do
        provisioning_download "$url" "$COMFY_ROOT/models/diffusion_models"
    done
    for url in "${VAE_MODELS[@]:-}"; do
        provisioning_download "$url" "$COMFY_ROOT/models/vae"
    done
    for url in "${TEXT_ENCODERS[@]:-}"; do
        provisioning_download "$url" "$COMFY_ROOT/models/text_encoders"
    done
    for url in "${CLIP_VISION_MODELS[@]:-}"; do
        provisioning_download "$url" "$COMFY_ROOT/models/clip_vision"
    done
    for url in "${LORA_MODELS[@]:-}"; do
        provisioning_download "$url" "$COMFY_ROOT/models/loras"
    done

    # Финальный проход по правам — на случай, если что-то создалось от root
    chown -R "$RUN_USER":"$RUN_GROUP" "$COMFY_ROOT" || true
    chmod -R u+rwX,g+rX "$COMFY_ROOT" || true

    provisioning_print_end
    log "Provisioning log saved to: $PROVISION_LOG"
}

provisioning_start
