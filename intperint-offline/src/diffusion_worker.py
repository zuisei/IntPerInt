import os
import sys
import time
import logging
from pathlib import Path
from typing import Dict, Any, List

from .job_queue import JobQueue
from .utils import set_offline_env_defaults, ensure_dir, write_json

set_offline_env_defaults()

LOG_PATH = Path(__file__).resolve().parent.parent / "logs" / "diffusion_worker.log"
logging.basicConfig(level=logging.INFO, handlers=[logging.FileHandler(LOG_PATH), logging.StreamHandler(sys.stdout)])
logger = logging.getLogger("diffusion")

BASE_DIR = Path(__file__).resolve().parent.parent
OUT_IMG = BASE_DIR / "outputs" / "image"
OUT_VID = BASE_DIR / "outputs" / "video"
UPLOADS = BASE_DIR / "uploads"

SDXL_DIR = os.environ.get("SDXL_MODEL_DIR", str((BASE_DIR / "models" / "sdxl").resolve()))
ANIM_MOTION = os.environ.get("ANIM_MOTION", str((BASE_DIR / "models" / "animatediff_motion").resolve()))

# Torch will be provided via wheels offline. Use MPS if available.

try:
    import torch  # type: ignore
    from diffusers import DiffusionPipeline  # type: ignore
except Exception:
    torch = None
    DiffusionPipeline = None


def txt2img(prompt: str, out_dir: Path, steps: int = 20, seed: int = 42) -> List[str]:
    out_dir = ensure_dir(out_dir)
    if torch is None or DiffusionPipeline is None or not Path(SDXL_DIR).exists():
        # Mock mode: generate empty placeholder files
        paths = []
        for i in range(1):
            p = out_dir / f"mock_{int(time.time())}.png"
            with open(p, "wb") as f:
                f.write(b"PNG\n")
            paths.append(str(p))
        return paths

    torch.backends.mps.allow_tf32 = True if hasattr(torch.backends, "mps") else False
    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")

    pipe = DiffusionPipeline.from_pretrained(
        SDXL_DIR,
        torch_dtype=torch.float16 if device.type == "mps" else torch.float32,
        use_safetensors=True,
        local_files_only=True,
    )
    pipe = pipe.to(device)
    image = pipe(prompt, num_inference_steps=steps, generator=torch.Generator(device=device).manual_seed(seed)).images[0]
    out_path = out_dir / f"sdxl_{int(time.time())}.png"
    image.save(out_path)
    return [str(out_path)]


def generate_video_frames(prompt: str, out_frames_dir: Path, num_frames: int = 8) -> List[str]:
    out_frames_dir = ensure_dir(out_frames_dir)
    paths = []
    # If motion adapter exists, in real use you'd integrate AnimatedDiff here.
    # Offline fallback: generate a sequence of placeholder frames.
    for i in range(num_frames):
        p = out_frames_dir / f"frame_{i:04d}.png"
        with open(p, "wb") as f:
            f.write(b"PNG\n")
        paths.append(str(p))
    return paths


def main_loop():
    jq = JobQueue()
    logger.info("Diffusion worker started (offline)")
    while True:
        job = jq.dequeue()
        if not job:
            time.sleep(0.2)
            continue
        jid, type_, payload = job
        try:
            if type_ == "generate_image":
                prompt = payload.get("prompt", "")
                out_dir = OUT_IMG / jid
                paths = txt2img(prompt, out_dir)
                jq.set_result(jid, "done", {"images": paths})
            elif type_ == "generate_video":
                prompt = payload.get("prompt", "")
                frames_dir = OUT_VID / jid / "frames"
                frames = generate_video_frames(prompt, frames_dir)
                # ffmpeg example (offline, optional):
                ffmpeg_cmd = f"ffmpeg -framerate 8 -i {frames_dir}/frame_%04d.png -c:v libx264 -pix_fmt yuv420p {OUT_VID / (jid + '.mp4')}"
                jq.set_result(jid, "done", {"frames": frames, "ffmpeg_example": ffmpeg_cmd})
            else:
                jq.set_result(jid, "error", {"error": "invalid_type"})
        except Exception as e:
            jq.set_result(jid, "error", {"error": str(e)})


if __name__ == "__main__":
    main_loop()
