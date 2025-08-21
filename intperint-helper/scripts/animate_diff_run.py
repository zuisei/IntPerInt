#!/usr/bin/env python3
# animate_diff_run.py – simple video maker via img2img frames + ffmpeg
import argparse, os, sys, shutil, json, random
from pathlib import Path

def choose_torch_device(prefer: str):
    import torch
    if prefer == "mps" and getattr(torch.backends, "mps", None) is not None and torch.backends.mps.is_available():
        return "mps"
    if torch.cuda.is_available():
        return "cuda"
    return "cpu"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--init', required=True)
    ap.add_argument('--prompt', required=True)
    ap.add_argument('--motion', default=None)
    ap.add_argument('--frames', type=int, default=16)
    ap.add_argument('--out', required=True)
    ap.add_argument('--model_dir', required=True)
    ap.add_argument('--device', default='mps', choices=['mps','cpu','cuda'])
    ap.add_argument('--steps', type=int, default=20)
    ap.add_argument('--strength', type=float, default=0.6)
    ap.add_argument('--seed', type=int, default=None)
    args = ap.parse_args()

    tmpdir = Path('/tmp/intperint_anim_frames')
    if tmpdir.exists():
        shutil.rmtree(tmpdir)
    tmpdir.mkdir(parents=True, exist_ok=True)

    out_p = Path(args.out); out_p.parent.mkdir(parents=True, exist_ok=True)
    seed = args.seed if args.seed is not None else random.randint(1,2**31-1)

    try:
        import torch
        from diffusers import StableDiffusionImg2ImgPipeline, DiffusionPipeline
        from PIL import Image
    except Exception as e:
        print('Missing deps:', e, file=sys.stderr); return 2

    device = choose_torch_device(args.device)
    print(f"[anim] device={device} frames={args.frames} seed={seed}")

    pipe = None
    try:
        pipe = StableDiffusionImg2ImgPipeline.from_pretrained(args.model_dir)
    except Exception:
        pipe = DiffusionPipeline.from_pretrained(args.model_dir)

    try:
        pipe = pipe.to(device)
    except Exception as e:
        print('Warn: move to device failed:', e)

    img0 = Image.open(args.init).convert('RGB')
    for i in range(args.frames):
        gen = torch.Generator(device if device!='cpu' else 'cpu').manual_seed(seed + i)
        prompt_i = f"{args.prompt} frame {i}"
        try:
            out_img = pipe(prompt=prompt_i, image=img0, strength=args.strength, num_inference_steps=args.steps, generator=gen).images[0]
        except Exception:
            out_img = pipe(prompt=prompt_i, num_inference_steps=args.steps, generator=gen).images[0]
        frame_path = tmpdir / f"frame_{i:04d}.png"
        out_img.save(str(frame_path))
        print('wrote', frame_path)

    ffmpeg = f'ffmpeg -y -framerate 12 -i "{tmpdir}/frame_%04d.png" -c:v libx264 -pix_fmt yuv420p "{out_p}"'
    rc = os.system(ffmpeg)
    if rc != 0:
        print('ffmpeg failed rc', rc, file=sys.stderr); return 5
    print(json.dumps({"status":"ok","out":str(out_p)}))
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
