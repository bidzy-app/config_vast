#!/bin/bash
set -e

echo "[INFO] Starting custom provisioning for ComfyUI..."

# === Создаём папки моделей ===
mkdir -p /workspace/ComfyUI/models/diffusion_models
mkdir -p /workspace/ComfyUI/models/vae
mkdir -p /workspace/ComfyUI/models/text_encoders
mkdir -p /workspace/ComfyUI/models/clip_vision
mkdir -p /workspace/ComfyUI/models/loras
mkdir -p /workspace/ComfyUI/custom_nodes

# === Модели ===
echo "[INFO] Downloading diffusion models..."
wget -nc -O /workspace/ComfyUI/models/diffusion_models/Wan2_1-InfiniTetalk-Single_fp16.safetensors \
  "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/InfiniteTalk/Wan2_1-InfiniTetalk-Single_fp16.safetensors?download=true"

wget -nc -O /workspace/ComfyUI/models/diffusion_models/Wan2_1-I2V-14B-480P_fp8_e4m3fn.safetensors \
  "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1-I2V-14B-480P_fp8_e4m3fn.safetensors"

echo "[INFO] Downloading VAE..."
wget -nc -O /workspace/ComfyUI/models/vae/Wan2_1_VAE_bf16.safetensors \
  "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1_VAE_bf16.safetensors"

echo "[INFO] Downloading text encoder..."
wget -nc -O /workspace/ComfyUI/models/text_encoders/umt5-xxl-enc-fp8_e4m3fn.safetensors \
  "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/umt5-xxl-enc-fp8_e4m3fn.safetensors"

echo "[INFO] Downloading CLIP-Vision..."
wget -nc -O /workspace/ComfyUI/models/clip_vision/clip_vision_h.safetensors \
  "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors"

echo "[INFO] Downloading LoRA..."
wget -nc -O /workspace/ComfyUI/models/loras/Wan21_I2V_14B_lightx2v_cfg_step_distill_lora_rank64.safetensors \
  "https://huggingface.co/lightx2v/Wan2.1-I2V-14B-480P-StepDistill-CfgDistill-Lightx2v/resolve/main/loras/Wan21_I2V_14B_lightx2v_cfg_step_distill_lora_rank64.safetensors"

# === Кастомные ноды ===
echo "[INFO] Installing custom nodes..."
cd /workspace/ComfyUI/custom_nodes

# WanVideo Wrapper
if [ ! -d "ComfyUI-WanVideoWrapper" ]; then
  git clone https://github.com/kijai/ComfyUI-WanVideoWrapper.git
  cd ComfyUI-WanVideoWrapper
  pip install . || true
  cd ..
fi

# KJNodes
if [ ! -d "ComfyUI-KJNodes" ]; then
  git clone https://github.com/kijai/ComfyUI-KJNodes.git
fi

# Video Helper Suite
if [ ! -d "ComfyUI-VideoHelperSuite" ]; then
  git clone https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git
  cd ComfyUI-VideoHelperSuite
  pip install -r requirements.txt || true
  cd ..
fi

# Audio separation nodes
if [ ! -d "audio-separation-nodes-comfyui" ]; then
  git clone https://github.com/christian-byrne/audio-separation-nodes-comfyui.git
  cd audio-separation-nodes-comfyui
  pip install -r requirements.txt || true
  cd ..
fi

echo "[INFO] Custom provisioning complete!"