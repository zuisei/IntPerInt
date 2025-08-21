# intperint-offline

Fully offline multimodal AI stack for macOS (Apple Silicon), no external network access at runtime.

## Hard constraints
- No external HTTP. Only localhost calls between components.
- Models are local-only. Use placeholders under `models/`.
- Always set offline env: HF_HUB_OFFLINE=1, TRANSFORMERS_OFFLINE=1, DIFFUSERS_OFFLINE=1, HF_DATASETS_OFFLINE=1.
- LLM: Use GGUF with llama.cpp or llama-cpp-python (examples provided as comments).
- Diffusion/Video: `diffusers` + PyTorch MPS; load with `local_files_only=True`.
- Provide install/start/stop/checksum scripts. Tests run offline with mocks.

## Layout
```
intperint-offline/
  scripts/ (env, install, start/stop, verify)
  src/ (api_server, llm20_service, deepseek67_worker, diffusion_worker, vlm_worker, job_queue, utils)
  tests/ (pytest offline with mocks)
  ci/ (template)
  outputs/, logs/, models/, wheels/, uploads/
```

## Prepare (you do this)
1. Put your local models under `models/` and wheels under `wheels/`.
2. Edit `scripts/env_offline.sh` to set placeholders:
   - `LLM20_MODEL={{MODEL_PATH_W8KXL_20B}}`
   - `DEEPSEEK67_MODEL={{MODEL_PATH_DEEPSEEK_67B}}`
   - `SDXL_MODEL_DIR={{SDXL_MODEL_DIR}}`
   - `ANIM_MOTION={{ANIMATEDIFF_MOTION}}`
   - `LLAVA_DIR={{LLAVA_MODEL_DIR}}`
3. (Optional) Place `checksums/models.sha256` to verify.

## Offline install
```bash
bash scripts/install_offline.sh
```

## Start (localhost only)
```bash
bash scripts/start_all_offline.sh
```
- API: 127.0.0.1:8000
- LLM20 service: 127.0.0.1:8001

## Try it
```bash
# Draft text (goes to LLM20 service, mocked if model missing)
python client_example.py
```

## Stop
```bash
bash scripts/stop_all_offline.sh
```

## Verify outbound is zero
```bash
lsof -i -n | grep ESTABLISHED || true
netstat -an | grep -E "ESTABLISHED|LISTEN" | grep -v -E "127.0.0.1|::1"
```

## Notes
- All model loads use `local_files_only=True` or mock fallback. No downloads.
- If you prefer CLI llama.cpp: edit `src/deepseek67_worker.py` comment and ensure `llama.cpp/bin/main` exists.
- Tests are offline, mocking heavy deps.
