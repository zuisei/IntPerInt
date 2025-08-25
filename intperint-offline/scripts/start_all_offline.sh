#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/env_offline.sh || true
source .venv/bin/activate
mkdir -p logs

# Start services in background, localhost only
# LLM20 microservice (port 8001)
nohup python -m uvicorn src.llm20_service:app --host 127.0.0.1 --port 8001 --reload=false --access-log=false > logs/llm20.out 2>&1 & echo $! > logs/llm20.pid

# Heavy worker (DeepSeek 67B)
nohup python src/deepseek67_worker.py > logs/deepseek67.out 2>&1 & echo $! > logs/deepseek67.pid

# Diffusion worker
nohup python src/diffusion_worker.py > logs/diffusion.out 2>&1 & echo $! > logs/diffusion.pid

# Orchestrator API (port 8000)
nohup python -m uvicorn src.api_server:app --host 127.0.0.1 --port 8000 --reload=false --access-log=false > logs/api.out 2>&1 & echo $! > logs/api.pid

echo "All offline services started."
