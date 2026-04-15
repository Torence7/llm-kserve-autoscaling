#!/usr/bin/env python3
import argparse
import asyncio
import csv
import json
import codecs
import math
import random
import string
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import aiohttp
import yaml


@dataclass
class RequestResult:
    request_id: str
    scenario: str
    phase_name: str
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


@dataclass
class PhaseConfig:
    name: str
    duration_seconds: int
    arrival_pattern: str
    mean_rps: Optional[float] = None
    rps: Optional[float] = None


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
    return random.expovariate(mean_rps)


def constant_wait(rps: float) -> float:
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
                raise ValueError(
                    f"Invalid JSONL at {path}:{line_num}: {e}") from e
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

    scenario_dir = Path(scenario_path).resolve().parent
    candidate = (scenario_dir / raw_path).resolve()
    if candidate.exists():
        return candidate

    return (Path.cwd() / raw_path).resolve()


def dataset_prompt_from_row(row: Dict[str, Any], min_tokens: int, max_tokens: int) -> str:
    for key in ["prompt", "instruction", "text", "input"]:
        value = row.get(key)
        if isinstance(value, str) and value.strip():
            return clamp_prompt_tokens(value, min_tokens, max_tokens)

    instruction = row.get("instruction", "")
    context = row.get("context", row.get("input", ""))
    merged = "\n\n".join([x for x in [instruction, context]
                         if isinstance(x, str) and x.strip()])
    if merged.strip():
        return clamp_prompt_tokens(merged, min_tokens, max_tokens)

    raise ValueError(
        f"Could not build prompt from dataset row keys: {list(row.keys())}")


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
            for i in range(len(normalized) - 1, -1, -1):
                if normalized[i]["role"] == "user":
                    normalized[i]["content"] = clamp_prompt_tokens(
                        normalized[i]["content"], min_tokens, max_tokens
                    )
                    break
            return normalized

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
        template = random.choice(
            template_pool) if template_pool else prompt_cfg["template"]
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
            raise ValueError(
                "prompt.style=dataset_prompt requires dataset.mode=jsonl and a loaded dataset")
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
            raise ValueError(
                "prompt.style=dataset_chat requires dataset.mode=jsonl and a loaded dataset")
        row = random.choice(dataset_rows)
        return {
            "messages": dataset_chat_from_row(
                row,
                prompt_cfg["min_tokens"],
                prompt_cfg["max_tokens"],
            )
        }

    raise ValueError(f"Unsupported prompt style: {style}")


def build_phases(cfg: Dict[str, Any]) -> List[PhaseConfig]:
    raw_phases = cfg.get("phases")
    phases: List[PhaseConfig] = []

    if raw_phases:
        if not isinstance(raw_phases, list) or not raw_phases:
            raise ValueError("scenario.phases must be a non-empty list")

        for i, phase in enumerate(raw_phases, start=1):
            if not isinstance(phase, dict):
                raise ValueError(f"Phase {i} must be a mapping")

            name = str(phase.get("name", f"phase_{i}"))
            duration_seconds = int(phase["duration_seconds"])
            arrival_pattern = str(
                phase.get("arrival_pattern", cfg.get("arrival_pattern", "")))

            if arrival_pattern not in {"poisson", "constant"}:
                raise ValueError(
                    f"Unsupported arrival pattern in phase {name}: {arrival_pattern}")

            mean_rps = None
            rps = None
            if arrival_pattern == "poisson":
                raw_mean_rps = phase.get("mean_rps", cfg.get("mean_rps"))
                if raw_mean_rps is None:
                    raise ValueError(
                        f"Phase {name} uses poisson but mean_rps is missing")
                mean_rps = float(raw_mean_rps)
            else:
                raw_rps = phase.get("rps", cfg.get("rps"))
                if raw_rps is None:
                    raise ValueError(
                        f"Phase {name} uses constant but rps is missing")
                rps = float(raw_rps)

            phases.append(
                PhaseConfig(
                    name=name,
                    duration_seconds=duration_seconds,
                    arrival_pattern=arrival_pattern,
                    mean_rps=mean_rps,
                    rps=rps,
                )
            )
        return phases

    duration_seconds = int(cfg["duration_seconds"])
    arrival_pattern = str(cfg["arrival_pattern"])

    if arrival_pattern == "poisson":
        mean_rps = cfg.get("mean_rps")
        if mean_rps is None:
            raise ValueError("arrival_pattern=poisson but mean_rps is missing")
        phases.append(
            PhaseConfig(
                name="default",
                duration_seconds=duration_seconds,
                arrival_pattern=arrival_pattern,
                mean_rps=float(mean_rps),
            )
        )
    elif arrival_pattern == "constant":
        rps = cfg.get("rps")
        if rps is None:
            raise ValueError("arrival_pattern=constant but rps is missing")
        phases.append(
            PhaseConfig(
                name="default",
                duration_seconds=duration_seconds,
                arrival_pattern=arrival_pattern,
                rps=float(rps),
            )
        )
    else:
        raise ValueError(f"Unsupported arrival pattern: {arrival_pattern}")

    return phases


def _extract_stream_delta_text(request_type: str, data: Dict[str, Any]) -> str:
    choices = data.get("choices")
    if not isinstance(choices, list) or not choices:
        return ""
    first = choices[0]
    if not isinstance(first, dict):
        return ""
    if request_type == "chat":
        delta = first.get("delta", {})
        if isinstance(delta, dict):
            content = delta.get("content")
            if isinstance(content, str):
                return content
        message = first.get("message", {})
        if isinstance(message, dict):
            content = message.get("content")
            if isinstance(content, str):
                return content
        return ""
    text = first.get("text")
    return text if isinstance(text, str) else ""


async def _read_sse_stream_and_measure(
    resp: aiohttp.ClientResponse, request_type: str, start: float
) -> Dict[str, Any]:
    decoder = codecs.getincrementaldecoder("utf-8")()
    pending = ""
    ttft_ms: Optional[float] = None
    output_chunks: List[str] = []

    async for raw in resp.content.iter_any():
        if not raw:
            continue

        decoded = decoder.decode(raw)
        if not decoded:
            continue

        pending += decoded
        while "\n" in pending:
            line, pending = pending.split("\n", 1)
            line = line.strip()
            if not line.startswith("data:"):
                continue

            payload = line[len("data:"):].strip()
            if payload == "[DONE]":
                continue

            try:
                data = json.loads(payload)
            except json.JSONDecodeError:
                continue

            chunk_text = _extract_stream_delta_text(request_type, data)
            if chunk_text:
                if ttft_ms is None:
                    ttft_ms = (time.time() - start) * 1000.0
                output_chunks.append(chunk_text)

    tail = decoder.decode(b"", final=True)
    if tail:
        pending += tail

    for line in pending.splitlines():
        line = line.strip()
        if not line.startswith("data:"):
            continue
        payload = line[len("data:"):].strip()
        if payload == "[DONE]":
            continue
        try:
            data = json.loads(payload)
        except json.JSONDecodeError:
            continue
        chunk_text = _extract_stream_delta_text(request_type, data)
        if chunk_text:
            if ttft_ms is None:
                ttft_ms = (time.time() - start) * 1000.0
            output_chunks.append(chunk_text)

    return {
        "ttft_ms": ttft_ms,
        "output_chars": len("".join(output_chunks)),
    }


async def send_one_request(
    session: aiohttp.ClientSession,
    endpoint_base: str,
    model_name: str,
    scenario_name: str,
    phase_name: str,
    request_type: str,
    timeout_s: float,
    semaphore: asyncio.Semaphore,
    payload_inputs: Dict[str, Any],
    max_tokens: int,
) -> RequestResult:
    req_id = random_id()
    url = endpoint_base.rstrip(
        "/") + ("/chat/completions" if request_type == "chat" else "/completions")

    if request_type == "chat":
        body = {
            "model": model_name,
            "messages": payload_inputs["messages"],
            "max_tokens": max_tokens,
            "stream": True,
            "temperature": 0.0,
        }
        prompt_chars = sum(len(m["content"])
                           for m in payload_inputs["messages"])
    else:
        body = {
            "model": model_name,
            "prompt": payload_inputs["prompt"],
            "max_tokens": max_tokens,
            "stream": True,
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
                text = ""
                output_chars = 0
                ttft_ms: Optional[float] = None

                if resp.status == 200:
                    stream_result = await _read_sse_stream_and_measure(resp, request_type, start)
                    ttft_ms = stream_result["ttft_ms"]
                    output_chars = int(stream_result["output_chars"])
                else:
                    text = await resp.text()

                end = time.time()
                latency_ms = (end - start) * 1000.0
                if ttft_ms is None:
                    ttft_ms = latency_ms

                return RequestResult(
                    request_id=req_id,
                    scenario=scenario_name,
                    phase_name=phase_name,
                    request_type=request_type,
                    start_ts=start,
                    end_ts=end,
                    latency_ms=latency_ms,
                    ttft_ms=float(ttft_ms),
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
                phase_name=phase_name,
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


async def drain_with_timeout(tasks: List[asyncio.Task], drain_timeout_s: float) -> Tuple[List[RequestResult], int, int]:
    if not tasks:
        return [], 0, 0

    done, pending = await asyncio.wait(tasks, timeout=drain_timeout_s)
    results: List[RequestResult] = []
    task_exception_count = 0

    for task in done:
        try:
            results.append(task.result())
        except Exception:
            task_exception_count += 1

    for task in pending:
        task.cancel()

    if pending:
        await asyncio.gather(*pending, return_exceptions=True)

    return results, len(pending), task_exception_count


async def benchmark_main(args: argparse.Namespace) -> None:
    scenario_cfg = load_yaml(args.scenario)
    outdir = Path(args.outdir)
    ensure_dir(outdir)

    request_type = scenario_cfg["request_type"]
    scenario_name = scenario_cfg["name"]
    timeout_s = float(args.timeout_seconds)
    max_in_flight = int(args.max_in_flight)
    drain_timeout_s = float(args.drain_timeout_seconds)

    dataset_rows: Optional[List[Dict[str, Any]]] = None
    dataset_cfg = scenario_cfg.get("dataset", {})
    dataset_mode = dataset_cfg.get("mode", "synthetic")

    if dataset_mode == "jsonl":
        dataset_path = normalize_dataset_path(scenario_cfg, args.scenario)
        dataset_rows = load_jsonl_dataset(str(dataset_path))
    elif dataset_mode != "synthetic":
        raise ValueError(f"Unsupported dataset.mode: {dataset_mode}")

    phases = build_phases(scenario_cfg)
    total_duration_seconds = sum(phase.duration_seconds for phase in phases)

    print(
        json.dumps(
            {
                "scenario": scenario_name,
                "request_type": request_type,
                "duration_seconds": total_duration_seconds,
                "target": args.target,
                "model_name": args.model_name,
                "max_in_flight": max_in_flight,
                "timeout_seconds": timeout_s,
                "drain_timeout_seconds": drain_timeout_s,
                "dataset_mode": dataset_mode,
                "dataset_rows": len(dataset_rows) if dataset_rows else 0,
                "dataset_path": dataset_cfg.get("path"),
                "phases": [
                    {
                        "name": p.name,
                        "duration_seconds": p.duration_seconds,
                        "arrival_pattern": p.arrival_pattern,
                        "mean_rps": p.mean_rps,
                        "rps": p.rps,
                    }
                    for p in phases
                ],
            },
            indent=2,
        ),
        flush=True,
    )

    semaphore = asyncio.Semaphore(max_in_flight)
    tasks: List[asyncio.Task] = []
    launched = 0
    launched_by_phase: Dict[str, int] = {p.name: 0 for p in phases}

    async with aiohttp.ClientSession() as session:
        for phase in phases:
            print(
                f"Starting phase '{phase.name}' for {phase.duration_seconds}s "
                f"({phase.arrival_pattern}, "
                f"{'mean_rps=' + str(phase.mean_rps) if phase.arrival_pattern == 'poisson' else 'rps=' + str(phase.rps)})",
                flush=True,
            )
            phase_end = time.time() + phase.duration_seconds

            while time.time() < phase_end:
                rate = phase.mean_rps if phase.arrival_pattern == "poisson" else phase.rps
                if rate is None:
                    raise ValueError(
                        f"Phase {phase.name} has no rate configured")

                if rate <= 0:
                    sleep_for = max(0.0, min(1.0, phase_end - time.time()))
                    if sleep_for > 0:
                        await asyncio.sleep(sleep_for)
                    continue

                payload_inputs = build_prompt_from_scenario(
                    scenario_cfg, dataset_rows=dataset_rows)
                max_tokens = choose_max_tokens(scenario_cfg)

                task = asyncio.create_task(
                    send_one_request(
                        session=session,
                        endpoint_base=args.target,
                        model_name=args.model_name,
                        scenario_name=scenario_name,
                        phase_name=phase.name,
                        request_type=request_type,
                        timeout_s=timeout_s,
                        semaphore=semaphore,
                        payload_inputs=payload_inputs,
                        max_tokens=max_tokens,
                    )
                )
                tasks.append(task)
                launched += 1
                launched_by_phase[phase.name] += 1

                if launched % 5 == 0:
                    print(
                        f"Launched {launched} requests so far...", flush=True)

                wait_s = poisson_wait(
                    rate) if phase.arrival_pattern == "poisson" else constant_wait(rate)
                remaining = phase_end - time.time()
                if remaining <= 0:
                    break
                await asyncio.sleep(min(wait_s, remaining))

        print(
            f"Launch phase done. Waiting up to {drain_timeout_s}s for {len(tasks)} tasks...", flush=True)
        results, pending_count, task_exception_count = await drain_with_timeout(tasks, drain_timeout_s)

    requests_csv = outdir / "requests.csv"
    print(f"Writing request results to {requests_csv}", flush=True)
    with open(requests_csv, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow([
            "request_id",
            "scenario",
            "phase_name",
            "request_type",
            "start_ts",
            "end_ts",
            "latency_ms",
            "ttft_ms",
            "prompt_chars",
            "output_chars",
            "max_tokens",
            "status_code",
            "ok",
            "error",
        ])
        for r in results:
            writer.writerow([
                r.request_id,
                r.scenario,
                r.phase_name,
                r.request_type,
                r.start_ts,
                r.end_ts,
                f"{r.latency_ms:.2f}",
                f"{r.ttft_ms:.2f}",
                r.prompt_chars,
                r.output_chars,
                r.max_tokens,
                r.status_code,
                int(r.ok),
                r.error,
            ])

    ok_results = [r for r in results if r.ok]
    recorded_failures = len(results) - len(ok_results)
    unfinished_requests = max(0, launched - len(results))

    per_phase_summary: Dict[str, Dict[str, Any]] = {
        phase.name: {
            "launched": launched_by_phase.get(phase.name, 0),
            "recorded": 0,
            "ok": 0,
            "failed": 0,
        }
        for phase in phases
    }

    for r in results:
        phase_stats = per_phase_summary.setdefault(
            r.phase_name, {"launched": 0, "recorded": 0, "ok": 0, "failed": 0}
        )
        phase_stats["recorded"] += 1
        if r.ok:
            phase_stats["ok"] += 1
        else:
            phase_stats["failed"] += 1

    for phase_name, stats in per_phase_summary.items():
        launched_phase = int(stats["launched"])
        recorded_phase = int(stats["recorded"])
        ok_phase = int(stats["ok"])
        stats["unfinished"] = max(0, launched_phase - recorded_phase)
        stats["completion_rate"] = (
            ok_phase / launched_phase) if launched_phase > 0 else None
        stats["recorded_success_rate"] = (
            ok_phase / recorded_phase) if recorded_phase > 0 else None

    summary = {
        "scenario": scenario_name,
        "request_type": request_type,
        "target": args.target,
        "model_name": args.model_name,
        "duration_seconds": total_duration_seconds,
        "drain_timeout_seconds": drain_timeout_s,
        "dataset_mode": dataset_mode,
        "dataset_path": dataset_cfg.get("path"),
        "dataset_rows": len(dataset_rows) if dataset_rows else 0,
        "phases": [
            {
                "name": p.name,
                "duration_seconds": p.duration_seconds,
                "arrival_pattern": p.arrival_pattern,
                "mean_rps": p.mean_rps,
                "rps": p.rps,
            }
            for p in phases
        ],
        "requests_launched": launched,
        "requests_total_recorded": len(results),
        "requests_ok": len(ok_results),
        "requests_failed": recorded_failures,
        "requests_unfinished": unfinished_requests,
        "task_exception_count": task_exception_count,
        "completion_rate": (len(ok_results) / launched) if launched > 0 else None,
        "recorded_success_rate": (len(ok_results) / len(results)) if results else None,
        "latency_p50_ms": percentile([r.latency_ms for r in ok_results], 50),
        "latency_p95_ms": percentile([r.latency_ms for r in ok_results], 95),
        "ttft_p50_ms": percentile([r.ttft_ms for r in ok_results], 50),
        "ttft_p95_ms": percentile([r.ttft_ms for r in ok_results], 95),
        "per_phase": per_phase_summary,
    }

    summary_path = outdir / "summary.json"
    print(f"Writing summary to {summary_path}", flush=True)
    with open(summary_path, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)

    print(json.dumps(summary, indent=2), flush=True)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Run a benchmark scenario against an OpenAI-compatible endpoint.")
    p.add_argument("--target", required=True,
                   help="Base target like http://localhost:8004/v1")
    p.add_argument("--model-name", required=True,
                   help="Served model name to send in request payload")
    p.add_argument("--scenario", required=True, help="Path to scenario YAML")
    p.add_argument("--outdir", required=True,
                   help="Directory to write results")
    p.add_argument("--timeout-seconds", type=float, default=60.0)
    p.add_argument("--max-in-flight", type=int, default=4)
    p.add_argument("--drain-timeout-seconds", type=float, default=10.0)
    return p.parse_args()


if __name__ == "__main__":
    random.seed(42)
    asyncio.run(benchmark_main(parse_args()))
