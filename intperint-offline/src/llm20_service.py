import os
import sys
import logging
from pathlib import Path
from typing import Optional
from fastapi import FastAPI
from pydantic import BaseModel

from .utils import set_offline_env_defaults

set_offline_env_defaults()

LOG_PATH = Path(__file__).resolve().parent.parent / "logs" / "llm20_service.log"
logging.basicConfig(level=logging.INFO, handlers=[logging.FileHandler(LOG_PATH), logging.StreamHandler(sys.stdout)])
logger = logging.getLogger("llm20")

app = FastAPI(title="LLM20 Service", version="0.1.0")

class GenRequest(BaseModel):
    prompt: str
    max_tokens: int = 256
    temperature: float = 0.7

class GenResponse(BaseModel):
    text: str

LLM = None
MODEL_PATH = os.environ.get("LLM20_MODEL", str((Path(__file__).resolve().parent.parent / "models" / "w8kxl-20b.gguf").resolve()))
THREADS = int(os.environ.get("LLM20_THREADS", "6"))
NGL = int(os.environ.get("LLM20_NGL", "35"))
CTX = int(os.environ.get("LLM20_CTX", "4096"))

try:
    from llama_cpp import Llama
    if Path(MODEL_PATH).exists():
        # Example llama.cpp python usage
        LLM = Llama(
            model_path=MODEL_PATH,
            n_ctx=CTX,
            n_threads=THREADS,
            n_gpu_layers=NGL,
            embedding=False,
            chat_format=None,
            verbose=False,
        )
        logger.info(f"Loaded GGUF model at {MODEL_PATH}")
    else:
        logger.warning(f"MODEL not found at {MODEL_PATH}. Using mock mode.")
except Exception as e:
    logger.warning(f"llama-cpp-python not available or failed: {e}. Using mock mode.")

@app.post("/gen", response_model=GenResponse)
async def gen(req: GenRequest):
    prompt = req.prompt
    if LLM is None:
        # mock fallback
        return GenResponse(text=f"[MOCK LLM20] {prompt[:64]}...")

    out = LLM(prompt, temperature=req.temperature, max_tokens=req.max_tokens, stop=["</s>"])
    if isinstance(out, dict):
        text = out.get("choices", [{}])[0].get("text", "")
    else:
        text = str(out)
    return GenResponse(text=text)

"""
Alternative: llama.cpp CLI (commented example)

# CLI example (not used in service):
# ./llama.cpp/bin/main -m ${LLM20_MODEL} -p "${PROMPT}" -n 256 -ngl ${LLM20_NGL} -c ${LLM20_CTX}
"""
