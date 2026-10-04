"""Accuracy, calibration and latency of Laya on the labeled screen regions.

Usage: python bench/quality.py [--device mps|cpu]
"""
import argparse
import statistics
import time

import laya
from cases import CASES, QUESTIONS, state_for

BLUR, LEAVE = 0.8, 0.5  # >= BLUR: blur, < LEAVE: leave alone, else: dim/ask


def percentile(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(p / 100 * (len(xs) - 1))))]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", default="mps")
    ap.add_argument("--model", default="convaiinnovations/laya")
    args = ap.parse_args()

    t0 = time.perf_counter()
    agent = laya.load(args.model, device=args.device)
    print(f"load: {time.perf_counter() - t0:.1f}s on {args.device}")

    states = [state_for(task, region) for task, region, _, _ in CASES]
    for s in states[:3]:  # warmup
        agent.predict(s, QUESTIONS)

    rows, lat = [], []
    for (task, region, label, tricky), s in zip(CASES, states, strict=True):
        t = time.perf_counter()
        out = agent.predict(s, QUESTIONS)
        lat.append((time.perf_counter() - t) * 1000)
        p = out["answers"]["distracting"]["noul"]
        rows.append((p, label, tricky, task, region))

    correct = [(p >= 0.5) == label for p, label, *_ in rows]
    tricky_correct = [c for c, r in zip(correct, rows, strict=True) if r[2]]
    brier = statistics.mean((p - label) ** 2 for p, label, *_ in rows)
    print(f"\n== quality ({len(rows)} cases) ==")
    print(f"accuracy@0.5: {sum(correct)}/{len(correct)} = {sum(correct) / len(correct):.0%}")
    print(f"tricky cases: {sum(tricky_correct)}/{len(tricky_correct)}")
    print(f"brier score: {brier:.3f}  (0 = perfect, 0.25 = coin flip)")

    print("\n== three-tier policy ==")
    for name, lo, hi in [("blur", BLUR, 1.01), ("dim/ask", LEAVE, BLUR), ("leave", 0, LEAVE)]:
        tier = [r for r in rows if lo <= r[0] < hi]
        hits = sum(r[1] for r in tier)
        print(f"{name:8s} n={len(tier):2d}  actually distracting: {hits}/{len(tier)}")

    print("\n== calibration (predicted P(distracting) vs observed) ==")
    for lo in (0, 0.2, 0.4, 0.6, 0.8):
        b = [r for r in rows if lo <= r[0] < lo + 0.2 or (lo == 0.8 and r[0] == 1)]
        if b:
            print(f"[{lo:.1f}, {lo + 0.2:.1f})  n={len(b):2d}  mean p={statistics.mean(r[0] for r in b):.2f}  observed={sum(r[1] for r in b) / len(b):.2f}")

    print("\n== mistakes ==")
    for (p, label, tricky, task, region), ok in zip(rows, correct, strict=True):
        if not ok:
            print(f"p={p:.2f} label={'distract' if label else 'ok':8s} {'[tricky] ' if tricky else ''}{task[:30]}... | {region['title']}: {region['text'][:60]}")

    print(f"\n== single-call latency ({args.device}) ==")
    print(f"p50 {percentile(lat, 50):.1f} ms  p95 {percentile(lat, 95):.1f} ms  max {max(lat):.1f} ms")

    for bs in (8, 16, len(states)):
        t = time.perf_counter()
        agent.predict_batch(states, QUESTIONS, batch_size=bs)
        dt = time.perf_counter() - t
        print(f"predict_batch batch_size={bs:2d}: {len(states) / dt:.0f} regions/s ({dt * 1000 / len(states):.1f} ms/region)")


if __name__ == "__main__":
    main()
