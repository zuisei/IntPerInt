#!/usr/bin/env bash
set -euo pipefail

# Enforce offline for HF ecosystem
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export DIFFUSERS_OFFLINE=1
export HF_DATASETS_OFFLINE=1
export HF_HOME="$(pwd)/.hf_home"
export NO_PROXY=127.0.0.1,localhost
export no_proxy=127.0.0.1,localhost

# Model placeholders (replace paths to your local models)
export LLM20_MODEL="{{MODEL_PATH_W8KXL_20B}}"
export LLM20_THREADS="8"
export LLM20_NGL="35"
export LLM20_CTX="4096"

export DEEPSEEK67_MODEL="{{MODEL_PATH_DEEPSEEK_67B}}"
export LLM67_THREADS="8"
export LLM67_NGL="35"
export LLM67_CTX="4096"

export SDXL_MODEL_DIR="{{SDXL_MODEL_DIR}}"
export ANIM_MOTION="{{ANIMATEDIFF_MOTION}}"
export LLAVA_DIR="{{LLAVA_MODEL_DIR}}"
