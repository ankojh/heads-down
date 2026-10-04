# Heads Down — stability, hiding, and temporary-pause fixes

**Recipient:** Opus 5-5 (Cloudbridge), or the next implementation agent  
**Repository:** `/Users/ankojh/b12/heads-down`  
**Investigated baseline:** `4bd5cc1` — `feat(app): add native macOS menu-bar prototype with region segmentation and local classification`  
**Scope of this pass:** Source inspection and analysis of existing local diagnostic metadata. No app code changed, no app/model launched, no new screen captures taken.

## 1. User request and priorities

The user reports:

1. The app recalculates after small changes, may not be caching effectively, and blur does not work well.
2. Add a temporary pause lasting 2–3 minutes, with automatic resumption.
3. Be substantially more aggressive: hide content unless it is really related to the task. The user prefers over-hiding to under-hiding and will correct mistakes afterward.

The requested deliverable for this investigation was a handoff, not immediate implementation. This document provides that handoff. It supersedes the conservative hiding/unknown-content defaults in `IMPLEMENTATION_HANDOFF.md` for this fix pass.

Carry forward these constraints:

- No confirmation prompts during classification or hiding. Manual reveal/pause remains available.
- Keep Swift/AppKit/Vision/ScreenCaptureKit and the existing local Laya service.
- No planner-model migration, Jev integration, new cloud dependency, or browser pivot as part of these fixes.
- No automated test suite, CI, new benchmarking framework, or prompt-tuning campaign. Do a normal build and brief hands-on checks of the actual requested behavior.
- Do not commit/push without user permission.
- Aggressive hiding is a focus preference, not a security guarantee. Never compromise the emergency escape controls or render stale geometry over unrelated apps/system UI.

Recommended implementation defaults in this document (thresholds, debounce values, pause default) are engineering starting points, not measured optimums or exact numbers chosen by the user.

## 2. What actually exists now

The native app is implemented under `app/HeadsDown/`; the old planning handoff's “no app exists” status is historical.

Current operation:

- Poll target window and capture a thumbnail approximately every 400 ms plus processing time.
- Trigger full AX + OCR + segmentation after detected changes, at most once per second when settled and once per three seconds when continuously unsettled.
- Cache classifier scores in memory, but not reusable OCR/layout results.
- Dim or blur text/container regions according to conservative thresholds.
- Pause indefinitely or reveal one region for ten minutes; no timed global pause.
- One frontmost normal window on one selected display. Full-screen windows are unsupported.

The worktree was clean before adding this handoff. No running process matched HeadsDown or laya in the process-name check. Existing logs are historical evidence, not a reproduction of the user's exact current visual issue.

## 3. Evidence from existing runtime logs

Analyzed `~/Library/Logs/HeadsDown/cycles.jsonl`, which contains metadata rather than screen/task text.

The available file has 75 events, including 64 completed cycles, from one start/stop session. Event timestamps are UTC, between `2026-10-04T00:12:05Z` and `2026-10-04T00:20:27Z`; the actual recorded session starts at `00:16:04Z`.

### Caching is present and demonstrably used

Across the 64 completed cycles:

- 955 region observations.
- 678 reported cached scores — about 71% of region observations.
- 253 newly classified region scores.
- 11 nonempty cycles had every region cached, yet still ran OCR/grouping.
- The remaining observations were not all successfully classified in that cycle; do not force the two counters to sum to the region count.

Concrete examples:

| Cycle | Regions | Cached | Classified | OCR time |
|---|---:|---:|---:|---:|
| 10 | 24 | 24 | 0 | ~199 ms |
| 12 | 25 | 25 | 0 | ~152 ms |
| 14 | 25 | 25 | 0 | ~160 ms |
| 70 | 27 | 27 | 0 | ~244 ms |

Therefore: **the problem is not absence of a score cache. It is repeated screen analysis, brittle cache identity, and overlay invalidation/replacement even when scores are reused.**

### Observed latency is not just model latency

- Median recorded OCR: ~165 ms.
- Median completed cycle: ~372 ms.
- Median recorded change-to-overlay interval: ~1.22 seconds.
- One initial recorded OCR took ~26.95 seconds, producing a ~27.58-second cycle. The log establishes a first-recorded-cycle stall, not its cause; do not confidently attribute it to model load or Vision warmup without evidence.

### Available logs do not demonstrate actual blur quality

- 57 completed cycles were in Dim mode, 6 Observe, and only 1 Blur.
- The completed Blur cycle (#10) applied 9 dim actions and 15 leave actions, **zero blur actions**.
- Its one score over 0.8 was excluded because the region's geometry was marked uncertain.
- Mode-change events are not full rendering traces; there could have been intervening mode-change renders not represented by a completed cycle.
- Action logs record intended policy, not necessarily what was drawn. A stale region can still be logged as `dim` even though `render()` drops it.

Do not report that Core Image blur was visually reproduced or proved broken. Source inspection identifies concrete exposure/flicker paths; its visual strength and alignment still need a short live check.

## 4. Findings: recalculation and caching

### A. One changed thumbnail cell schedules a full analysis

**Files/symbols:**

- `Capture/Thumbnail.swift`: `Thumbnail.diff(against:)`, `cellThreshold`, `cellSize`.
- `Controller/SessionController.swift`: `tick(session:)`, `maybeStartCycle(_:)`, `changedSince(_:capturedAt:)`, `staleIDs(for:)`.

The thumbnail is 192 px wide with 8×8 px cells; a cell is changed if its mean grayscale difference exceeds 6.0.

In `tick`, **any nonempty changed-cell list** relative to the analysis baseline sets `needsAnalysis = true`. The 2% `settledChangeFraction` only determines whether consecutive thumbnails are considered settled; it is not a threshold that suppresses analysis.

One cell spans about 1/24 of the target window's width. A small local change can therefore intersect a substantially larger region. Any changed cell intersecting the region's inset rectangle marks the whole region stale and removes its overlay.

Consequences:

- Hover effects, counters, or animations can trigger full-window AX/OCR/grouping.
- Changes outside existing semantic regions also schedule full analysis.
- “Settled” means the newest two thumbnails are similar, not that a meaningful semantic change happened.
- Existing thresholds attempt to ignore a caret, but that intent is not a guarantee for every layout/font/scale.

### B. Dirty state can survive a cycle that already captured the change

`startCycle` clears `needsAnalysis`; while the cycle is awaiting work, `tick` can set it again against the **old** baseline. When the new segmentation/baseline is committed, there is no epoch-aware reconciliation that says which pending changes the new capture already incorporated.

Also, when the latest thumbnail returns to matching the baseline, stale IDs are cleared but `needsAnalysis` is not cleared. A transient change can still lead to a redundant cycle after disappearing.

Fix the bookkeeping, not just the poll interval. Do not blindly set `needsAnalysis = false` at completion either: that would lose genuine changes that arrived after the captured frame.

### C. Every analysis does full-window OCR regardless of cache hits

`runCycle` captures a small frame and a full frame, performs full AX and full OCR in parallel, merges, and segments. Only **after** all of that does it check `scoreCache`.

`ObservationMerger.merge` currently requires OCR visibility confirmation for AX text. An incremental fix must account for this dependency; do not just skip OCR and feed stale AX observations through the existing merger as though they were fresh.

There is no changed-region OCR cache/layout cache, no stable tracked-region store, and no separate classifier-only retry path. A classifier retry can rerun the capture/OCR pipeline even when the input already exists unchanged.

### D. Score fingerprints do not reliably represent the actual submitted input

**Files/symbols:**

- `Regions/Segmenter.swift`: region construction in `segment(_:)`, `Fingerprint`.
- `Controller/Models.swift`: `ScreenRegion`.
- `Policy/Policy.swift`: `ScoreCache`.
- `Controller/SessionController.swift`: `cacheKey(_:revision:)`.

The classifier fingerprint hashes `appName + windowTitle + raw reading-order text`:

- It does not normalize harmless whitespace/line-break changes.
- It includes the raw window title; changing counters/status titles can miss every score in a window.
- It hashes the **full text**, but `ScreenRegion.text` sent to Laya is truncated to 1,200 characters afterward. A change only beyond the submitted prefix invalidates a score even though the model sees identical input.
- Changes in OCR grouping/order change fingerprints even where most content is stable.

The normalized content fingerprint used for IDs is different: it lowercases and strips all punctuation. Do not reuse that indiscriminately as the semantic classifier key; punctuation/case can matter in code, names, numbers, and negation.

The existing cache is bounded FIFO (1,000 entries), not LRU; cache hits do not refresh order. FIFO is not the central problem, and adding disk persistence will not fix screen-analysis churn.

### E. Cancellation prevents display of old results, not all background work

AX/OCR/grouping/blur jobs are created with `Task.detached`. Cancelling `cycleTask` does not automatically cancel detached work or an already-running synchronous Vision request. `invalidateAll()` also immediately sets the cycle handle to nil, so a replacement cycle may start while obsolete detached work is still executing.

Keep generation guards, but also serialize/own expensive recognition work. Pause should prevent new work and discard late results immediately; be honest if an in-progress OS call cannot stop instantly.

## 5. Findings: why hiding/blur is unreliable or too weak

### A. Blur frames are discarded on every analysis, including fully cached cycles

In `SessionController.runCycle`:

```text
regions = new segmentation
baseline = new baseline
lastSnapshot = new snapshot
blurCache = [:]
rebuildDecisions()
render()
... classify pending regions ...
prepareBlurCrops()
render()
```

`render()` maps a `.blur` decision with no cached image to **`.none`**. This guarantees an uncovered interval when blur crops are being rebuilt; if classification is pending, that interval includes its latency too. Crop failure also produces uncovered content.

Do not interpret an intended blur action as evidence of rendered blur.

### B. Content changes remove covers instead of refreshing them safely

Stale regions are filtered out of rendering entirely. Continuous animation can repeatedly expose exactly the distracting region the user wants hidden. “Hidden until re-read” in existing comments/UI sometimes means the **overlay** is hidden, not the content—fix this confusing terminology.

Distinguish:

- Appearance/content changed inside a still-valid container: retain coverage, update evidence/crop as necessary.
- Geometry/ownership changed: discard old screen-space placement immediately and reacquire valid bounds.

Never solve flicker by blindly keeping a rectangle over a different app after scrolling/window switching.

### C. Current policy is conservative, even in Blur mode

`Policy.swift` currently:

- Leaves scores below 0.5 alone.
- Dims 0.5–0.8.
- Blurs only >=0.8.
- Leaves unscored regions uncovered.
- Leaves geometry-uncertain regions uncovered.

The user now requests almost the reverse: **keep only content with strong evidence of relevance; cover the rest within a trustworthy coverage area.**

Lowering only the Gaussian radius or increasing only dim opacity cannot fix these policy exclusions.

### D. Coverage is often text-only

`Segmenter` uses a qualifying AX container when possible; otherwise it covers text bounds plus 4 pt padding. Images, card backgrounds, and video thumbnails outside those boxes remain visible regardless of score or blur radius. Regions over the 60-region cap and blocks below the text minimum are dropped altogether.

A strict policy that only covers existing OCR boxes will still leave most text-free distractions exposed. Address the uncovered space explicitly rather than claiming a lower score threshold solves it.

### E. Actual renderer characteristics

- `BlurRenderer.radiusPoints = 10`, scaled to capture density, with clamped edges.
- It renders a snapshot, not live cross-app compositor blur.
- `OverlayView` draws that snapshot without an additional suppressive tint.
- Dim uses black at 0.72 alpha, which can leave readable content.
- Rounded crop corners leave small uncovered corners.

Clamping and Retina-aware radius scaling already exist. Don't “fix” them as if absent. There is no evidence in this investigation of a proven Y-flip or broken capture self-exclusion; inspect those only if live symptoms point there.

## 6. Recommended design for the fixes

Implement one coherent correction: **separate observation freshness, semantic decisions, and visual coverage.**

```text
cheap window/layout + local change monitoring
             │
       tracked region state
       ├── layout evidence / bounds freshness
       ├── normalized submitted input + score cache
       └── cover image / placeholder freshness
             │
 targeted analysis only when evidence requires it
             │
      atomic policy/overlay update
```

### 6.1 Scheduling and region reuse

1. Introduce explicit dirty reasons: target/layout change, local content change, geometry-only movement, classifier retry, policy change, override expiry, and blur-refresh-only.
2. Track observation/capture epochs and the regions affected by changes. Consume only dirty events incorporated into the committed capture; preserve newer ones.
3. Reconcile dirty state after a successful cycle. If a transient diff disappears and no newer evidence is pending, do not run another full cycle.
4. Derive the analysis baseline from the **same full image** used for OCR, rather than an independently captured earlier thumbnail. Ensure downsampling/comparison uses compatible geometry and filtering. The current separate captures can sample different animation states; that risk is source-derived, not a reproduced cause.
5. Coalesce local diffs before expensive analysis. Suggested starting debounce: 500–800 ms, with a bounded maximum delay around 2 seconds for sustained meaningful text changes. Do not indefinitely defer typing or slowly accumulating changes.
6. Preserve unaffected regions and scores. Use geometry/container identity plus conservative text identity for tracking; do not treat every new OCR result array as a new screen.
7. Distinguish image animation from text/layout changes. Persistent motion in an already-covered, stable container should not force global OCR every three seconds forever. A bounded local reinspection can detect changed labels/layout without globally uncovering it.
8. After stable-layout local edits, OCR/resegment the affected crop/container with enough margin/context for grouping, and reuse unaffected observations. Expand/fall back to a full pass for scrolling, large layout changes, ambiguous ownership, or split/merge boundary changes.
9. Do not use only whole-window changed-area fraction: one small new recommendation can matter. Combine local persistence, region overlap, layout evidence, and semantic input changes.
10. Retry classification against unchanged stored inputs without recapturing/re-OCR'ing the window. Coalesce identical pending classifier inputs and fan out their results.
11. Keep a real single expensive-work lane across cancellation/replacement. Check cancellation between phases and before network requests; don't misreport cancellation as classifier outage/backoff.

This does not need a new LLM planner. Implement deterministic scheduling/region reuse first.

### 6.2 Correct cache identity

Build the submitted `ClassifierInput` once, then derive the key from that exact canonical payload:

```text
(task revision, provider/model version, question version, input-schema version,
 canonical app/context, canonical submitted text after truncation)
```

- Canonicalize Unicode and harmless whitespace consistently in both payload and key.
- Preserve meaningful punctuation, numbers, and word changes.
- Hash **after** the same truncation used for the actual model input.
- Separate current rectangle/layout identity from score identity.
- Separate visual snapshot identity from both of those.
- Keep true document/page/title changes meaningful. Do not simply remove title context from the key while still sending it to the model.
- If stabilizing title counters/status decorations, use a conservative documented generic normalization applied to both payload and key; don't introduce site-specific title hacks or strip meaningful numbers everywhere.
- Keep the cache bounded and in memory. LRU is reasonable but lower priority than identity and analysis reuse.
- Retain score cache during pauses and window switches; invalidate on task/provider/question changes as appropriate.
- Do not use broad fuzzy matching to keep new unrelated content visible based on an old relevant score.

### 6.3 Strict hiding policy

**Recommended default for active focus mode: strict, with a keep cutoff of `pDistracting < 0.20`.** This is an uncalibrated, intentionally aggressive starting point, not a measured “80% relevance” guarantee.

| Situation | Strict focus behavior |
|---|---|
| Valid low distraction score (<0.20) and current trustworthy region bounds | Keep visible |
| Valid score >=0.20 | Strongly cover |
| Pending/missing/malformed classification, but trustworthy target coverage area | Cover as unknown/pending; do not fabricate a score |
| User explicitly revealed the region | Keep revealed until expiry/revocation |
| User paused/stopped | Remove all coverage immediately |
| Unsupported target, permission loss, unknown ownership, or invalid geometry | Remove invalid coverage; show an accurate paused/degraded status |

Keep semantic uncertainty separate from geometry uncertainty. The user accepts false-positive **content decisions**, not rectangles placed on arbitrary windows.

- In Blur mode, everything that fails the keep rule gets the strong blur/mask; do not merely dim the whole ambiguous middle band.
- Preserve Observe for debugging and Dim if useful, but don't change modes silently on an existing user. Make the strict policy explicit and make active hiding easy/default for a fresh focus session; Observe should be deliberately chosen rather than mistaken for protection.
- Keep the existing Laya question initially. The benchmark's alternate “is this relevant?” wording performed much worse. Lowering the keep cutoff is a policy change, not proof the model now understands relevance better.
- Include policy version/settings in decision identity, not in raw score identity unless the actual request changes. A strictness change should rerender from cached scores, not reclassify identical input.
- Add modest release hysteresis if needed: cover immediately on meaningful uncertainty; require a stable valid keep decision before revealing. Don't let raw score jitter flash content repeatedly.

### 6.4 Cover unknown space, not just OCR text

For the requested “hide unless related” behavior, use an **allow-visible mask within a validated target-content envelope**:

```text
safe target content envelope
  minus proven relevant regions
  minus explicit user reveals
  minus excluded UI / higher-window occlusion
= area to cover
```

This covers text-free thumbnails/backgrounds and areas dropped by the segmenter's text/region limits without pretending to classify their pixels.

Implementation requirements:

- Validate the coverage envelope against the current selected target/window/display on every layout change.
- Exclude higher-window occluders, Heads Down controls, system UI, and required escape/navigation chrome. Use actual window/AX structure where possible, not guessed site selectors.
- Do not globally mask the selected display or other app windows.
- Reveal only the verified region bounds; a relevant label does not justify opening an enormous parent container containing unrelated material.
- Where only text-block geometry exists, revealing only that block is acceptable for this user's over-hiding preference. Document that relevant surrounding images may be hidden and can be manually revealed.
- When a changed container still has trustworthy geometry, cover its pending/unknown area instead of leaving a hole.
- If only part of a region is occluded, subtract/clip the occluded area where possible rather than marking the entire content region unhideable. Preserve ownership/occlusion safeguards.
- If the safe content envelope cannot be established, use trustworthy region bounds only and disclose reduced coverage. Do not guess a full-screen black rectangle.

This is deliberately more aggressive than the original text-region-only architecture. A first patch may lower the threshold and fix persistent covers before this envelope work, but it must not claim “everything unrelated is hidden” while thumbnails and unsegmented areas remain visible.

### 6.5 Stable, strong visual coverage

- Retain covers for unchanged regions across analysis cycles.
- Key crop reuse by region visual/content version, bounds/scale, and rendering configuration. Do not reuse stale pixels solely because a score matches.
- Prepare replacement images off the main actor and swap them atomically. Do not clear the entire blur cache before rendering the replacement state.
- If a region must be covered but no usable blur crop exists, render an **opaque neutral placeholder** immediately—not `.none` and not weak dimming.
- For stable-geometry changes, keep the cover/placeholder while refreshing text/imagery. For invalid geometry, discard the old rectangle and reconstruct coverage from current validated target bounds.
- Make blur more suppressive: a stronger configurable Gaussian blur (e.g. start around 20–24 pt) plus a dark/desaturated treatment. These are starting visual parameters, not verified optimal settings.
- If large recognizable content remains distracting, use a near-opaque/opaque neutral mask rather than claiming larger Gaussian blur alone guarantees hiding. Keep the actual effect described honestly in UI/docs.
- Keep coverage edges fully covered where strict hiding is intended; avoid rounded-corner slivers exposing readable pixels.
- Maintain clean capture exclusion of Heads Down; do not implement hide/capture/show flicker loops or capture the rendered blur as source imagery.
- Do not increase full OCR frequency to make blur look live. Appearance refresh and semantic classification need independent schedules.

## 7. Temporary pause: exact behavior to implement

Existing `pause()` calls `endWork()`, clears overlays/geometry, and preserves task/score cache; `resume()` starts a fresh observation loop. Reuse that structure.

### UI contract

- Add prominent **Pause for 3 min**; offer **2 min** in the same menu/control.
- Show `Paused · resumes in 2:17` using a deadline-derived countdown.
- Offer **Resume now** and **Stay paused**.
- Preserve the existing indefinite emergency pause/resume shortcut (`⌃⌥⌘P`). Do not silently turn the emergency stop into a timer that unexpectedly re-hides the screen.
- Keep Stop distinct: it ends the session and cancels any automatic resume.
- Do not ask the user for confirmation on every pause/resume.

### State/lifecycle contract

Add an explicit pause kind/reason, a resume deadline, and a cancellable auto-resume task owned by the controller—not by an open SwiftUI panel.

1. Timed pause clears overlays immediately, cancels/suspends observation scheduling, and blocks all late work from rendering.
2. Preserve current task, mode, strictness, scores, and valid user overrides. Discard/revalidate geometry and snapshots on resume.
3. Starting a new timed pause replaces the previous deadline; no stacked timers.
4. Resume now cancels the timer and starts exactly one observation loop.
5. Stay paused converts to indefinite pause and cancels the timer.
6. Stop, Quit, or starting a replacement session cancels/invalidate the deadline and prevents resurrection.
7. A task edit while paused must have deliberate behavior: update/invalidate task scores without leaving an old timer able to restart an obsolete session. Distinguish “edit task” from an explicit Start/Resume action.
8. Timer completion validates session identity, pause token, timed-pause state, and permission/capture readiness before resuming.
9. Use a sleep-aware elapsed deadline (e.g. `ContinuousClock`) for timing; derive display countdown rather than decrementing a counter. If the interval elapses during sleep, resume once after wake when capture is available. Never draw old pre-sleep masks.
10. Work must resume when the menu is closed. Countdown UI refresh must not trigger OCR or rebuild overlays.

Related existing issue worth fixing in this pass: reveal overrides expire only when `rebuildDecisions()`/override access occurs. A completely static screen may never reapply coverage at the ten-minute expiry. Make policy/override expiry scheduling independent of OCR, using the same controller-level scheduling discipline.

## 8. File-by-file implementation map

Paths below are relative to `app/HeadsDown/` unless noted.

| File | Changes |
|---|---|
| `Controller/SessionController.swift` | Dirty-event/epoch reconciliation; separate capture, local analysis, retry, and render-only paths; keep covers through updates; bounded recognition jobs; timed pause lifecycle; expiry-driven policy updates |
| `Controller/Models.swift` | Tracked-region/layout/content versions; policy/render status; explicit timed/indefinite pause state and UI descriptions |
| `Capture/Thumbnail.swift` | Expose useful local change magnitudes; support debouncing/local significance without treating every changed cell as a full analysis request |
| `Capture/ScreenCapturer.swift` | Reuse the clean frame for baseline; support targeted refresh where needed; retain self-exclusion |
| `Capture/WindowLocator.swift` | Trustworthy current coverage envelope, clipping, geometry/occlusion distinctions; don't extend scope to other apps |
| `Capture/Geometry.swift` | Centralize any new crop/mask transforms; retain point/pixel correctness |
| `Recognition/OCRRecognizer.swift` | Crop-level recognition path and bounded cancellation-aware work ownership where supported |
| `Recognition/ObservationMerger.swift` | Merge fresh local observations with valid retained ones; don't treat old OCR confirmation as eternally fresh AX evidence |
| `Regions/Segmenter.swift` | Stable tracking integration, canonical submitted text before hashing, local regrouping, appropriate keep-region/container boundaries |
| `Policy/Policy.swift` | Strict keep cutoff, unknown/pending action, override precedence, scores separate from policy, cache maintenance |
| `Classification/Classifier.swift` | Shared canonical submitted input/key contract if placed here; retain unknown as nil |
| `Classification/LayaClient.swift` | Preserve question; cancellation handling and request dedup integration if needed; no relevance-prompt rewrite |
| `Overlays/OverlayController.swift` | Strong cover fallback, allow-visible mask/occlusion clipping, atomic display updates, actual rendered-status accounting |
| `Overlays/BlurRenderer.swift` | Stronger configurable treatment, appearance cache/version inputs, no forced global regeneration |
| `App/ControlPanelView.swift` | Timed pause choices/countdown/resume/stay-paused; strict focus explanation |
| `App/InspectorView.swift` | Separate cache hits/analysis reuse; intended action versus actual rendered cover; clear unknown/stale semantics |
| `App/HeadsDownApp.swift` / `App/HotKeys.swift` | Preserve emergency shortcut and stop-on-quit; menu-bar timed-pause status if useful |
| `Diagnostics/DiagnosticsLog.swift` | Continue existing bounded privacy-safe log; extend fields at call sites, no screenshots/text |
| `README.md` | Update thresholds, strict unknown behavior, timed pause, actual coverage/blur limitations; remove stale claims of never-verified behavior only when actually checked |

Keep the source layout; no rewrite of the app or new dependency framework is needed.

## 9. Minimal observability needed to tell whether the fixes worked

Extend existing metadata, not a new telemetry system:

- Analysis trigger reason and dirty epoch consumed/pending.
- Full versus local OCR count and regions reused.
- Cache hit/miss counts, classifier request count, identical-input coalescing count.
- Score-cache misses by coarse cause if available: task/context/text changed, absent, evicted. Do not log raw input/fingerprints that enable persistent content tracking unnecessarily.
- Cover reused/rebuilt count; fallback mask count.
- Intended hide count **and actual rendered hide count**; reason for skipped geometry.
- Timed pause/resume/cancel events and duration, not task text.

Existing logs can't identify which tiny visual element caused a cycle or prove a crop was drawn; these fields close that gap without storing screen content.

## 10. Implementation order

1. **Temporary pause and escape correctness.** Make aggressive mode easy to suspend before expanding coverage.
2. **Fix no-image → uncovered and global blur-cache reset.** Add strong placeholders and atomic replacement; retain valid covers.
3. **Strict policy.** Keep only low-score content, cover pending/unknown within trustworthy geometry, update all UI threshold strings/colors together.
4. **Dirty-state bookkeeping and canonical cache keys.** Eliminate redundant cycles already consumed by a capture; deduplicate classifier work.
5. **Incremental observation/tracking.** Preserve unchanged OCR/layout and avoid repeated whole-window work for local animation/text changes.
6. **Strict coverage envelope.** Address text-free/unsegmented gaps and partial occlusion with bounded mask geometry; don't claim completion before this is addressed or explicitly limited.
7. **Renderer strength and concise docs/logs.** Confirm the actual visual result briefly rather than assuming a larger radius is sufficient.

Do not hide problems by changing only `minCycleInterval`, increasing `cellThreshold` dramatically, deleting geometry guards, or persisting stale score/rectangle pairs indefinitely.

## 11. Lightweight completion checks — not a test-suite task

Build the existing target:

```bash
xcodebuild -project app/HeadsDown.xcodeproj -scheme HeadsDown -configuration Debug \
  -derivedDataPath app/build build
```

If a live run is appropriate/authorized for the implementation session:

```bash
# Existing local classifier, if not already running:
USE_TF=0 LAYA_MODELS=english LAYA_PORT=8077 LAYA_HOST=127.0.0.1 \
LAYA_DEVICE=mps .venv/bin/laya-serve

open app/build/Build/Products/Debug/HeadsDown.app
```

Ad-hoc signing can require Screen Recording/Accessibility grants to be refreshed after rebuilding. Do not confuse denied permissions with segmentation failure.

Briefly demonstrate:

- A static page remains stable; minor hover/caret/counter changes do not repeatedly rebuild every region/crop.
- A real local text change is eventually re-read and classified without refreshing unrelated regions; navigation/scrolling cannot reuse stale keep holes.
- Hiding persists while crops are being refreshed and when a crop/model response is unavailable but geometry remains trustworthy.
- Irrelevant/unknown text and image areas are substantially covered; relevant content can remain visible and manual reveal works.
- Pause 2/3 min removes coverage instantly; automatic resume works with the panel closed; Stop/indefinite pause prevents old timers from resuming.
- The global pause shortcut still works during slow OCR/classification, and no late result resurrects coverage after pause/stop.
- Report whether actual blur/mask appearance and geometry were seen on the desktop. A build alone is not visual verification.

No unit/integration suite or new benchmark dataset is requested. No accuracy claims from these hands-on checks.

## 12. Report-back expectations

Summarize:

- Which recalculation paths were eliminated and which cache layers now exist.
- Whether observed classifier misses were input changes versus missing cache entries.
- How strict mode treats low scores, unknown content, text-free regions, and invalid geometry.
- What the visual effect really is: snapshot blur, tinted blur, opaque mask, or fallback.
- Exact timed-pause controls and preserved emergency shortcut.
- What was built/run versus what remains unverified.

Most important: **fix needless reanalysis and disappearing covers together.** A faster classifier cannot compensate for discarding valid overlays on every small change, and more aggressive thresholds cannot hide content outside the regions the renderer actually covers.
