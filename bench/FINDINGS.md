# Laya benchmark findings

Run on 2026-10-03 to decide whether Laya can be the local "is this distracting?" brain for Heads Down.

**Verdict:** fast and cheap enough to run continuously, and good on obvious cases. On its own it
behaves like a site blocker: it judges by the website (YouTube, Reddit) more than by the content,
which is exactly the case the agent is supposed to handle better than a blocklist.

## Setup

- Machine: M3 Max, 48 GB, macOS
- `laya` 0.3.26, `torch` 2.14.1, `transformers` 5.18.0, Python 3.12
- Model: `convaiinnovations/laya` (English, ModernBERT-large, 421M params, ~800 MB download)
- Data: 48 hand-labeled screen regions in `cases.py` across 4 tasks (PM studying, coding the
  backend, group sync call, history essay). 11 are marked **tricky**, meaning a fixed blocklist would get
  them wrong (e.g. a Kano model lecture on YouTube while studying PM).
- State sent to Laya: `{"current_task": ..., "screen_region": {app, title, url, text}}`
- Labels are my own judgment and the set is small, so treat percentages as rough.

## Speed (M3 Max)

| Setting | Result |
|---|---|
| One region, GPU (`mps`) | p50 ~26 ms, p95 ~30 ms over HTTP |
| One region, CPU | p50 ~95 ms |
| Batch of 10 regions (one screen), GPU | ~134 ms per request |
| Batched throughput, GPU | ~70–75 regions/s |
| Batched throughput, CPU | ~21–23 regions/s |
| Model load | ~19 s on GPU first time (includes download), ~2 s on CPU once cached |
| Server memory | ~930 MB RSS |

GPU and CPU gave identical accuracy.

## Load test (`laya-serve` on GPU)

The server processes one inference at a time, so concurrency only adds queueing. Throughput is flat.

| Concurrent clients | req/s | p50 | p95 | Errors |
|---|---|---|---|---|
| 1 | 38 | 26 ms | 30 ms | 0 |
| 4 | 40 | 100 ms | 106 ms | 0 |
| 16 | 40 | 400 ms | 418 ms | 0 |
| 32 | 38 | 431 ms | 485 ms | 503s (over `LAYA_MAX_CONCURRENT=16`) |
| 64 | 38 | 552 ms | 1022 ms | 503s |

Batch endpoint, 10 regions per request: ~7.3 req/s regardless of concurrency.

**For Heads Down:** one user checking one screen every ~2 s uses under 5% of capacity. Load is not a concern.

## Quality (default question: "would this pull the user away from their task?")

- Accuracy at 0.5 threshold: **40/48 = 83%**
- Tricky cases: **5/11** (coin flip)
- Brier score: 0.127 (0 = perfect, 0.25 = coin flip)

Three-tier policy (blur ≥ 0.8, dim/ask 0.5–0.8, leave < 0.5):

| Tier | n | Actually distracting |
|---|---|---|
| blur | 11 | 10/11 |
| dim/ask | 10 | 7/10 |
| leave | 27 | 4/27 |

Calibration is reasonable at the top (predicted 0.89, observed 0.91). The 0.2–0.4 bucket is somewhat
too high (predicted 0.30, observed 0.14). The high-confidence "blur" tier is trustworthy.

### Mistakes

| P(distracting) | Truth | Case |
|---|---|---|
| 0.91 | ok | Studying PM: YouTube "Kano Model Explained in 8 Minutes" |
| 0.80 | ok | Coding: Spotify "Lofi Beats to Code To" |
| 0.73 | ok | Coding: YouTube "FastAPI Full Course" |
| 0.51 | ok | Studying PM: r/ProductManagement thread about RICE |
| 0.44 | distracting | Coding: Hacker News front page |
| 0.41 | distracting | Essay: Wikipedia "List of Pokemon" |
| 0.39 | distracting | Group sync: ESPN live Lakers score |
| 0.35 | distracting | Group sync: gaming Discord patch notes |

Pattern: it is biased by the site (YouTube/Reddit → distracting, Wikipedia → fine) and is too lenient
during the group sync task.

## Question wording matters a lot (`phrasing.py`)

| Variant | Accuracy | Tricky |
|---|---|---|
| `distracting_noul`: "would this pull the user away?" | 83% | 5/11 |
| `keep_or_blur_choice`: choice keep/blur with topic-focused criteria | **85%** | **6/11** |
| `relevant_noul`: "does this help the user's task?" | 44% | 2/11 |
| `topic_noul`: "same subject as the task? judge content, not site" | 46% | 2/11 |

Asking about *relevance* instead of *distraction* collapses to worse than chance, even though it is
logically the same question. A minimal ad-hoc question rated "TikTok dance trend while studying" only
0.30 distracting. Any wording change must be re-checked against this benchmark.

## Ideas to try next

1. Iterate on the wording (choice form did best) and keep tracking the tricky score.
2. Add a separate content-vs-task topic signal (e.g. embedding similarity of region text vs task)
   so YouTube/Reddit content about the task isn't blurred.
3. Collect real screens from actual study sessions and grow `cases.py` beyond 48.
4. Compare against Jev (same `/v1/systemone` API) if early access comes through.
5. Try the `typed-decisions` checkpoint.

## Reproduce

```bash
cd ~/b12/heads-down
python3.12 -m venv .venv && .venv/bin/pip install "laya[serve]" httpx   # if .venv is missing

USE_TF=0 .venv/bin/python bench/quality.py --device mps    # accuracy, calibration, latency
USE_TF=0 .venv/bin/python bench/quality.py --device cpu
USE_TF=0 .venv/bin/python bench/phrasing.py                # question wording comparison

# load test: start the server, then run the client
USE_TF=0 LAYA_MODELS=english LAYA_PORT=8077 LAYA_HOST=127.0.0.1 LAYA_DEVICE=mps .venv/bin/laya-serve &
.venv/bin/python bench/load.py --seconds 8
pkill -f laya-serve
```

`USE_TF=0` avoids a known hang in `transformers` when TensorFlow is installed.
