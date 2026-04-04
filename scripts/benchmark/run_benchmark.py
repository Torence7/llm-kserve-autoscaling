#!/usr/bin/env python3
import argparse
import asyncio
import csv
import json
import math
import random
import string
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional

import aiohttp
import yaml


@dataclass
class RequestResult:
    request_id: str
    scenario: str
    request_type: str
    start_ts: float
    end_ts: float
    latency_ms: float
    ttft_ms: float
    prompt_chars: int
    output_chars: int
    max_tokens: int
    status_code: int
    ok: bool
    error: str = ""


def load_yaml(path: str) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def random_id(k: int = 10) -> str:
    return "".join(random.choices(string.ascii_lowercase + string.digits, k=k))


def estimate_tokens_from_text(text: str) -> int:
    return max(1, math.ceil(len(text.split()) * 1.33))


def clamp_prompt_tokens(text: str, min_tokens: int, max_tokens: int) -> str:
    base = text.strip()
    words = base.split()
    if not words:
        words = ["benchmark"]
    target = random.randint(min_tokens, max_tokens)
    while estimate_tokens_from_text(" ".join(words)) < target:
        words.extend(words[: min(len(words), 20)] or ["benchmark"])
    return " ".join(words)


def percentile(values: List[float], p: float) -> Optional[float]:
    if not values:
        return None
    values_sorted = sorted(values)
    if len(values_sorted) == 1:
        return float(values_sorted[0])
    k = (len(values_sorted) - 1) * (p / 100.0)
    f = math.floor(k)
    c = math.ceil(k)
    if f == c:
        return float(values_sorted[int(k)])
    d0 = values_sorted[f] * (c - k)
    d1 = values_sorted[c] * (k - f)
    return float(d0 + d1)


def choose_max_tokens(cfg: Dict[str, Any]) -> int:
    output_cfg = cfg["output"]
    if "max_tokens" in output_cfg:
        return int(output_cfg["max_tokens"])
    return random.randint(int(output_cfg["max_tokens_min"]), int(output_cfg["max_tokens_max"]))


def poisson_wait(mean_rps: float) -> float:
    if mean_rps <= 0:
        return 1.0
    return random.expovariate(mean_rps)


def constant_wait(rps: float) -> float:
    if rps <= 0:
        return 1.0
    return 1.0 / rps


def load_jsonl_dataset(path: str) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    with open(path, "r", encoding="utf-8") as f:
        for line_num, line in enumerate(f, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as e:
                raise ValueError(f"Invalid JSONL at {path}:{line_num}: {e}") from e
    if not rows:
        raise ValueError(f"No rows found in dataset file: {path}")
    return rows


def normalize_dataset_path(cfg: Dict[str, Any], scenario_path: str) -> Optional[Path]:
    dataset_cfg = cfg.get("dataset", {})
    if dataset_cfg.get("mode") != "jsonl":
        return None

    raw_path = dataset_cfg.get("path")
    if not raw_path:
        raise ValueError("dataset.mode is jsonl but dataset.path is missing")

    p = Path(raw_path)
    if p.is_absolute():
        return p

    # Resolve relative to repo root-ish by scenario file parent/.. fallback
    scenario_parent = Path(scenario_path).resolve().parent
    candidate = (scenario_parent.parent.parent / raw_path).resolve()
    if candidate.exists():
        return candidate

    candidate2 = (Path.cwd() / raw_path).resolve()
    return candidate2


def dataset_prompt_from_row(row: Dict[str, Any], min_tokens: int, max_tokens: int) -> str:
    # Try common fields in order.
    for key in ["prompt", "instruction", "text", "input"]:
        value = row.get(key)
        if isinstance(value, str) and value.strip():
            return clamp_prompt_tokens(value, min_tokens, max_tokens)

    # Dolly-style rows often have instruction + context/input
    instruction = row.get("instruction", "")
    context = row.get("context", row.get("input", ""))
    merged = "\n\n".join([x for x in [instruction, context] if isinstance(x, str) and x.strip()])
    if merged.strip():
        return clamp_prompt_tokens(merged, min_tokens, max_tokens)

    raise ValueError(f"Could not build prompt from dataset row keys: {list(row.keys())}")


def dataset_chat_from_row(row: Dict[str, Any], min_tokens: int, max_tokens: int) -> List[Dict[str, str]]:
    messages = row.get("messages")
    if isinstance(messages, list) and messages:
        normalized = []
        for m in messages:
            if not isinstance(m, dict):
                continue
            role = m.get("role")
            content = m.get("content")
            if isinstance(role, str) and isinstance(content, str) and content.strip():
                normalized.append({"role": role, "content": content})
        if normalized:
            # Expand the last user message a little if desired
            for i in range(len(normalized) - 1, -1, -1):
                if normalized[i]["role"] == "user":
                    normalized[i]["content"] = clamp_prompt_tokens(
                        normalized[i]["content"], min_tokens, max_tokens
                    )
                    break
            return normalized

    # Fallback: build simple chat from prompt-like fields
    prompt = dataset_prompt_from_row(row, min_tokens, max_tokens)
    return [{"role": "user", "content": prompt}]


def build_prompt_from_scenario(
    cfg: Dict[str, Any],
    dataset_rows: Optional[List[Dict[str, Any]]] = None,
) -> Dict[str, Any]:
    prompt_cfg = cfg["prompt"]
    style = prompt_cfg["style"]

    if style == "plain":
        template_pool = prompt_cfg.get("template_pool")
        template = random.choice(template_pool) if template_pool else prompt_cfg["template"]
        prompt_text = clamp_prompt_tokens(
            template,
            prompt_cfg["min_tokens"],
            prompt_cfg["max_tokens"],
        )
        return {"prompt": prompt_text}

    if style == "repeated_context":
        seed_text = prompt_cfg["seed_text"]
        prompt_text = clamp_prompt_tokens(
            seed_text,
            prompt_cfg["min_tokens"],
            prompt_cfg["max_tokens"],
        )
        return {"prompt": prompt_text}

    if style == "chat_pool":
        messages_pool = prompt_cfg["messages_pool"]
        item = random.choice(messages_pool)
        system_msg = item["system"]
        user_msg = item["user"]
        expanded = clamp_prompt_tokens(
            f"{system_msg}\n\n{user_msg}",
            prompt_cfg["min_tokens"],
            prompt_cfg["max_tokens"],
        )
        return {
            "messages": [
                {"role": "system", "content": system_msg},
                {"role": "user", "content": expanded},
            ]
        }

    if style == "dataset_prompt":
        if not dataset_rows:
            raise ValueError("prompt.style=dataset_prompt requires dataset.mode=jsonl and a loaded dataset")
        row = random.choice(dataset_rows)
        return {
            "prompt": dataset_prompt_from_row(
                row,
                prompt_cfg["min_tokens"],
                prompt_cfg["max_tokens"],
            )
        }

    if style == "dataset_chat":
        if not dataset_rows:
            raise ValueError("prompt.style=dataset_chat requires dataset.mode=jsonl and a loaded dataset")
        row = random.choice(dataset_rows)
        return {
            "messages": dataset_chat_from_row(
                row,
                prompt_cfg["min_tokens"],
                prompt_cfg["max_tokens"],
            )
        }

    raise ValueError(f"Unsupported prompt style: {style}")


async def send_one_request(
    session: aiohttp.ClientSession,
    endpoint_base: str,
    model_name: str,
    scenario_name: str,
    request_type: str,
    timeout_s: float,
    semaphore: asyncio.Semaphore,
    payload_inputs: Dict[str, Any],
    max_tokens: int,
) -> RequestResult:
    req_id = random_id()
    url = endpoint_base.rstrip("/") + ("/chat/completions" if request_type == "chat" else "/completions")

    if request_type == "chat":
        body = {
            "model": model_name,
            "messages": payload_inputs["messages"],
            "max_tokens": max_tokens,
            "stream": False,
            "temperature": 0.0,
        }
        prompt_chars = sum(len(m["content"]) for m in payload_inputs["messages"])
    else:
        body = {
            "model": model_name,
            "prompt": payload_inputs["prompt"],
            "max_tokens": max_tokens,
            "stream": False,
            "temperature": 0.0,
        }
        prompt_chars = len(payload_inputs["prompt"])

    async with semaphore:
        start = time.time()
        try:
            async with session.post(
                url,
                json=body,
                timeout=aiohttp.ClientTimeout(total=timeout_s),
            ) as resp:
                ttft_ms = (time.time() - start) * 1000.0
                text = await resp.text()
                end = time.time()
                latency_ms = (end - start) * 1000.0

                output_chars = 0
                if resp.status == 200:
                    try:
                        data = json.loads(text)
                        if request_type == "chat":
                            output_chars = len(data["choices"][0]["message"]["content"])
                        else:
                            output_chars = len(data["choices"][0]["text"])
                    except Exception:
                        output_chars = 0

                return RequestResult(
                    request_id=req_id,
                    scenario=scenario_name,
                    request_type=request_type,
                    start_ts=start,
                    end_ts=end,
                    latency_ms=latency_ms,
                    ttft_ms=ttft_ms,
                    prompt_chars=prompt_chars,
                    output_chars=output_chars,
                    max_tokens=max_tokens,
                    status_code=resp.status,
                    ok=(resp.status == 200),
                    error="" if resp.status == 200 else text[:500],
                )
        except Exception as e:
            end = time.time()
            return RequestResult(
                request_id=req_id,
                scenario=scenario_name,
                request_type=request_type,
                start_ts=start,
                end_ts=end,
                latency_ms=(end - start) * 1000.0,
                ttft_ms=(end - start) * 1000.0,
                prompt_chars=prompt_chars,
                output_chars=0,
                max_tokens=max_tokens,
                status_code=0,
                ok=False,
                error=str(e)[:500],
            )


async def drain_with_timeout(tasks: List[asyncio.Task], drain_timeout_s: float) -> List[RequestResult]:
    if not tasks:
        return []

    done, pending = await asyncio.wait(tasks, timeout=drain_timeout_s)
    results: List[RequestResult] = []

    for task in done:
        try:
            results.append(task.result())
        except Exception:
            pass

    for task in pending:
        task.cancel()

    if pending:
        await asyncio.gather(*pending, return_exceptions=True)

    return results


async def benchmark_main(args: argparse.Namespace) -> None:
    scenario_cfg = load_yaml(args.scenario)
    outdir = Path(args.outdir)
    ensure_dir(outdir)

    duration = int(scenario_cfg["duration_seconds"])
    arrival_pattern = scenario_cfg["arrival_pattern"]
    request_type = scenario_cfg["request_type"]
    scenario_name = scenario_cfg["name"]
    timeout_s = float(args.timeout_seconds)
    max_in_flight = int(args.max_in_flight)
    drain_timeout_s = float(args.drain_timeout_seconds)

    mean_rps = scenario_cfg.get("mean_rps")
    rps = scenario_cfg.get("rps")

    dataset_rows: Optional[List[Dict[str, Any]]] = None
    dataset_cfg = scenario_cfg.get("dataset", {})
    dataset_mode = dataset_cfg.get("mode", "synthetic")

    if dataset_mode == "jsonl":
        dataset_path = normalize_dataset_path(scenario_cfg, args.scenario)
        dataset_rows = load_jsonl_dataset(str(dataset_path))
    elif dataset_mode != "synthetic":
        raise ValueError(f"Unsupported dataset.mode: {dataset_mode}")

    print(
        json.dumps(
            {
                "scenario": scenario_name,
                "request_type": request_type,
                "duration_seconds": duration,
                "arrival_pattern": arrival_pattern,
                "target": args.target,
                "model_name": args.model_name,
                "max_in_flight": max_in_flight,
                "timeout_seconds": timeout_s,
                "drain_timeout_seconds": drain_timeout_s,
                "dataset_mode": dataset_mode,
                "dataset_rows": len(dataset_rows) if dataset_rows else 0,
                "dataset_path": dataset_cfg.get("path"),
            },
            indent=2,
        ),
        flush=True,
    )

    semaphore = asyncio.Semaphore(max_in_flight)
    tasks: List[asyncio.Task] = []
    t_end = time.time() + duration
    launched = 0

    async with aiohttp.ClientSession() as session:
        while time.time() < t_end:
            payload_inputs = build_prompt_from_scenario(scenario_cfg, dataset_rows=dataset_rows)
            max_tokens = choose_max_tokens(scenario_cfg)

            task = asyncio.create_task(
                send_one_request(
                    session=session,
                    endpoint_base=args.target,
                    model_name=args.model_name,
                    scenario_name=scenario_name,
                    request_type=request_type,
                    timeout_s=timeout_s,
                    semaphore=semaphore,
                    payload_inputs=payload_inputs,
                    max_tokens=max_tokens,
                )
            )
            tasks.append(task)
            launched += 1

            if launched % 5 == 0:
                print(f"Launched {launched} requests so far...", flush=True)

            if arrival_pattern == "poisson":
                await asyncio.sleep(poisson_wait(float(mean_rps)))
            elif arrival_pattern == "constant":
                await asyncio.sleep(constant_wait(float(rps)))
            else:
                raise ValueError(f"Unsupported arrival pattern: {arrival_pattern}")

        print(f"Launch phase done. Waiting up to {drain_timeout_s}s for {len(tasks)} tasks...", flush=True)
        results = await drain_with_timeout(tasks, drain_timeout_s)

    requests_csv = outdir / "requests.csv"
    print(f"Writing request results to {requests_csv}", flush=True)
    with open(requests_csv, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow([
            "request_id", "scenario", "request_type", "start_ts", "end_ts",
            "latency_ms", "ttft_ms", "prompt_chars", "output_chars",
            "max_tokens", "status_code", "ok", "error"
        ])
        for r in results:
            writer.writerow([
                r.request_id, r.scenario, r.request_type, r.start_ts, r.end_ts,
                f"{r.latency_ms:.2f}", f"{r.ttft_ms:.2f}", r.prompt_chars, r.output_chars,
                r.max_tokens, r.status_code, int(r.ok), r.error
            ])

    ok_results = [r for r in results if r.ok]
    summary = {
        "scenario": scenario_name,
        "request_type": request_type,
        "target": args.target,
        "model_name": args.model_name,
        "duration_seconds": duration,
        "drain_timeout_seconds": drain_timeout_s,
        "requests_launched": launched,
        "requests_total_recorded": len(results),
        "requests_ok": len(ok_results),
        "requests_failed": len(results) - len(ok_results),
        "latency_p50_ms": percentile([r.latency_ms for r in ok_results], 50),
        "latency_p95_ms": percentile([r.latency_ms for r in ok_results], 95),
        "ttft_p50_ms": percentile([r.ttft_ms for r in ok_results], 50),
        "ttft_p95_ms": percentile([r.ttft_ms for r in ok_results], 95),
    }

    summary_path = outdir / "summary.json"
    print(f"Writing summary to {summary_path}", flush=True)
    with open(summary_path, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)

    print(json.dumps(summary, indent=2), flush=True)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Run a benchmark scenario against an OpenAI-compatible endpoint.")
    p.add_argument("--target", required=True, help="Base target like http://localhost:8004/v1")
    p.add_argument("--model-name", required=True, help="Served model name to send in request payload")
    p.add_argument("--scenario", required=True, help="Path to scenario YAML")
    p.add_argument("--outdir", required=True, help="Directory to write results")
    p.add_argument("--timeout-seconds", type=float, default=60.0)
    p.add_argument("--max-in-flight", type=int, default=4)
    p.add_argument("--drain-timeout-seconds", type=float, default=10.0)
    return p.parse_args()


if __name__ == "__main__":
    random.seed(42)
    asyncio.run(benchmark_main(parse_args()))