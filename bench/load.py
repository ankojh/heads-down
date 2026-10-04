"""Load test a running laya-serve over HTTP.

Start the server first, e.g.:
    LAYA_MODELS=english LAYA_PORT=8077 laya-serve
Usage: python bench/load.py [--url http://127.0.0.1:8077] [--seconds 10]
"""
import argparse
import asyncio
import itertools
import time

import httpx
from cases import CASES, QUESTIONS, state_for

STATES = [state_for(task, region) for task, region, _, _ in CASES]


def percentile(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(p / 100 * (len(xs) - 1))))]


async def run(url, path, make_body, concurrency, seconds):
    lat, errors, done = [], {}, 0
    deadline = time.perf_counter() + seconds
    counter = itertools.count()

    async def worker(client):
        nonlocal done
        while time.perf_counter() < deadline:
            body = make_body(next(counter))
            t = time.perf_counter()
            try:
                r = await client.post(url + path, json=body)
                if r.status_code == 200:
                    lat.append((time.perf_counter() - t) * 1000)
                    done += 1
                else:
                    errors[r.status_code] = errors.get(r.status_code, 0) + 1
            except httpx.HTTPError as e:
                errors[type(e).__name__] = errors.get(type(e).__name__, 0) + 1

    limits = httpx.Limits(max_connections=concurrency)
    async with httpx.AsyncClient(timeout=60, limits=limits) as client:
        start = time.perf_counter()
        await asyncio.gather(*(worker(client) for _ in range(concurrency)))
        elapsed = time.perf_counter() - start
    if not lat:
        return f"c={concurrency:3d}  no successful requests  errors={errors}"
    return (f"c={concurrency:3d}  {done / elapsed:6.1f} req/s  p50 {percentile(lat, 50):7.1f} ms  "
            f"p95 {percentile(lat, 95):7.1f} ms  p99 {percentile(lat, 99):7.1f} ms  errors={errors or 0}")


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8077")
    ap.add_argument("--seconds", type=float, default=10)
    ap.add_argument("--regions", type=int, default=10, help="regions per batch request (one screen)")
    args = ap.parse_args()

    def single(i):
        return {"model": "laya", "state": STATES[i % len(STATES)], "questions": QUESTIONS}

    def screen(i):
        start = (i * args.regions) % len(STATES)
        states = [STATES[(start + k) % len(STATES)] for k in range(args.regions)]
        return {"model": "laya", "states": states, "questions": QUESTIONS}

    print("== POST /v1/systemone (one region per request) ==")
    for c in (1, 4, 16, 32, 64):
        print(await run(args.url, "/v1/systemone", single, c, args.seconds))

    print(f"\n== POST /v1/systemone/batch ({args.regions} regions per request = one screen) ==")
    for c in (1, 4, 16):
        print(await run(args.url, "/v1/systemone/batch", screen, c, args.seconds))


if __name__ == "__main__":
    asyncio.run(main())
