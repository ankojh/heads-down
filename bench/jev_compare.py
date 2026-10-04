"""Compare Jev (TypeSafe hosted) with local Laya on the same labeled screen regions.

Sends only the synthetic cases in cases.py to TypeSafe; no real screen content.
Reads TYPESAFE_API_KEY / TYPESAFE_BASE_URL from ../.env (or the environment). The key is never printed.
Laya is queried through a running laya-serve (see FINDINGS.md for the start command).

Usage: python bench/jev_compare.py [--models jev-latest,jev-preview] [--laya-url http://127.0.0.1:8077]
"""
import argparse
import asyncio
import os
import pathlib
import statistics
import time

import httpx
from cases import CASES, QUESTIONS, state_for

ENV_FILE = pathlib.Path(__file__).resolve().parent.parent / ".env"
APP_CUTOFFS = (0.5, 0.65)  # Balanced / Relaxed in the app


def load_env():
    if ENV_FILE.exists():
        for line in ENV_FILE.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                os.environ.setdefault(key.strip(), value.strip())


def percentile(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(p / 100 * (len(xs) - 1))))]


async def score_jev(client, base_url, key, model, states, concurrency=4):
    """One request per case, mirroring how the app would call it. Retries 429/5xx with backoff."""
    sem = asyncio.Semaphore(concurrency)
    headers = {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}

    async def one(state):
        body = {"model": model, "state": state, "questions": QUESTIONS}
        async with sem:
            for attempt in range(5):
                t = time.perf_counter()
                r = await client.post(f"{base_url}/v1/systemone", json=body, headers=headers)
                ms = (time.perf_counter() - t) * 1000
                if r.status_code == 200:
                    return r.json()["answers"]["distracting"]["noul"], ms
                if r.status_code in (429, 500, 502, 503, 504):
                    await asyncio.sleep(float(r.headers.get("retry-after", 2 ** attempt)))
                    continue
                raise RuntimeError(f"{model}: HTTP {r.status_code}: {r.text[:200]}")
            raise RuntimeError(f"{model}: gave up after retries")

    results = await asyncio.gather(*(one(s) for s in states))
    return [p for p, _ in results], [ms for _, ms in results]


async def score_laya(client, url, states):
    t = time.perf_counter()
    r = await client.post(f"{url}/v1/systemone/batch", json={"model": "laya", "states": states, "questions": QUESTIONS})
    r.raise_for_status()
    ms = (time.perf_counter() - t) * 1000 / len(states)
    return [item["answers"]["distracting"]["noul"] for item in r.json()["results"]], [ms] * len(states)


def report(name, scores, lat):
    labels = [label for _, _, label, _ in CASES]
    tricky = [t for *_, t in CASES]
    correct = [(p >= 0.5) == label for p, label in zip(scores, labels, strict=True)]
    tricky_ok = sum(c for c, t in zip(correct, tricky, strict=True) if t)
    brier = statistics.mean((p - label) ** 2 for p, label in zip(scores, labels, strict=True))
    hidden = "  ".join(f"hides@{c}: {sum(p >= c for p in scores) / len(scores):.0%}" for c in APP_CUTOFFS)
    print(f"{name:12s} acc {sum(correct)}/{len(correct)} = {sum(correct) / len(correct):.0%}  "
          f"tricky {tricky_ok}/{sum(tricky)}  brier {brier:.3f}  median p {statistics.median(scores):.2f}  "
          f"{hidden}  latency p50 {percentile(lat, 50):.0f} ms")
    return correct


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", default="jev-latest,jev-preview")
    ap.add_argument("--laya-url", default="http://127.0.0.1:8077")
    args = ap.parse_args()
    load_env()
    key = os.environ.get("TYPESAFE_API_KEY", "")
    base_url = os.environ.get("TYPESAFE_BASE_URL", "https://api.typesafe.ai").rstrip("/")
    if not key:
        raise SystemExit("TYPESAFE_API_KEY is not set (see .env)")

    states = [state_for(task, region) for task, region, _, _ in CASES]
    print(f"{len(states)} labeled cases ({sum(t for *_, t in CASES)} tricky); "
          f"truth = distracting; correct = (p >= 0.5) matches label\n")
    runs = {}
    async with httpx.AsyncClient(timeout=60) as client:
        try:
            runs["laya (local)"] = await score_laya(client, args.laya_url, states)
        except httpx.HTTPError as e:
            print(f"laya skipped: {type(e).__name__} (is laya-serve running?)")
        for model in args.models.split(","):
            runs[model] = await score_jev(client, base_url, key, model, states)

    correctness = {name: report(name, *run) for name, run in runs.items()}

    names = list(runs)
    print("\n== per-case scores where any model is wrong (✗) ==")
    print(f"{'truth':8s} " + " ".join(f"{n[:12]:>12s}" for n in names) + "  case")
    for i, (task, region, label, tricky) in enumerate(CASES):
        if all(correctness[n][i] for n in names):
            continue
        cells = " ".join(f"{runs[n][0][i]:>10.2f}{' ' if correctness[n][i] else '✗'} " for n in names)
        print(f"{'distract' if label else 'ok':8s} {cells} {'[tricky] ' if tricky else ''}"
              f"{task[:24]}… | {region['title']}: {region['text'][:50]}")


if __name__ == "__main__":
    asyncio.run(main())
