import os
import sys
import logging
from pathlib import Path
from typing import Dict, Any, Optional

from fastapi import FastAPI, UploadFile, File
from pydantic import BaseModel
import uvicorn

from .job_queue import JobQueue
from .utils import set_offline_env_defaults, ensure_dir, LocalOnlySession

set_offline_env_defaults()

LOG_PATH = Path(__file__).resolve().parent.parent / "logs" / "api_server.log"
logging.basicConfig(level=logging.INFO, handlers=[logging.FileHandler(LOG_PATH), logging.StreamHandler(sys.stdout)])
logger = logging.getLogger("api")

BASE_DIR = Path(__file__).resolve().parent.parent
UPLOADS = ensure_dir(BASE_DIR / "uploads")

app = FastAPI(title="intperint-offline API", version="0.1.0")
jq = JobQueue()
local_http = LocalOnlySession()


class GenTextRequest(BaseModel):
    prompt: str
    mode: str = "draft"  # draft -> 20B microservice, heavy -> 67B job
    max_tokens: int = 256

class GenImageRequest(BaseModel):
    prompt: str
    params: Dict[str, Any] = {}

class GenVideoRequest(BaseModel):
    prompt: str
    params: Dict[str, Any] = {}


@app.post("/generate_text")
async def generate_text(req: GenTextRequest):
    if req.mode == "draft":
        # Call 20B microservice locally
        try:
            r = local_http.post("http://127.0.0.1:8001/gen", json={"prompt": req.prompt, "max_tokens": req.max_tokens})
            r.raise_for_status()
            return r.json()
        except Exception as e:
            return {"text": f"[MOCK draft] {req.prompt[:64]}...", "note": str(e)}
    elif req.mode == "heavy":
        jid = jq.enqueue("generate_text_heavy", {"prompt": req.prompt, "max_tokens": req.max_tokens})
        return {"job_id": jid}
    else:
        return {"error": "invalid_mode"}


@app.post("/generate_image")
async def generate_image(req: GenImageRequest):
    jid = jq.enqueue("generate_image", {"prompt": req.prompt, "params": req.params})
    return {"job_id": jid}


@app.post("/generate_video")
async def generate_video(req: GenVideoRequest):
    jid = jq.enqueue("generate_video", {"prompt": req.prompt, "params": req.params})
    return {"job_id": jid}


@app.post("/analyze_image")
async def analyze_image(file: UploadFile = File(...)):
    # Save file locally and call local function in-process to avoid HTTP
    data = await file.read()
    dst = UPLOADS / file.filename
    with open(dst, "wb") as f:
        f.write(data)
    # Import locally to avoid importing if unused
    from .vlm_worker import analyze_image as vlm_analyze
    res = vlm_analyze(str(dst))
    return res


@app.get("/job_status/{job_id}")
async def job_status(job_id: str):
    return jq.status(job_id)


@app.post("/cancel_job/{job_id}")
async def cancel_job(job_id: str):
    ok = jq.cancel(job_id)
    return {"ok": ok}


if __name__ == "__main__":
    uvicorn.run("src.api_server:app", host="127.0.0.1", port=8000, reload=False, access_log=False)
