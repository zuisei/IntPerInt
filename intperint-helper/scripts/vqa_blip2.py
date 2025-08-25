#!/usr/bin/env python3
"""vqa_blip2.py - Very small BLIP-2 VQA runner.
Outputs single JSON line: {"op":"done","answer":"..."}
If model weights not present offline, it will attempt to download (user must allow network).
"""
import argparse, json, sys
from pathlib import Path

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--image', required=True)
    ap.add_argument('--question', required=True)
    ap.add_argument('--model_dir', required=False, help='Optional local cache path')
    args = ap.parse_args()
    img_path = Path(args.image)
    if not img_path.exists():
        print(json.dumps({"op":"error","error":"image not found"}))
        return 2
    try:
        from PIL import Image
        import torch
        from transformers import Blip2Processor, Blip2ForConditionalGeneration
    except Exception as e:
        print(json.dumps({"op":"error","error":f"deps missing: {e}"}))
        return 3

    device = 'cuda' if torch.cuda.is_available() else ('mps' if torch.backends.mps.is_available() else 'cpu')
    model_name = 'Salesforce/blip2-flan-t5-xl'
    try:
        processor = Blip2Processor.from_pretrained(model_name, cache_dir=args.model_dir)
        model = Blip2ForConditionalGeneration.from_pretrained(model_name, device_map=None, torch_dtype=torch.float16 if device!='cpu' else torch.float32, cache_dir=args.model_dir)
        if device=='mps':
            model.to('mps')
    except Exception as e:
        print(json.dumps({"op":"error","error":f"load failed: {e}"}))
        return 4

    image = Image.open(str(img_path)).convert('RGB')
    q = args.question.strip()
    inputs = processor(images=image, text=q, return_tensors='pt')
    if device!='cpu':
        inputs = {k:v.to(device) for k,v in inputs.items()}
    with torch.no_grad():
        out = model.generate(**inputs, max_new_tokens=64)
    ans = processor.tokenizer.decode(out[0], skip_special_tokens=True)
    print(json.dumps({"op":"done","answer":ans}))
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
