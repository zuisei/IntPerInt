#!/usr/bin/env python3
# run_sd_diffusers.py – SDXL via diffusers (local model_dir)
import argparse, os, sys, random, json
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
    ap.add_argument('--model_dir', required=True)
    ap.add_argument('--prompt', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--steps', type=int, default=20)
    ap.add_argument('--width', type=int, default=768)
    ap.add_argument('--height', type=int, default=768)
    ap.add_argument('--device', default='mps', choices=['mps','cpu','cuda'])
    ap.add_argument('--seed', type=int, default=None)
    ap.add_argument('--guidance_scale', type=float, default=7.5)
    args = ap.parse_args()

    out_p = Path(args.out); out_p.parent.mkdir(parents=True, exist_ok=True)
    seed = args.seed if args.seed is not None else random.randint(1, 2**31-1)

    try:
        import torch
        from diffusers import DiffusionPipeline
    except Exception as e:
        print("Missing dependency:", e, file=sys.stderr); return 2

    device = choose_torch_device(args.device)
    print(f"[sd] device={device} seed={seed}")

    try:
        pipe = DiffusionPipeline.from_pretrained(args.model_dir)
    except Exception as e:
        print("Failed to load pipeline:", e, file=sys.stderr); return 3

    try:
        pipe = pipe.to(device)
    except Exception as e:
        print("Warn: move to device failed:", e)

    gen = torch.Generator(device if device!='cpu' else 'cpu').manual_seed(seed)

    try:
        img = pipe(prompt=args.prompt,
                   num_inference_steps=args.steps,
                   guidance_scale=args.guidance_scale,
                   generator=gen,
                   width=args.width,
                   height=args.height).images[0]
        img.save(str(out_p))
        print(json.dumps({"status":"ok","out":str(out_p),"seed":seed}))
        return 0
    except Exception as e:
        print("Generation failed:", e, file=sys.stderr); return 4

if __name__ == '__main__':
    raise SystemExit(main())
