# Heads Down — Jev performance and cost implementation handoff

**For:** the builder agent  
**Repository:** `/Users/ankojh/b12/heads-down`  
**Goal:** Stop unnecessary Jev calls and repeated work while preserving the successful classifier inputs and current hiding behavior.  
**Deliverable from this research pass:** This document only. No app implementation changes or paid API requests were made.

## 1. User-approved direction

The user prefers Jev's quality over Laya and wants to improve runtime/cost without weakening decisions:

1. **Do not rescore a section whose content and relevant context have not changed.**
2. **Dispatch new/changed content at most once per second.**
3. Add other low-risk improvements that reduce wasted work without changing the model's successful question or decision policy.

Interpret the second point as **one dispatch round of eligible pending regions per second**, not one region or one HTTP request per second. Jev currently receives one request per region. Restricting the entire app to one region per second would leave a 20-region screen waiting roughly 20 seconds.

Cached decisions should be usable immediately, without waiting for the dispatch interval. A one-second dispatch gate can add up to roughly one second of scheduling delay before network time; do not describe this as zero latency trade-off. Savings come primarily from reusing results and dropping obsolete inputs, not from a timer alone.

### Scope constraints

- Keep native Swift/AppKit/Vision/ScreenCaptureKit and Jev; preserve local Laya as an available provider.
- Preserve the current question, score interpretation, strictness settings, blur/mask behavior, reveal overrides, timed pause, and emergency pause controls.
- Do not add a planner model, cloud provider, site-specific rules, embeddings, or fuzzy semantic caching.
- Do not batch multiple unrelated regions into a changed Jev prompt in this pass.
- Do not shorten the successful question just to save tokens.
- Carry forward the user's preference against spending time on automated tests: no test suite, CI, new benchmark framework, or dataset work. Build and briefly inspect the real behavior instead.
- No commit/push without permission.

## 2. Working tree warning

HEAD is `4bd5cc1`, but **the current implementation is substantially newer than HEAD and is uncommitted**. Many Swift files and README are modified; important new files are untracked, including:

- `app/HeadsDown/Classification/JevClient.swift`
- `app/HeadsDown/Classification/CanonicalInput.swift`
- `app/HeadsDown/Controller/SessionController+Pipeline.swift`
- `app/HeadsDown/Capture/ContentEnvelope.swift`
- `bench/jev_compare.py`

Inspect and edit the current working files. Do not reset, overwrite, or reconstruct from HEAD. Do not implement the historical `IMPLEMENTATION_HANDOFF.md` from scratch or assume its “no app exists” status still applies. `FIXES_HANDOFF.md` also contains historical findings that have since been partly addressed.

Do not read or expose `.env` secrets just to investigate defaults. `JevClient.swift` and `.env.example` provide configuration structure. Preserve existing secret handling and cloud consent.

## 3. What is already implemented — do not redo it

Source inspection confirms:

- `ScoreCache` is a **2,000-entry in-memory LRU**.
- Keys include task revision, provider identity, question version, and canonical classifier-input fingerprint.
- `CanonicalInput` normalizes Unicode/whitespace, truncates text to 1,200 characters, and removes leading unread-count decorations such as `(3)` from window titles.
- `classifyPending` coalesces identical input keys **within one pass**.
- OCR supports full reads, changed horizontal bands, and retained-observation reuse.
- Blur/cover appearance refresh is separated from OCR/classification.
- Jev makes one HTTP request per region with **up to six concurrent requests**.
- Classifier-only retry passes already exist.
- The app has two-/three-minute timed pause, indefinite pause, and reveal controls.

Do not claim to add caching, title normalization, partial OCR, or bounded concurrency for the first time. The improvements are more precise scheduling, stable input identity, immediate completion caching, and observability.

## 4. Concrete findings in the current code

Paths below are relative to `app/HeadsDown/`.

### 4.1 Successful results can be lost when a group is cancelled

`Classification/JevClient.swift`:

- `classify(task:regions:)` runs a task group, accumulating results in a local array.
- The caller receives results only after the group completes.
- Cancellation or certain fatal errors throw out of the group before returning the array.

`Controller/SessionController+Pipeline.swift`:

- `classifyPending` writes scores to `scoreCache` only after awaiting the entire provider call.

Therefore, if several Jev requests succeed and a window switch cancels the group before the last completes, already-successful scores may never reach the cache. Returning to the same content can pay for those decisions again.

This is a source-confirmed failure path; the research did not quantify how often it occurred in the supplied session.

### 4.2 The current cadence is not the requested classification cadence

`Controller/SessionController.swift` currently defines:

- `tickInterval = 400 ms`
- `debounce = 0.6 s`
- `minCycleGap = 0.5 s`
- `maxDirtyDelay = 2 s`
- `motionRecheckInterval = 15 s`

`maybeStartWork()` gates capture/analysis, not all HTTP dispatches. A cycle can classify many regions, and classifier-only passes follow another path. Changing `minCycleGap` to one second alone does not implement a central, consistent classification dispatcher.

### 4.3 Long scrolling can still generate intermediate paid decisions

`userScrolled()` records `lastScrollAt`, marks `.scroll`, and closes stale keep holes. `maybeStartWork()` can force a cycle after `maxDirtyDelay` even if scrolling continues. `runCycle()` then proceeds to classify the committed regions.

Keep prompt geometry invalidation. Change **eligibility for paid classification**, so scrolling through transient content does not automatically send each intermediate view.

### 4.4 Classification and observation share a long-lived lane

`laneTask` currently owns capture/AX/OCR/grouping and then waits for all classification results. The cheap tick continues, but new expensive observation work can be delayed by network work for obsolete content.

A bounded network dispatcher should be independently owned from the observation lane. Preserve one expensive OCR/analysis lane and one globally bounded network scheduler; do not replace one bottleneck with unbounded parallel work.

### 4.5 Remaining identity weaknesses

`CanonicalInput.text` preserves line breaks. Rewrapping the same prose can therefore alter a key. Other grouping/OCR changes can also create new inputs.

However:

- Actual new text should be rescored.
- Meaningful page/document context changes should be rescored.
- Numbers, punctuation, case, and line breaks may be meaningful in code and structured content.

Do not blindly drop title context or use punctuation-stripped `Fingerprint.normalize` as a classifier key. The key must match the exact canonical payload actually sent.

### 4.6 Usage and request counts are not actual provider billing counters

- `classifyPending` sets `timings.classifierRequests = 1` per provider invocation.
- One Jev invocation can produce many HTTP requests, plus retries.
- `JevClient.classifyOne` extracts the score but discards response `usage.input_tokens` and the returned concrete model ID.

Current pass counts cannot reliably answer “how many HTTP calls/tokens did this session consume?”

### 4.7 Model alias can drift

The client defaults to `jev-latest`, unless configuration overrides it. Cache provider identity uses the requested model string. An alias can resolve to a new model without changing that key. Pin the evaluated concrete version when appropriate and record the returned model ID.

## 5. Target architecture

```text
cheap screen/window monitoring and immediate geometry safety
                  │
       single bounded observation lane
       capture → AX/OCR → current regions
                  │
       reconcile region/input identities
                  │
       cached? ── yes → apply current policy immediately
          │ no
       in flight? ─ yes → subscribe to existing result
          │ no
       latest-only pending registry
                  │
   global dispatch gate: at most one round / second
   + scroll-idle eligibility + retry deadlines
                  │
       Jev HTTP work, at most six in flight
                  │
   each response → usage accounting + cache immediately
                  │
  update only current, geometrically valid subscribers
```

Do not require the builder to use a particular actor/class name, but keep the state responsibilities explicit. A small scheduler/coordinator is preferable to scattered timer checks across `runCycle` and `startClassificationPass`.

## 6. Implementation requirements

### A. Separate semantic identity from current geometry

Use a key equivalent to:

```text
(task namespace/revision,
 provider + pinned model,
 question version,
 canonical-input schema version,
 canonical app + relevant document context + submitted section text)
```

- Coordinates, frame IDs, scroll offsets, and region numbering are not semantic score-key inputs.
- A moved section with identical submitted content/context reuses its score after fresh bounds are established.
- Returning to the same page/window in the same task should reuse retained scores, subject to bounded eviction.
- Keep title/document context if it changes what Jev is asked. Normalize only genuinely decorative data consistently in both payload and key.
- Ensure truncation precedes key creation, as the canonical-input design intends.
- Reuse existing normalization before introducing more.
- Stabilize extraction/grouping where possible, rather than aggressively merging different strings into the same key.
- If prose reflow normalization is added, scope it to reliably identified prose paragraphs. Preserve code/list structure. Version the canonical schema when the payload changes.
- Avoid a cross-session disk cache for this pass; it adds privacy/lifecycle complexity without fixing wasted in-session work.

A title change with unchanged text is not automatically a false miss. Conversely, geometry movement is not automatically a reason for a new semantic score.

### B. Immediate per-result completion

Evolve the provider boundary to report individual completed inputs, for example with an async progress callback or keyed async results. Exact API shape is up to the builder.

Each completion must carry or be associated with immutable metadata captured at dispatch:

- Input key.
- Original task/provider/question namespace.
- Validated score or item error.
- Returned model ID.
- Reported usage when available.

Required behavior:

1. Cache each valid response when it arrives; do not wait for the final sibling request.
2. Do not lose successful siblings when another item fails, is cancelled, or returns unauthorized.
3. Cache scores by semantic key, not by current region index or whatever `regions` happens to contain on completion.
4. Permit reuse of successful scores after a target-window change within the same authorized task/session namespace.
5. Do not apply an old rectangle or reopen an old keep hole from a delayed response.
6. Task/session/provider changes must not relabel old results as new ones. Stopped sessions must not be repopulated or restarted by late callbacks.
7. Usage accounting can record a known completed request even if its visual result is obsolete; cost and applicability are different.
8. Preserve Laya compatibility. A local batch can emit per-item completions once its batch response arrives; it need not fake incremental network responses.

Keep shared mutable cache/UI state isolated to the main actor or an explicit coordinator actor. No detached callback writes to unprotected dictionaries.

### C. Latest-only pending registry

Maintain pending work keyed by semantic input, with references to current region subscribers.

On every region update:

- Use cached scores immediately.
- Attach to an identical in-flight request rather than resubmitting.
- Insert only genuinely missing inputs into pending work.
- Replace superseded versions of the same tracked section.
- Remove pending inputs no longer needed by any current analyzed section.
- Reconcile a split/merge carefully: discard obsolete subscribers and create only the newly necessary inputs.

Do not build a FIFO backlog of historical screen snapshots. Fast scrolling/navigation should leave a small queue describing the latest useful screen, not hundreds of cards that passed through it.

Background retained covers should not by themselves cause new speculative classification. If the current app deliberately analyzes additional windows, explicitly bound that policy; don't expand coverage scope incidentally.

### D. One global dispatch gate

- Use a monotonic clock.
- Permit at most one dispatch round per second across full-cycle and classifier-only paths.
- Do not use a repeating timer that sends requests when there is no work.
- At a dispatch boundary, recheck current subscribers, cache, in-flight registry, scrolling state, and retry eligibility.
- Launch eligible requests up to remaining global concurrency slots (retain a maximum of six initially).
- With more work than slots, retain only still-current items for a later round. The dispatch cap controls starts; requests can naturally finish between rounds.
- Do not launch a new request immediately whenever a sibling finishes if doing so bypasses the chosen round policy.
- Never block cache-hit rendering on the one-second gate.
- Apply individual successful results as they arrive; do not wait to repaint the whole group.
- Keep the pause/stop and capture-invalidity paths immediate, outside this throttle.

If the builder chooses a bounded round that drains a snapshot of inputs in concurrency-limited waves instead, explicitly document that distinction: it limits new observation rounds, not every HTTP start. Prefer strict dispatch slots initially for predictable accounting and cancellation of obsolete queued work.

### E. Scroll-settle gating

Suggested initial quiet interval: **300–500 ms since the most recent real scroll event**, then dispatch on the next available one-second slot.

- Continue lightweight observation and keep-hole invalidation while scrolling.
- Do not send a pending view that was replaced before scrolling stopped.
- Continued momentum scrolling extends the quiet interval.
- Do not apply the same indefinite deferral to normal typing or unrelated animations.
- Don't let a permanently noisy event source starve useful work: use actual target-scoped scroll activity and current visual evidence, not any global mouse-wheel event.
- Preserve existing focus-mode semantics while new decisions are pending; don't silently switch Balanced/Strict or weaken/strengthen masking in this performance pass.

A one-second rate limit alone is not a savings guarantee. If all intermediate content still enters the network queue, the same tokens will eventually be billed.

### F. In-flight deduplication and cancellation

One registry entry per semantic input key:

```text
ready cache → immediate reuse
in-flight key → attach subscriber
pending key → update subscribers, no duplicate
missing key → enqueue
```

- Keep the registry entry alive until the request actually settles, not merely until a view disappears.
- Recheck cancellation before issuing HTTP work and before retries.
- Drop obsolete **unsent** inputs freely.
- For submitted work, do not assume client cancellation refunds the request. Preserve completed useful results; don't launch an identical replacement while the original is still known to be in flight.
- Pause/stop must immediately prevent further dispatch/retries and visual updates. Cancel active network work according to existing lifecycle/privacy expectations; never keep a hidden background classifier loop running after Stop.
- Remove settled/failed entries deterministically so abandoned keys don't become permanently unrequestable.
- Use current task/model namespaces to avoid cross-task result contamination.

### G. Retry behavior

The current client has immediate retries for some URL errors and clips `Retry-After` waits to five seconds.

Improve without changing decisions:

- Use bounded exponential backoff with jitter for retryable transport/overload errors.
- Respect a valid provider retry deadline rather than clipping a longer requested wait down to five seconds.
- Support the documented `429` and `529` cases; don't retry auth/validation failures as ordinary transient errors.
- Recheck whether the input is still needed before each retry.
- Coordinate provider-level backoff with the dispatcher instead of allowing six independent retry loops to create a burst.
- Account for every HTTP attempt. A timed-out request may have been processed remotely; reported usage won't necessarily cover every charge.
- Do not manufacture a distraction score for failed/malformed responses.

Do not add undocumented idempotency headers or assume the provider offers billing deduplication.

### H. Model version and exact cost instrumentation

- TypeSafe currently documents `jev-1.13.0` as the concrete version behind `jev-latest`. Pin the version actually evaluated by this project, after checking the current nonsecret config/defaults and existing comparison notes.
- Record returned model identity and do not silently share score entries across concrete model changes.
- Parse `usage.input_tokens` from each response before discarding the response body; preserve accounting even if the answer is malformed where usage is valid.
- Track: actual HTTP attempts, completed responses, unique input decisions, retries, cache hits, in-flight shares, obsolete queued items dropped, reported input tokens, and estimated cost.
- Keep analysis-pass counts separate from HTTP-request counts.
- Current direct-provider estimate: `input_tokens / 1_000_000 * 0.042` USD; output tokens are free under the cited rate card.
- Label the UI amount as an estimate based on reported usage/rate, not an authoritative invoice. Missing responses, retries, account terms, taxes, and rate changes may differ.
- Reset per-session display counters deliberately; avoid resetting data merely because a window switches or a timed pause occurs.
- Continue privacy-safe bounded logs. No task text, region text, titles, tokens containing content, API keys, or raw HTTP payloads in logs.

A compact Inspector line could show:

```text
Jev: 38 requests · 12,450 reported input tokens · ~$0.0005
Cache: 81 hits · 4 in-flight shares · 22 obsolete inputs skipped
```

Those numbers are illustrative, not measured project results.

## 7. Code touchpoints

| File | Main responsibility |
|---|---|
| `Classification/Classifier.swift` | Provider completion/usage contract; keep the successful question unchanged |
| `Classification/JevClient.swift` | Incremental per-item completion, accurate attempt/usage accounting, cancellation/backoff, returned model identity |
| `Classification/LayaClient.swift` | Adapt to provider contract without changing local prompt/batch semantics |
| `Classification/CanonicalInput.swift` | Preserve exact-payload identity; carefully scoped normalization only |
| `Policy/Policy.swift` | Reuse existing LRU; don't change strictness or score interpretation |
| `Controller/SessionController.swift` | Own scheduler lifecycle, pause/stop/task/provider boundaries, clocks and concurrency limits |
| `Controller/SessionController+Pipeline.swift` | Stop synchronous paid classification after every capture; reconcile pending regions; immediate cache use; result-to-current-region validation |
| `Controller/Models.swift` | Immutable request/completion identity and separate usage/dispatch counters as needed |
| `Regions/Segmenter.swift` | Inspect extraction instability before changing grouping; keep semantics unchanged for the initial queue fixes |
| `App/InspectorView.swift` | Real calls/tokens/cost and useful reuse counters |
| `Diagnostics/DiagnosticsLog.swift` / existing log call sites | Extend bounded metadata only |
| `README.md` and `.env.example` | Document dispatch behavior, timing trade-off, measured counters, pinned model configuration |

Do not read secrets into output. Do not add dependencies merely to implement a timer, cache, or task registry.

## 8. Things explicitly deferred because they may change quality

### Multi-question requests

TypeSafe supports multiple questions against a shared state and evaluates them in parallel. That is **not** proof that combining many unrelated screen regions preserves current accuracy or saves a particular fraction of tokens.

- The documented API is `/v1/systemone`, not a documented independent-state batch endpoint equivalent to Laya's batch endpoint.
- Multi-region/multi-question requests change input organization and potentially visible context.
- Questions/instructions still consume tokens; fewer HTTP calls does not equal proportionally less billed input.
- Question IDs are response routing keys and are **not sent to the model**. Merely naming a question `region_7` does not tell Jev which region to judge; an explicit reference in instructions is required.
- TypeSafe warns that irrelevant large state and indirection can reduce accuracy.

Therefore do not implement batching in this pass. If later explored, compare actual token usage and decisions on representative screens before claiming savings; keep that separate from these quality-preserving scheduler fixes.

### Other deferred ideas

- Shorter prompt/criteria or missing document context.
- Fuzzy/embedding cache reuse for merely similar text.
- Returning to Laya for “easy” cases without evaluating the routing trade-off.
- Increasing concurrency to hide queue latency; it can increase waste on fast navigation.
- Capture-stack replacement with `SCStream` solely to save API cost.

Apple's `SCStream` does expose idle frames and dirty rectangles, useful for reducing capture/CPU work later. The current app uses screenshot capture, so exploiting that metadata is a separate capture refactor. Pixel-change information also cannot prove semantic content is unchanged. Do this only after the API scheduling fixes if actual CPU/energy measurements justify it.

## 9. Research sources and corrections to the supplied estimate

First-party sources were successfully accessed during this investigation:

1. TypeSafe models/pricing/version guidance: https://docs.typesafe.ai/models
2. Request/response usage, question IDs, errors: https://docs.typesafe.ai/api
3. Multiple-question fan-out: https://docs.typesafe.ai/patterns/fan-out
4. Structured question fields: https://docs.typesafe.ai/primitives/advanced
5. Jev 1.13 limitations, including irrelevant large state/indirection: https://docs.typesafe.ai/model-jaggedness/jev-1.13
6. Apple stream frame metadata: https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo
7. Apple stream complete/idle frame explanation: https://developer.apple.com/videos/play/wwdc2022/10156/

As fetched, TypeSafe lists:

- `$0.042 / million input tokens`; output tokens free.
- `jev-1.13.0` behind `jev-latest`.
- Dynamic rate limits of 100K input tokens/second and 80 requests/second. Do not hardcode the older 1,200/minute quotation as a current contractual limit.

The user supplied a prior session estimate: 230 calls in 75 active seconds, ~420 tokens per call, 35% cached regions. This handoff did not independently replay that session or verify each token estimate.

Arithmetic correction: `230 / 75 * 60 ≈ 184 calls/minute`, not 115. At 420 input tokens per call, extrapolated cost is about `$0.195/hour`, or `$34.3` for 22 eight-hour days of sustained activity. That is not a forecast for normal use: scrolling/switching intensity and token sizes vary.

Do not promise a fixed percentage saving. Truly new content still needs a decision. Queue thinning, completion reuse, and duplicate suppression save only work the app otherwise would have wasted.

## 10. Recommended implementation sequence

1. Add accurate HTTP usage/attempt accounting and the per-result completion contract.
2. Cache each result immediately; preserve successful siblings across cancellation/errors.
3. Add the keyed pending/in-flight registry and separate bounded network scheduling from observation.
4. Route every classification path through the one-second dispatch gate.
5. Apply scroll-idle gating and remove obsolete queued versions before sending.
6. Verify cache keys preserve exact canonical inputs/context; address demonstrated extraction misses conservatively.
7. Pin/record model identity and improve retry coordination.
8. Expose concise counters in Inspector and update documentation.

Keep the initial change focused. Do not simultaneously rewrite segmentation, policy, capture, and provider prompts.

## 11. Lightweight completion checks

No new automated suite or benchmark campaign is requested.

Build the existing app:

```bash
xcodebuild -project app/HeadsDown.xcodeproj -scheme HeadsDown -configuration Debug \
  -derivedDataPath app/build build
```

Briefly inspect these behaviors in a normal user-authorized run:

- A settled unchanged page makes no new classification requests after its missing inputs are resolved.
- A section moving or returning into view with unchanged semantic input reuses its score; current bounds are still verified.
- Scrolling continuously does not queue/score every intermediate page. The final settled view becomes eligible on the next dispatch slot.
- New regions dispatch no more than once per second in rounds, while cached decisions apply immediately.
- A window switch partway through several requests retains scores already completed and does not reopen old overlays.
- One failed/cancelled sibling does not discard successful siblings.
- A genuine text/task/document-context change is not incorrectly treated as cached.
- Pause/Stop/timed pause still work immediately; no old timer/request restarts work or redraws stale coverage.
- Pending/in-flight counters settle and memory remains bounded; no permanently stuck input keys.
- Inspector distinguishes HTTP attempts from classification passes and counts actual reported tokens.

Changing code and building is not proof of a cost reduction or visual correctness. State exactly what was observed. If a live run needs permission renewal or would make billable calls beyond existing authorization, tell the user rather than quietly launching a large experiment.

## 12. Report back

Provide:

- Files changed and the implemented scheduling semantics.
- Which successes now reach cache earlier, and how cancelled/obsolete work is handled.
- Any remaining identity misses versus genuinely new content.
- Actual observed request/token counters if measured, not estimated percentage claims.
- The one-second freshness trade-off and behavior during scrolling.
- Build status and remaining unverified behavior.

**Success criterion:** ask Jev once for each genuinely new semantic input that is still useful when dispatch occurs; reuse the answer while safely tracking where that content is now. Do not trade away context or decision quality to make the request counter look smaller.
