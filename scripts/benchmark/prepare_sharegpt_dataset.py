#!/usr/bin/env python3
"""
Prepare a ShareGPT-style dataset into benchmark-ready JSONL rows.

Output format:
  {"prompt": "<user prompt text>"}

Supports input records with either:
  - "conversations": [{"from":"human"/"user", "value":"..."}, ...]
  - "messages": [{"role":"user", "content":"..."}, ...]
  - "prompt": "..."

Usage examples:
  python scripts/benchmark/prepare_sharegpt_dataset.py \
    --input /path/to/sharegpt.json \
    --output configs/data/sharegpt_prompts_5k.jsonl \
    --max-samples 5000
"""

import argparse
import json
import random
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional


def load_records(path: Path) -> List[Dict[str, Any]]:
    text = path.read_text(encoding="utf-8").strip()
    if not text:
        return []

    if path.suffix.lower() == ".jsonl":
        out: List[Dict[str, Any]] = []
        for line in text.splitlines():
            line = line.strip()
            if not line:
                continue
            out.append(json.loads(line))
        return out

    data = json.loads(text)
    if isinstance(data, list):
        return [x for x in data if isinstance(x, dict)]
    if isinstance(data, dict):
        if isinstance(data.get("data"), list):
            return [x for x in data["data"] if isinstance(x, dict)]
        return [data]
    return []


def extract_prompt(rec: Dict[str, Any]) -> Optional[str]:
    direct = rec.get("prompt")
    if isinstance(direct, str) and direct.strip():
        return direct.strip()

    # Common instruction-tuning schema (e.g., Dolly-like records).
    instruction = rec.get("instruction")
    context = rec.get("context", rec.get("input"))
    if isinstance(instruction, str) and instruction.strip():
        if isinstance(context, str) and context.strip():
            return f"{instruction.strip()}\n\n{context.strip()}"
        return instruction.strip()

    conv = rec.get("conversations")
    if isinstance(conv, list):
        for turn in conv:
            if not isinstance(turn, dict):
                continue
            speaker = str(turn.get("from", "")).strip().lower()
            if speaker in {"human", "user"}:
                value = turn.get("value")
                if isinstance(value, str) and value.strip():
                    return value.strip()

    msgs = rec.get("messages")
    if isinstance(msgs, list):
        for msg in msgs:
            if not isinstance(msg, dict):
                continue
            role = str(msg.get("role", "")).strip().lower()
            if role == "user":
                content = msg.get("content")
                if isinstance(content, str) and content.strip():
                    return content.strip()

    return None


def token_estimate(text: str) -> int:
    return max(1, int(len(text.split()) * 1.33))


def filter_prompts(
    prompts: Iterable[str],
    min_tokens: int,
    max_tokens: int,
) -> List[str]:
    out: List[str] = []
    seen = set()
    for p in prompts:
        norm = " ".join(p.split())
        if not norm:
            continue
        if norm in seen:
            continue
        t = token_estimate(norm)
        if t < min_tokens or t > max_tokens:
            continue
        seen.add(norm)
        out.append(norm)
    return out


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Prepare ShareGPT-style prompts for benchmark JSONL.")
    ap.add_argument("--input", required=True,
                    help="Path to ShareGPT JSON or JSONL file")
    ap.add_argument("--output", required=True, help="Output JSONL path")
    ap.add_argument("--min-prompt-tokens", type=int, default=16)
    ap.add_argument("--max-prompt-tokens", type=int, default=256)
    ap.add_argument("--max-samples", type=int, default=5000)
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()

    in_path = Path(args.input)
    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    records = load_records(in_path)
    prompts = []
    for r in records:
        p = extract_prompt(r)
        if p:
            prompts.append(p)

    prompts = filter_prompts(
        prompts,
        min_tokens=args.min_prompt_tokens,
        max_tokens=args.max_prompt_tokens,
    )

    rnd = random.Random(args.seed)
    rnd.shuffle(prompts)
    prompts = prompts[: args.max_samples]

    with out_path.open("w", encoding="utf-8") as f:
        for p in prompts:
            f.write(json.dumps({"prompt": p}, ensure_ascii=False) + "\n")

    print(
        json.dumps(
            {
                "input": str(in_path),
                "output": str(out_path),
                "records_in": len(records),
                "prompts_after_filter": len(prompts),
                "min_prompt_tokens": args.min_prompt_tokens,
                "max_prompt_tokens": args.max_prompt_tokens,
                "max_samples": args.max_samples,
                "seed": args.seed,
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
