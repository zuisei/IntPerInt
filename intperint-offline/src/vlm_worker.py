import os
import sys
import time
import json
import logging
from pathlib import Path
from typing import Dict, Any

from .utils import set_offline_env_defaults, ensure_dir, write_json

set_offline_env_defaults()

LOG_PATH = Path(__file__).resolve().parent.parent / "logs" / "vlm_worker.log"
logging.basicConfig(level=logging.INFO, handlers=[logging.FileHandler(LOG_PATH), logging.StreamHandler(sys.stdout)])
logger = logging.getLogger("vlm")

BASE_DIR = Path(__file__).resolve().parent.parent
OUT_DIR = BASE_DIR / "outputs" / "vlm"
MODEL_DIR = os.environ.get("LLAVA_DIR", str((BASE_DIR / "models" / "llava").resolve()))

try:
    from transformers import AutoProcessor  # type: ignore
    HAVE_TFM = True
except Exception:
    HAVE_TFM = False


def analyze_image(path: str) -> Dict[str, Any]:
    p = Path(path)
    if not p.exists():
        raise FileNotFoundError(path)

    # Real VLM loading would go here with local_files_only=True
    if HAVE_TFM and Path(MODEL_DIR).exists():
        # Placeholder logic: we are offline, so avoid real model calls.
        caption = f"A plausible description of {p.name} (offline placeholder)"
        objects = ["object1", "object2"]
        ocr_text = ""
    else:
        # Mock mode
        caption = f"[MOCK VLM] A mock caption for {p.name}"
        objects = ["mock-object"]
        ocr_text = "mock-ocr"

    return {"caption": caption, "objects": objects, "ocr_text": ocr_text}


if __name__ == "__main__":
    ensure_dir(OUT_DIR)
    sample = analyze_image(str(BASE_DIR / "uploads" / "sample.png"))
    write_json(OUT_DIR / "sample.json", sample)
