#!/bin/bash
set -e

# Централизованный лог провижининга
COMFY_ROOT="${COMFY_ROOT:-/opt/ComfyUI}"
PROVISION_LOG="$COMFY_ROOT/provisioning.log"

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
  "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/InfiniteTalk/Wan2_1-InfiniTetalk-Single_fp16.safetensors"
  "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1-I2V-14B-480P_fp8_e4m3fn.safetensors"
)
VAE_MODELS=("https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1_VAE_bf16.safetensors")
TEXT_ENCODERS=("https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/umt5-xxl-enc-fp8_e4m3fn.safetensors")
CLIP_VISION_MODELS=("https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors")
LORA_MODELS=("https://huggingface.co/lightx2v/Wan2.1-I2V-14B-480P-StepDistill-CfgDistill-Lightx2v/resolve/main/loras/Wan21_I2V_14B_lightx2v_cfg_step_distill_lora_rank64.safetensors")

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }

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

install_python_packages() {
  local PIP="/opt/micromamba/envs/comfyui/bin/pip"
  echo "[INFO] Installing fixed Python package set..."
  "$PIP" install --no-cache-dir \
    accelerate==1.10.1 aiofiles==24.1.0 aiohappyeyeballs==2.6.1 aiohttp==3.12.15 aiohttp_socks==0.10.1 \
    aiosignal==1.4.0 albucore==0.0.24 albumentations==2.0.8 alembic==1.16.4 annotated-types==0.7.0 \
    asttokens==3.0.0 attrs==25.3.0 audioread==3.0.1 av==15.0.0 beautifulsoup4==4.13.4 certifi==2025.6.15 \
    cffi==1.17.1 chardet==5.2.0 charset-normalizer==3.4.2 click==8.2.1 color-matcher==0.6.0 \
    colour-science==0.4.6 comfyui-embedded-docs==0.2.4 comfyui_frontend_package==1.23.4 \
    comfyui_workflow_templates==0.1.41 comm==0.2.2 contourpy==1.2.1 cryptography==45.0.5 cycler==0.12.1 \
    ddt==1.7.2 debugpy==1.8.14 decorator==5.2.1 diffusers==0.35.1 docutils==0.22 easydict==1.13 \
    einops==0.8.1 executing==2.2.0 filelock==3.18.0 fonttools==4.59.2 frozenlist==1.7.0 fsspec==2025.5.1 \
    ftfy==6.3.1 future==1.0.0 gdown==5.2.0 gguf==0.17.1 gitdb==4.0.12 GitPython==3.1.45 greenlet==3.2.3 \
    h11==0.16.0 h2==4.2.0 hf-xet==1.1.5 hpack==4.1.0 huggingface-hub==0.34.3 hyperframe==6.1.0 \
    idna==3.10 imageio==2.37.0 imageio-ffmpeg==0.6.0 importlib_metadata==8.7.0 inquirerpy==0.3.4 \
    ipykernel==6.29.5 ipython==9.3.0 ipython_pygments_lexers==1.1.1 ipywidgets==8.1.7 jedi==0.19.2 \
    Jinja2==3.1.4 joblib==1.5.2 jsonschema==4.25.0 jsonschema-specifications==2025.4.1 \
    jupyter_client==8.6.3 jupyter_core==5.8.1 jupyterlab_widgets==3.0.15 kiwisolver==1.4.9 \
    kornia==0.8.1 kornia_rs==0.1.9 lazy_loader==0.4 librosa==0.10.2 llvmlite==0.44.0 Mako==1.3.10 \
    markdown-it-py==3.0.0 MarkupSafe==2.1.5 matplotlib==3.10.6 matplotlib-inline==0.1.7 \
    matrix-nio==0.25.2 mdurl==0.1.2 moviepy==2.2.1 mpmath==1.3.0 msgpack==1.1.1 mss==10.1.0 \
    multidict==6.6.3 nest-asyncio==1.6.0 networkx==3.3 numba==0.61.2 numpy==2.1.2 \
    opencv-python==4.12.0.88 opencv-python-headless==4.12.0.88 packaging==25.0 parso==0.8.4 \
    peft==0.17.1 pexpect==4.9.0 pfzy==0.3.4 pillow==11.0.0 pip==25.1.1 pixeloe==0.1.4 platformdirs==4.3.8 \
    pooch==1.8.2 proglog==0.1.12 prompt_toolkit==3.0.51 propcache==0.3.2 protobuf==6.32.0 psutil==7.0.0 \
    ptyprocess==0.7.0 pure_eval==0.2.3 pycparser==2.22 pycryptodome==3.23.0 pydantic==2.11.7 \
    pydantic_core==2.33.2 pydantic-settings==2.10.1 PyGithub==2.7.0 Pygments==2.19.2 PyJWT==2.10.1 \
    pyloudnorm==0.1.1 PyMatting==1.1.14 PyNaCl==1.5.0 pyparsing==3.2.3 PySocks==1.7.1 \
    python-dateutil==2.9.0.post0 python-dotenv==1.1.1 python-socks==2.7.1 PyYAML==6.0.2 pyzmq==27.0.0 \
    referencing==0.36.2 regex==2025.7.34 rembg==2.0.67 requests==2.32.4 rich==14.1.0 rpds-py==0.26.0 \
    safetensors==0.5.3 scikit-image==0.25.2 scikit-learn==1.7.1 scipy==1.16.1 sentencepiece==0.2.0 \
    setuptools==80.9.0 shellingham==1.5.4 simsimd==6.5.0 six==1.17.0 smmap==5.0.2 soundfile==0.13.1 \
    soupsieve==2.7 soxr==0.5.0.post1 spandrel==0.4.1 SQLAlchemy==2.0.42 stack-data==0.6.3 \
    stringzilla==3.12.5 sympy==1.13.3 threadpoolctl==3.6.0 tifffile==2025.6.11 timm==1.0.19 \
    tokenizers==0.21.4 toml==0.10.2 torch==2.7.1+cu128 torchaudio==2.7.1+cu128 torchsde==0.2.6 \
    torchvision==0.22.1+cu128 tornado==6.5.1 tqdm==4.67.1 traitlets==5.14.3 trampoline==0.1.2 \
    transformers==4.54.1 transparent-background==1.3.4 triton==3.3.1 typer==0.16.0 typing_extensions==4.14.0 \
    typing-inspection==0.4.1 unpaddedbase64==2.1.0 urllib3==2.5.0 uv==0.8.4 wcwidth==0.2.13 wget==3.2 \
    wheel==0.45.1 widgetsnbextension==4.0.14 yarl==1.20.1 zipp==3.23.0
}

provisioning_start() {
  provisioning_print_header
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
