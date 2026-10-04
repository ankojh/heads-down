# Handoff: Heads Down (focus mode)

> **Implementation update:** Read `IMPLEMENTATION_HANDOFF.md` for the current user-approved
> macOS-first direction, native Swift + local Laya architecture, and implementation sequence.
> This file records the earlier benchmark session; its quality-first suggested next steps
> have been superseded. The user accepts imperfect classification for the initial prototype.

Written 2026-10-03 for the next agent (GPT-6 Astra, high). Read this, then `bench/FINDINGS.md`.

## The project

An extra-credit assignment. The rubric is at `~/Downloads/Extra Credit Rubric - Final.pdf`; read it
before making design decisions. From the earlier discussion, it rewards:
- a specific, personal pain point (not generic "too much info")
- an agent that chains tools together, not a single prompt
- running on its own (bonus)
- a video a non-technical audience can follow
- an honest limitations section backed by real testing

**Idea (the user's):** a macOS focus mode that blurs distracting parts of the screen, judged by an
agent against what the user is currently working on, rather than a fixed blocklist.

**Planned design (not built yet):**
1. **Read:** window titles, browser tabs/URLs, and on-screen text via macOS APIs and Apple's
   on-device text recognition (Vision OCR). Text only; the decision models don't take images.
2. **Decide:** send `{current_task, screen_region}` to Laya running locally. The task is typed in by the
   user or taken from the current Google Calendar event.
3. **Act on confidence:** ≥ 0.8 blur, 0.5–0.8 dim or ask, < 0.5 leave alone. Use a translucent
   overlay window over the region.

**Model decision:** the user chose **Laya** (open source, local, by Convai Innovations) over
**Jev** (TypeSafe's hosted cloud API; early-access waitlist; ~$0.042 per million input tokens). Laya
serves the same `/v1/systemone` API as Jev, so Jev can be swapped in later for comparison. Privacy
story: screen content never leaves the laptop.

## What was done this session

- Deleted an old `~/focus-mode` folder (only a stale venv) at the user's request.
- The user created `git@github.com:ankojh/heads-down.git`; cloned to `~/b12/heads-down` (was empty).
- Created `.venv` (Python 3.12) with `laya[serve]` 0.3.26 and `httpx`. `.gitignore` excludes `.venv/`
  and `__pycache__/`. Model weights are in the Hugging Face cache (`~/.cache/huggingface`).
- Built and ran a benchmark in `bench/`:
  - `cases.py`: 48 hand-labeled regions across 4 tasks, 11 marked tricky; the shared question; `state_for()`
  - `quality.py`: accuracy, calibration, three-tier breakdown, mistakes, latency, batch throughput
  - `phrasing.py`: compares 4 question wordings
  - `load.py`: HTTP load test against `laya-serve`
  - `FINDINGS.md`: all results, plus how to rerun them

## Key findings (details in `bench/FINDINGS.md`)

- **Speed is not a problem.** About 26 ms per region on the M3 Max GPU (`mps`) and ~134 ms for a 10-region
  screen batch; ~95 ms per region on CPU. ~930 MB RAM.
- **Load is not a problem.** The server runs one inference at a time, so throughput stays around 38 req/s
  and extra concurrency only adds queueing; above 16 concurrent requests it returns 503s. One user
  needs under 5% of capacity.
- **Quality is the problem.** 83–85% overall, but only 5–6 of the 11 tricky cases right. It judges by the
  site, not the content: a Kano-model YouTube lecture while studying PM was rated 0.91 distracting,
  and Pokémon Wikipedia during the WWI essay only 0.41. It is also too lenient during the group-sync task.
- **High-confidence tier is trustworthy:** 10 of the 11 regions it would blur at ≥ 0.8 really were
  distracting.
- **Very sensitive to how the question is worded.** "Is this distracting?" scored 83% and a keep/blur
  choice 85%, but "is this relevant to the task?" scored 44%, worse than chance. Recheck every
  wording change with `bench/phrasing.py`.
- Caveat: 48 cases labeled by the previous agent, so the percentages are rough.

## Current state

- **Nothing is committed or pushed.** The working tree has `.gitignore`, `bench/` and this file.
  Ask the user before committing or pushing.
- No app code exists yet: no screen reading, overlay or calendar integration.
- `laya-serve` is stopped.

## Suggested next steps

1. Confirm the direction with the user. Options from the findings:
   tune the question wording, add a separate topic-similarity signal for the region's content
   (e.g. local embeddings of the region text vs the task), and grow `cases.py` with real screens.
2. Read the rubric PDF and confirm the user's specific pain point (which apps or sites distract them
   and how much time it costs). They were asked this but never answered.
3. Prototype the screen-reading step on macOS and measure its latency, since only Laya's speed has
   been measured so far.
4. Then build the overlay and the three-tier policy, and log every decision for the limitations section.

## Gotchas

- Run Laya with `USE_TF=0`; `transformers` can hang at load when TensorFlow is installed.
- Laya 0.3.26 `Agent.predict` is `system_one(state, questions)`; use `predict_batch(states, questions,
  batch_size=16)` for a whole screen. `noul` answers return P(true) in `answers[q]["noul"]`.
- `laya-serve` config is via env vars: `LAYA_MODELS=english LAYA_PORT=8077 LAYA_HOST=127.0.0.1
  LAYA_DEVICE=mps`. Batch endpoint: `POST /v1/systemone/batch` with `{states, questions}`.
- User preference (from `~/.pi/agent/AGENTS.md`): when a request is ambiguous or has several
  reasonable approaches, ask the user before starting.
