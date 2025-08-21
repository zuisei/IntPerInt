#!/usr/bin/env python3
import json
from pathlib import Path
from src.utils import LocalOnlySession

s = LocalOnlySession()

# draft text generation
r = s.post("http://127.0.0.1:8000/generate_text", json={"prompt": "Hello offline world", "mode": "draft"})
print("/generate_text draft:", r.json())

# analyze_image (requires API server running, uploads mock)
img_path = Path("uploads/mock.png")
img_path.parent.mkdir(parents=True, exist_ok=True)
img_path.write_bytes(b"PNG\n")
with img_path.open("rb") as f:
    r2 = s.post("http://127.0.0.1:8000/analyze_image", files={"file": ("mock.png", f, "image/png")})
    print("/analyze_image:", r2.json())
