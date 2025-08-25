#!/usr/bin/env python3
"""rag_worker.py
Sub-ops:
  index: --root <folder>
  query: --root <folder> --query <text> --topk N
Outputs single JSON line for query: {"op":"done","chunks":[{"text":"...","source":"..."}]}
Index artifacts are stored inside <root>/.intperint_index/{faiss.index,meta.json}
"""
import argparse, json, sys, os, re
from pathlib import Path

IDX_DIR_NAME = '.intperint_index'

TOKEN_SPLIT_RE = re.compile(r'(?<=\.)\s+|\n+')


def build_chunks(text: str, max_chars=800):
    parts = TOKEN_SPLIT_RE.split(text)
    buf = []
    cur = ''
    for p in parts:
        if len(cur) + len(p) + 1 > max_chars:
            if cur.strip():
                buf.append(cur.strip())
            cur = p
        else:
            cur += (' ' if cur else '') + p
    if cur.strip():
        buf.append(cur.strip())
    return buf


def do_index(root: Path):
    try:
        import faiss, numpy as np
        from sentence_transformers import SentenceTransformer
    except Exception as e:
        print(json.dumps({"op":"error","error":f"deps missing: {e}"}))
        return 2
    model = SentenceTransformer('all-MiniLM-L6-v2')

    texts = []
    sources = []
    for path in root.rglob('*'):
        if path.is_dir():
            continue
        if path.suffix.lower() not in {'.txt', '.md'}:
            continue
        try:
            data = path.read_text(errors='ignore')
        except Exception:
            continue
        for chunk in build_chunks(data):
            texts.append(chunk)
            sources.append(str(path.relative_to(root)))
    if not texts:
        print(json.dumps({"op":"error","error":"no texts"}))
        return 3
    embeds = model.encode(texts, convert_to_numpy=True, show_progress_bar=False, batch_size=64, normalize_embeddings=True)
    dim = embeds.shape[1]
    index = faiss.IndexFlatIP(dim)
    index.add(embeds)
    out_dir = root/IDX_DIR_NAME
    out_dir.mkdir(parents=True, exist_ok=True)
    faiss.write_index(index, str(out_dir/'faiss.index'))
    (out_dir/'meta.json').write_text(json.dumps({'sources':sources}, ensure_ascii=False))
    print(json.dumps({"op":"done","chunks_indexed":len(texts)}))
    return 0


def do_query(root: Path, query: str, topk: int):
    try:
        import faiss, numpy as np
        from sentence_transformers import SentenceTransformer
    except Exception as e:
        print(json.dumps({"op":"error","error":f"deps missing: {e}"}))
        return 2
    out_dir = root/IDX_DIR_NAME
    if not (out_dir/'faiss.index').exists():
        print(json.dumps({"op":"error","error":"index not found"}))
        return 4
    index = faiss.read_index(str(out_dir/'faiss.index'))
    meta = json.loads((out_dir/'meta.json').read_text())
    sources = meta['sources']
    model = SentenceTransformer('all-MiniLM-L6-v2')
    q_emb = model.encode([query], convert_to_numpy=True, normalize_embeddings=True)
    D, I = index.search(q_emb, topk)
    chunks = []
    for score, idx in zip(D[0], I[0]):
        if idx < 0 or idx >= len(sources):
            continue
        # For brevity, we don't keep original chunk text separately; re-load file (inefficient but acceptable for prototype)
        rel = sources[idx]
        file_path = root/rel
        try:
            snippet = file_path.read_text(errors='ignore')[:400].replace('\n',' ')
        except Exception:
            snippet = ''
        chunks.append({'text': snippet, 'source': rel, 'score': float(score)})
    print(json.dumps({"op":"done","chunks":chunks}))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('subop', choices=['index','query'])
    ap.add_argument('--root', required=True)
    ap.add_argument('--query')
    ap.add_argument('--topk', type=int, default=5)
    args = ap.parse_args()
    root = Path(os.path.expanduser(args.root))
    if not root.exists():
        print(json.dumps({"op":"error","error":"root missing"}))
        return 1
    if args.subop == 'index':
        return do_index(root)
    else:
        if not args.query:
            print(json.dumps({"op":"error","error":"query missing"}))
            return 1
        return do_query(root, args.query, args.topk)

if __name__ == '__main__':
    raise SystemExit(main())
