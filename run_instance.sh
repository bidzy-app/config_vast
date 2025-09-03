#!/bin/bash
set -e

vastai create instance 25475069 \
  --image ghcr.io/ai-dock/comfyui:latest-jupyter \
  --env '-p 3000:3000 -p 18288:18288 -e COMFY_MODEL="wan_talk" -e HF_TOKEN="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" -e DATA_DIRECTORY=/workspace/ -e WORKSPACE=/workspace/ -e WORKSPACE_MOUNTED=force -e JUPYTER_DIR=/ -e COMFYUI_BRANCH=master -e WEB_USER=user -e WEB_PASSWORD=password -e PROVISIONING_SCRIPT="https://raw.githubusercontent.com/bidzy-app/config_vast/main/wan_talk.sh" -e BACKEND=comfyui -e WEB_ENABLE_AUTH=false -e MODEL_LOG=/var/log/logtail.log' \
  --onstart-cmd 'env | grep _ >> /etc/environment && wget -O - "https://raw.githubusercontent.com/vast-ai/pyworker/main/start_server.sh" | bash && (/opt/ai-dock/bin/init.sh &> /dev/null) && cd /opt/ComfyUI && python main.py --listen --port 18288 --enable-api &' \
  --disk 32 \
  --jupyter \
  --ssh \
  --direct
