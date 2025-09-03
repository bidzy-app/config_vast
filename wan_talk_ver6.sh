```bash
...existing code...

CUSTOM_NODES=(
    "https://github.com/kijai/ComfyUI-WanVideoWrapper"
    "https://github.com/kijai/ComfyUI-KJNodes"
    "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite"
    "https://github.com/christian-byrne/audio-separation-nodes-comfyui"
)

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

# массив для найденных requirements
NODE_REQUIREMENTS=()

# restore/install custom nodes function (clone + install requirements)
function install_custom_nodes() {
    # ensure target dir exists
    mkdir -p /workspace/ComfyUI/custom_nodes
    cd /workspace/ComfyUI/custom_nodes
    for repo in "${CUSTOM_NODES[@]}"; do
        local dir="${repo##*/}"
        if [[ "$dir" == *.git ]]; then
            dir="${dir%.git}"
        fi
        if [ ! -d "$dir" ]; then
            echo "[INFO] Cloning node: $repo"
            git clone "$repo" "$dir" --depth 1 || git clone "$repo" "$dir"
        else
            echo "[INFO] Node already exists: $dir"
            if [[ ${AUTO_UPDATE,,} != "false" ]]; then
                echo "[INFO] Updating node: $dir"
                ( cd "$dir" && git pull --quiet ) || true
            fi
        fi

        # check for requirements after clone/update
        req_path="$dir/requirements.txt"
        if [ -f "$req_path" ]; then
            echo "[INFO] Found requirements for node $dir -> $req_path"
            NODE_REQUIREMENTS+=("$req_path")
            # attempt to install using micromamba if available, else pip
            if command -v micromamba >/dev/null 2>&1; then
                micromamba -n comfyui run pip install -r "$req_path" || true
            else
                pip install -r "$req_path" || true
            fi
        else
            echo "[INFO] No requirements.txt for node $dir"
        fi
    done
}

# create combined requirements file and print summary
function summarize_node_requirements() {
    combined="/workspace/ComfyUI/combined-requirements.txt"
    : > "$combined"
    if [ ${#NODE_REQUIREMENTS[@]} -eq 0 ]; then
        echo "[INFO] No node requirements found."
        return 0
    fi
    echo "[INFO] Aggregating ${#NODE_REQUIREMENTS[@]} requirements files to $combined"
    for r in "${NODE_REQUIREMENTS[@]}"; do
        echo "# --- from: $r ---" >> "$combined"
        wc -l "$r" 2>/dev/null | awk '{print "[LINES] "$1" "$2}' >> /workspace/ComfyUI/requirements_summary.txt || true
        sed -n '1,200p' "$r" >> "$combined"   # limit to first 200 lines per file for safety
        echo "" >> "$combined"
    done
    echo "[INFO] Combined requirements saved to: $combined"
    echo "[INFO] To review: cat $combined"
}

### Основной запуск ###

function provisioning_start() {
    provisioning_print_header
    create_directories
    ensure_worker_port_env
    install_python_packages
    install_custom_nodes          # <-- установка нод перед скачиванием моделей
    summarize_node_requirements   # <-- сводка по requirements нод
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