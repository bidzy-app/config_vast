```bash
...existing code...

function install_python_packages() {
    if [ ${#PYTHON_PACKAGES[@]} -gt 0 ]; then
        echo "[INFO] Installing additional Python packages..."
        safe_micromamba_install "${PYTHON_PACKAGES[@]}"
    fi
}

# Add helper to retry micromamba when lockfile present, fallback to pip
function safe_micromamba_install() {
    pkgs=("$@")
    # try micromamba if available
    if command -v micromamba >/dev/null 2>&1; then
        tries=0
        max=6
        wait_s=5
        while [ $tries -lt $max ]; do
            if micromamba -n comfyui run ${PIP_INSTALL} "${pkgs[@]}"; then
                return 0
            fi
            # detect libmamba lock error and retry
            echo "[WARN] micromamba install failed, retrying in ${wait_s}s (try $((tries+1))/$max)..."
            sleep $wait_s
            tries=$((tries+1))
            wait_s=$((wait_s*2))
        done
        echo "[WARN] micromamba failed after retries, falling back to pip in current environment..."
    fi

    # fallback: try pip (best-effort)
    if command -v pip >/dev/null 2>&1; then
        pip install --no-cache-dir "${pkgs[@]}" || true
    else
        echo "[ERROR] pip not available to install packages: ${pkgs[*]}"
    fi
}

# Ensure VAST_TCP_PORT_3000 exists (pyworker expects it when WORKER_PORT=3000)
function ensure_worker_port_env() {
    if [ -z "${VAST_TCP_PORT_3000+x}" ]; then
        # try common existing port envs (18288, 18188, 40440 etc.)
        for candidate in 18288 18188 18288 40440 18188; do
            varname="VAST_TCP_PORT_${candidate}"
            if [ ! -z "${!varname}" ]; then
                echo "[INFO] Setting VAST_TCP_PORT_3000=${!varname} (from ${varname})"
                echo "VAST_TCP_PORT_3000=${!varname}" >> /etc/environment || true
                export VAST_TCP_PORT_3000="${!varname}"
                return 0
            fi
        done
        # last resort: use WORKER_PORT mapping if present
        if [ ! -z "${VAST_TCP_PORT_18288+x}" ]; then
            echo "[INFO] Setting VAST_TCP_PORT_3000=${VAST_TCP_PORT_18288} (fallback)"
            echo "VAST_TCP_PORT_3000=${VAST_TCP_PORT_18288}" >> /etc/environment || true
            export VAST_TCP_PORT_3000="${VAST_TCP_PORT_18288}"
            return 0
        fi
        echo "[WARN] Could not find an existing VAST_TCP_PORT_* to map to VAST_TCP_PORT_3000; pyworker may still fail"
    else
        echo "[INFO] VAST_TCP_PORT_3000 already set"
    fi
}

### Основной запуск ###

function provisioning_start() {
    provisioning_print_header
    create_directories
    ensure_worker_port_env
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
...existing code...
```