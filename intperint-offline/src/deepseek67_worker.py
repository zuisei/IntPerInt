import os
import sys
import time
import json
import logging
from pathlib import Path
from typing import Dict, Any

from .job_queue import JobQueue
from .utils import set_offline_env_defaults, write_json, ensure_dir, run_cmd_with_timeout

set_offline_env_defaults()

LOG_PATH = Path(__file__).resolve().parent.parent / "logs" / "deepseek67_worker.log"
logging.basicConfig(level=logging.INFO, handlers=[logging.FileHandler(LOG_PATH), logging.StreamHandler(sys.stdout)])
logger = logging.getLogger("deepseek67")

BASE_DIR = Path(__file__).resolve().parent.parent
OUT_DIR = BASE_DIR / "outputs" / "text"

MODEL = os.environ.get("DEEPSEEK67_MODEL", str((BASE_DIR / "models" / "deepseek-67b.gguf").resolve()))
NGL = int(os.environ.get("LLM67_NGL", "35"))
CTX = int(os.environ.get("LLM67_CTX", "4096"))
THREADS = int(os.environ.get("LLM67_THREADS", "8"))

LLAMA_CPP_MAIN = str((BASE_DIR / "llama.cpp" / "bin" / "main").resolve())


def process_job(jid: str, payload: Dict[str, Any]) -> Dict[str, Any]:
    prompt = payload.get("prompt", "")
    # Prefer llama.cpp CLI if exists
    if Path(LLAMA_CPP_MAIN).exists() and Path(MODEL).exists():
        cmd = [
            LLAMA_CPP_MAIN,
            "-m", MODEL,
            "-p", prompt,
            "-n", str(payload.get("max_tokens", 256)),
            "-ngl", str(NGL),
            "-c", str(CTX),
            "-t", str(THREADS),
        ]
        code, out, err = run_cmd_with_timeout(cmd, timeout=payload.get("timeout", 600), cwd=str(BASE_DIR))
        logger.info(f"llama.cpp exited code={code}")
        if code == 0:
            return {"text": out.strip()}
        else:
            logger.warning(f"llama.cpp failed, fallback to llama-cpp-python mock: {err}")

    # Fallback: python mock (offline)
    try:
        from llama_cpp import Llama
        if Path(MODEL).exists():
            llm = Llama(model_path=MODEL, n_ctx=CTX, n_threads=THREADS, n_gpu_layers=NGL)
            res = llm(prompt, max_tokens=payload.get("max_tokens", 256))
            text = res.get("choices", [{}])[0].get("text", "") if isinstance(res, dict) else str(res)
        else:
            text = f"[MOCK 67B] {prompt[:64]}..."
    except Exception:
        text = f"[MOCK 67B] {prompt[:64]}..."
    return {"text": text}


def main_loop():
    jq = JobQueue()
    ensure_dir(OUT_DIR)
    logger.info("DeepSeek67 worker started (offline)")
    while True:
        item = jq.dequeue()
        if not item:
            time.sleep(0.2)
            continue
        jid, type_, payload = item
        if type_ != "generate_text_heavy":
            jq.set_result(jid, "error", {"error": "invalid_type"})
            continue
        try:
            result = process_job(jid, payload)
            out_path = OUT_DIR / f"{jid}.json"
            write_json(out_path, {"job_id": jid, "result": result})
            jq.set_result(jid, "done", result)
        except Exception as e:
            jq.set_result(jid, "error", {"error": str(e)})


if __name__ == "__main__":
    main_loop()
