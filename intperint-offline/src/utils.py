import hashlib
import json
import os
import shlex
import subprocess
import threading
import time
from pathlib import Path
from typing import Any, Dict, Optional

LOG_DIR = Path(__file__).resolve().parent.parent / "logs"
BASE_DIR = Path(__file__).resolve().parent.parent
OUTPUTS_DIR = BASE_DIR / "outputs"

for d in [LOG_DIR, OUTPUTS_DIR / "text", OUTPUTS_DIR / "image", OUTPUTS_DIR / "video"]:
    d.mkdir(parents=True, exist_ok=True)


def ensure_dir(path: Path | str) -> Path:
    p = Path(path)
    p.mkdir(parents=True, exist_ok=True)
    return p


def safe_file_write(path: Path | str, data: bytes, mode: str = "wb") -> None:
    p = Path(path)
    ensure_dir(p.parent)
    tmp = p.with_suffix(p.suffix + ".tmp")
    with open(tmp, mode) as f:
        f.write(data)
    os.replace(tmp, p)


def checksum_file(path: Path | str, algo: str = "sha256", chunk_size: int = 1024 * 1024) -> str:
    h = hashlib.new(algo)
    with open(path, "rb") as f:
        while True:
            chunk = f.read(chunk_size)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def checksum_verify(file_path: Path | str, expected_hex: str, algo: str = "sha256") -> bool:
    return checksum_file(file_path, algo) == expected_hex.lower()


def write_json(path: Path | str, obj: Any) -> None:
    data = json.dumps(obj, ensure_ascii=False, indent=2).encode("utf-8")
    safe_file_write(path, data)


def read_json(path: Path | str) -> Any:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def run_cmd_with_timeout(cmd: list[str] | str, timeout: int = 300, cwd: Optional[str] = None) -> tuple[int, str, str]:
    if isinstance(cmd, str):
        cmd_list = shlex.split(cmd)
    else:
        cmd_list = cmd
    proc = subprocess.Popen(cmd_list, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    timer = threading.Timer(timeout, proc.kill)
    try:
        timer.start()
        out, err = proc.communicate()
        return proc.returncode, out, err
    finally:
        timer.cancel()


class LocalOnlySession:
    """Very small guard to avoid accidental external HTTP calls.
    Only allows http://127.0.0.1 or http://localhost requests via requests.
    """
    def __init__(self):
        import requests
        self._s = requests.Session()

    def post(self, url: str, *args, **kwargs):
        if not (url.startswith("http://127.0.0.1") or url.startswith("http://localhost")):
            raise RuntimeError("External HTTP is forbidden in offline mode")
        return self._s.post(url, *args, **kwargs)

    def get(self, url: str, *args, **kwargs):
        if not (url.startswith("http://127.0.0.1") or url.startswith("http://localhost")):
            raise RuntimeError("External HTTP is forbidden in offline mode")
        return self._s.get(url, *args, **kwargs)


def set_offline_env_defaults():
    # Enforce offline for huggingface ecosystem
    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
    os.environ.setdefault("DIFFUSERS_OFFLINE", "1")
    os.environ.setdefault("HF_DATASETS_OFFLINE", "1")
    os.environ.setdefault("HF_HOME", str((BASE_DIR / ".hf_home").resolve()))
    # No proxies except local
    os.environ.setdefault("NO_PROXY", "127.0.0.1,localhost")
    os.environ.setdefault("no_proxy", "127.0.0.1,localhost")


def now_ts() -> float:
    return time.time()
