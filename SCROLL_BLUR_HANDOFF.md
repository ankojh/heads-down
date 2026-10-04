# Heads Down — scroll-following coverage and blur optimization

**For:** the builder agent  
**Repository:** `/Users/ankojh/b12/heads-down`  
**Scope:** Fix covers disappearing during scrolling, make coverage follow moving content where reliable, and reduce blur/rendering work.  
**This handoff:** Based on current source inspection. No app code changed or live visual reproduction performed while writing it.

## 1. User request

> Every time I scroll, all of the blur things unblur and recalculate. Can it be optimized so that it scrolls along with it?

The user then requested a builder handoff for the scroll fix and blur optimization, **without tests**.

Desired experience:

- Distracting content does not flash visible on each scroll event.
- Existing covers move with their content when its movement can be tracked reliably.
- Unchanged sections keep their existing Jev decisions.
- Only newly exposed or meaningfully changed content requires new semantic analysis.
- Blur rendering remains responsive without coupling animation to OCR or paid calls.
- When tracking is uncertain, temporarily conceal the affected content area rather than exposing everything or leaving incorrectly positioned rectangles.

Do not add tests, a testing section/workstream, test fixtures, CI, or new benchmark infrastructure. This is an implementation handoff, not a request to start another research project.

## 2. Scope boundaries

Keep:

- Native Swift/AppKit, ScreenCaptureKit, Vision, current providers and current classifier question.
- Current score cache and classification scheduler.
- Current hiding levels, user-selected mode, task/context semantics, and reveal controls.
- Instant emergency pause, two-/three-minute timed pause, Stop, and existing cloud consent.
- Click-through, nonactivating overlays and exclusion of our own windows from capture.

Do not add:

- Calendar, notes, other connectors, or an agent/planner model. Those were discussed separately and are not part of this request.
- Website selectors, browser extension code, or site-specific scroll rules.
- More Jev calls to make masks move smoothly.
- New blanket site/app blocking or a silent switch from Balanced to Strict.
- A full-screen mask over unrelated apps/system controls.
- Prompt changes, classification-threshold tuning, new dependencies merely for timers, or git commits/pushes without permission.

A temporary mask over a trustworthy affected scroll container is an explicit transition fallback, not a permanent policy change.

## 3. Current working tree matters

The implementation is largely **uncommitted** and newer than HEAD `4bd5cc1`. Important untracked files include:

- `app/HeadsDown/Controller/ClassificationScheduler.swift`
- `app/HeadsDown/Controller/SessionController+Pipeline.swift`
- `app/HeadsDown/Classification/JevClient.swift`
- `app/HeadsDown/Classification/CanonicalInput.swift`
- `app/HeadsDown/Capture/ContentEnvelope.swift`

Inspect the working files, not just committed history. Do not reset or overwrite existing changes.

Historical handoffs are context, not current specifications to implement from scratch:

- `IMPLEMENTATION_HANDOFF.md`: original architecture.
- `FIXES_HANDOFF.md`: earlier stability/strictness fixes, several now implemented.
- `JEV_PERFORMANCE_HANDOFF.md`: classifier scheduling/cache work, now partly implemented in `ClassificationScheduler.swift`.

This document addresses the remaining scroll/visual behavior. Preserve recent scheduler improvements rather than redoing them.

## 4. Confirmed causes in the current code

Paths in the following sections are relative to `app/HeadsDown/`.

### 4.1 Scroll explicitly disables all region covers in Balanced/Relaxed

`Controller/SessionController.swift`, `userScrolled()`:

```swift
lastScrollAt = Date()
dirtyReasons.insert(.scroll)
holesClosedByScroll = true
render()
```

`Controller/SessionController+Pipeline.swift`, `frontLayer(_:)`:

```swift
let geometryFresh = !layoutChanged && !holesClosedByScroll
// Balanced / Relaxed:
covered = geometryFresh && decision?.visibleIntent == false
```

When scrolling makes `geometryFresh` false, every non-Strict region stops contributing to `coveredRegions`. This is a deterministic exposure path, not just slow Jev inference or a missing cache entry.

Strict mode behaves differently: the whole target stays covered, but keep holes close. That avoids the all-unblur behavior at the cost of temporarily obscuring useful content. Do not describe the two modes as having identical failure behavior.

### 4.2 There is no scroll-container motion model

Current region bounds are screen-space rectangles. There is no retained mapping from each region to a particular scrolling container, stable child anchor, or measured content displacement.

`AXContainer` currently stores only rectangle, role, subrole, and depth. `AccessibilityReader` discards the element/ancestry associations needed for targeted anchor updates. A smooth tracker cannot simply consume persistent AX identifiers that already exist; that plumbing must be added where supported.

A wheel event indicates input, not actual content displacement. Momentum, acceleration, overscroll, nested panes, sticky headers, and animations mean its delta is not a reliable translation for every rectangle in a window.

### 4.3 Raw pixel changes also invalidate the whole layout

The pipeline compares a thumbnail with the baseline used for OCR. A large changed fraction marks `layoutChanged`, and changed cells close keep holes.

Normal scrolling changes most pixels even when all visible content is simply translated. If a new tracker moves the boxes but raw baseline comparison still treats the same movement as a destructive layout change, `frontLayer()` will continue suppressing them.

The fix must integrate motion-aware freshness with dirty-state evaluation, not merely translate rectangles immediately before drawing.

### 4.4 Blur refresh is low-rate and runs synchronously in ingestion

`Capture/Thumbnail.swift`:

- A small color capture is retained for blur.
- A 192-pixel-wide grayscale copy drives change detection.
- Changed cells are 8×8 thumbnail pixels; this is coarse for precise scrolling alignment.

`Overlays/BlurRenderer.swift`:

- One shared `CIContext` already exists.
- Blur radius is 22 screen points, scaled to the captured image width.
- Color is preserved; no dark tint is currently applied.
- Image edges are already clamped and the output cropped to the input extent.

`SessionController+Pipeline.ingest` calls `BlurRenderer.cover(from:)` synchronously when detected pixels change. The controller is main-actor isolated. Increasing capture cadence without moving image processing off that path could hurt UI/escape responsiveness.

Current ticks are about every 400 ms plus work. That is around 2.5 updates/second at best, not a smooth scroll-following loop.

### 4.5 Appearance refresh can miss changes that grayscale ignores

`ingest` decides whether to refresh the color cover using a thresholded grayscale diff. A color-only change or subtle visual change below that threshold may leave the cover image stale.

Do not use one threshold for both semantic reanalysis and visual freshness. It is valid to update blur imagery without rerunning OCR/Jev.

### 4.6 Scroll-moving control holes can remain at old positions

`frontLayer()` always subtracts `controlRects` from coverage. Those rectangles come from the last AX read; they are not independently tracked during scrolling.

Fixed window chrome can stay in place, but an in-content button/field may move with a pane. Leaving its old hole visible can expose content at the wrong location. Update or suppress moving-content exemptions when their bounds are uncertain. Preserve real escape/navigation chrome.

Current AX code already excludes links from control exemptions and caps control size. Do not claim all links are currently exempt or redo those fixes unnecessarily.

### 4.7 Paid classification already waits for scroll reconciliation

The current `classificationGateDelay()` blocks dispatch while `.scroll` is dirty, then waits for the configured quiet interval. `syncClassification()` only offers uncached current inputs to the scheduler.

Retain that separation. The remaining visual problem should not be solved by bypassing the scheduler or classifying intermediate positions more frequently.

## 5. Recommended architecture: independent rates and responsibilities

```text
Scroll/input hints + current window ownership
                     │
       lightweight motion/geometry lane
       identify pane → measure movement → update masks
                     │
       fast visual coverage / safe fallback
                     │
       appearance refresh from clean captured frames

After content settles:
       OCR / AX reconciliation → current semantic regions
                     │
       cached score reuse / existing Jev dispatch scheduler
```

Three independent concerns:

1. **Geometry:** where a known piece of content is now.
2. **Semantics:** whether that piece of content is related to the task.
3. **Appearance:** the image used to obscure its current pixels.

Do not invalidate semantic scores because geometry moved. Do not wait for new scores to maintain a known cover. Do not attach fresh images to old, unvalidated geometry.

## 6. Stage one: remove the exposure immediately

Implement a safe scroll transition before pursuing perfect tracking.

### On scroll start

- Determine the affected scroll container from current bounded AX structure and event location where possible.
- Preserve unaffected panes/sidebar regions and their valid covers.
- If the moving content's new positions are not yet known, mask the affected container's **validated visible content viewport**.
- For Balanced/Relaxed, apply this continuity fallback when that affected container had active coverage or when coverage must be maintained pending reconciliation. Do not indiscriminately mask an unrelated all-visible pane on every wheel event.
- If pane identity cannot be established, a bounded fallback to the target's safe content envelope is acceptable when existing covers otherwise would disappear. Exclude chrome, occluders, our controls, and unrelated windows.
- Preserve Strict's safe whole-content coverage while tracking its keep holes conservatively.
- Observe mode remains non-hiding.

### On settle

- Keep the transition mask until replacement region geometry/policy is ready.
- Reuse existing scores; do not wait for Jev to re-answer unchanged inputs.
- Atomically swap the transition state to the reconciled scene.
- Never clear the cover first and add its replacement in a later frame.

Do not fix the current bug by simply deleting `geometryFresh` checks and retaining stale rectangles at their old screen positions. That trades flashing for obscuring unrelated content.

## 7. Stage two: track scrolling content

### 7.1 Add bounded container identity and region ownership

Represent at least:

- Owner process/window and target generation.
- Scroll-container identity with a current visible viewport.
- The regions and control exemptions belonging to that container.
- Fixed/sticky versus scrolling anchors where evidence supports the distinction.
- Baseline capture/frame identity and measured cumulative displacement.
- Last trustworthy geometry timestamp and tracking confidence.

Prefer AX element handles/identifiers and ancestry when available, scoped to a process/window lifetime. AX references can become invalid or be recycled; revalidate them and never treat a coordinate or sibling index as permanent identity.

Do not traverse the full accessibility tree at display refresh rate. Read structure on acquisition/reconciliation, then poll a small bounded set of useful anchors off the main actor. Existing AX messaging calls can take up to their timeout, so AX alone cannot be assumed to supply 30–60 Hz tracking.

### 7.2 Measure actual movement

Preferred evidence order:

1. Valid current frames of known AX content anchors inside the identified scroll container.
2. Lightweight frame-to-frame visual translation/registration of that container's clean image crop.
3. Temporary container mask when neither source is reliable.

For visual fallback, use native image-registration capabilities if suitable and supported by the installed SDK, or a small bounded translation estimator. Start with a translation model for normal pane scrolling; don't build a generic scene-understanding system.

- Estimate motion from several content features/anchors, not a single repeated text line.
- Reject inconsistent motion, insufficient overlap, repetitive/featureless content, and jumps larger than trustworthy overlap permits.
- Exclude fixed chrome, sticky headers, other panes, videos, and overlay pixels from a shared translation estimate.
- Treat nested panes separately.
- Use wheel phase/momentum information to schedule tracking and find the likely pane, not as authoritative pixel displacement.
- Include horizontal scrolling in the data model even if the first reliable behavior is vertical translation.
- If sticky elements change attachment state or layout reflows, stop translating that group and reconcile/fallback.

A tracked rectangle can be expressed as:

```text
current rectangle = baseline rectangle + verified content displacement
visible portion = current rectangle ∩ current pane viewport ∩ target coverage area
```

Use measured, validated displacement in canonical points. Apply point/pixel transforms through `Capture/Geometry.swift`; don't scatter Retina scale or Y-flip arithmetic.

### 7.3 Clip and retire correctly

- Remove a rectangle as its content exits the viewport; don't leave it hovering over incoming content.
- Clip partial regions at pane edges and higher-window occlusion boundaries.
- Do not move sidebars, toolbars, sticky headers, or another pane with the scrolling body.
- Transform scrolling control/reveal holes with their owned content, or suppress them until revalidated.
- A user reveal stays associated with content identity, not a permanent hole at a screen position.
- Keep stable anchored regions semantically intact: a viewport-edge crop must not create a different model input just because the visible fragment shrank.
- New text replacing an old item at the same location/virtualized AX element still needs a new semantic identity.

### 7.4 Handle newly exposed areas

Compute newly exposed strips/areas from the transformed viewport overlap. Those areas have no validated existing region map.

- Do not project an old keep hole into them.
- Retain Strict's coverage for unknown content.
- In Balanced/Relaxed, use the bounded transition fallback described above while re-establishing coverage; do not silently make the entire session permanently Strict.
- After scrolling settles, inspect new areas and relevant boundaries, reuse unchanged regions, and schedule only actual uncached semantic inputs.
- Use a full read for large jumps, navigation, ambiguous reflow, or failed tracking rather than attempting an unsafe partial merge.

### 7.5 Reconcile drift instead of accumulating it forever

- Associate every transform with a particular frame/capture baseline.
- Re-anchor to fresh AX/OCR observations after scroll settle.
- Bound accumulated prediction error and tracking lifetime.
- Let actual content identity/context changes invalidate scores as before.
- When visual correspondence supports translation, avoid classifying the translated pixels as an unrelated large layout change.
- Compute residual change after alignment for deciding what truly changed; do not disable layout detection globally.
- A failed motion estimate should trigger a fallback mask/re-read, not continued blind translation.

## 8. Capture and cadence

Suggested initial motion target: **15–30 geometry/visual updates per second during active scrolling**, backed off when idle. This is a starting budget, not a guarantee of smoothness on every app or display.

A 192-pixel-wide thumbnail can support coarse change detection, but subpixel motion at that size can translate to visibly wrong desktop placement. Keep blur input low-resolution if useful; allow a separately sized tracking crop where precision requires it.

Do not drive full-resolution `SCScreenshotManager.captureImage` calls, full AX scans, or OCR at 30–60 Hz.

For sustained fast tracking, a bounded **ScreenCaptureKit stream** is the recommended capture direction:

- Reuse frames for tracking and blur rather than repeatedly launching independent screenshot requests.
- Use frame status to skip idle/incomplete frames.
- Use dirty rectangles as hints for where pixels changed, not evidence that content identity changed.
- Keep a small queue and latest-frame-wins processing; drop superseded frames rather than building latency.
- Preserve application/window exclusion so the tracker never follows its own covers.
- Use content rect/scale metadata and the existing canonical geometry conversions.
- Adapt capture resolution/rate to active scrolling versus idle observation.
- Bound buffer retention and release replaced frames.

Implement the no-flash fallback first. A stream migration must not delay that smaller fix. If implementing tracking with the existing screenshot path initially, cap the rate conservatively and describe its limits rather than claiming smooth 60 Hz tracking.

Apple references:

- https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo
- https://developer.apple.com/videos/play/wwdc2022/10156/
- https://developer.apple.com/videos/play/wwdc2022/10155/

## 9. Blur/rendering optimization

### 9.1 Keep the existing useful pieces

The current renderer already has:

- A reusable `CIContext`.
- Low-resolution color input.
- Radius scaled to screen points.
- Clamped filter edges.
- Square coverage edges.
- A placeholder when no image exists.
- Per-window transparency layers so holes do not erase other windows' covers.

Preserve these properties. This request is not to darken the effect or retune its visual strength; the current blur intentionally keeps real colors.

### 9.2 Move expensive image work out of main-actor ingestion

- Run image conversion/filtering on a bounded worker/actor appropriate for the chosen graphics APIs.
- Allow at most one blur render in progress and one newest pending source frame; discard superseded queued inputs.
- Keep lightweight scene geometry updates and final AppKit publication on the main actor.
- Tag results with window/display, capture/visual generation, scale, and rendering configuration.
- Ignore a completed image if it belongs to an obsolete target or paused/stopped session.
- Keep a valid existing cover or placeholder while the next image is prepared.

Do not spawn one detached image-processing task per capture without bounds.

### 9.3 Avoid unnecessary regeneration

- Geometry movement, a new classifier score, toggling debug boxes, and a reveal change do not inherently require another Gaussian blur.
- Reuse the current blurred source where its frame transform remains valid.
- Reuse a translated prior source only within verified overlap; provide a fresh image/placeholder for newly exposed areas rather than stretching old edge pixels into new content.
- Recompute when source imagery, scale, blur settings, or target geometry genuinely requires it.
- Separate appearance freshness from OCR/semantic thresholds. Color changes can warrant a fresh cover without any classifier call.
- Share filtered source imagery among masks over the same valid window/frame rather than blurring every tiny region independently.
- Never translate a whole-window source as if all its panes/chrome shared one scroll offset.

### 9.4 Atomic scene publication

Publish a coherent bundle containing:

- Current validated target/occlusion geometry.
- Per-pane transforms and viewport clips.
- Cover image with its own frame/coordinate mapping.
- Current masks, keep/reveal holes, and eligible control exemptions.

Do not publish new rectangle coordinates with an unrelated image mapping and then repair them later. Do not briefly publish an empty scene between old and new covers.

The existing `OverlayView.draw` clears the full view and redraws all layers. At higher rates, consider invalidating only the union of old/new affected bounds or using cached layers, while preserving transparent clearing and window order. Avoid a premature full renderer rewrite; keep work proportional to what moved.

### 9.5 Preserve occlusion and escape behavior

- The overlay remains click-through/nonactivating.
- Never move a mask onto Heads Down controls, a permission dialog, or another app based on an obsolete window snapshot.
- Pause/Stop removes coverage immediately and invalidates all pending visual publications.
- Window switch/movement/resize, Spaces change, lost capture permission, or unsupported full-screen transition invalidates affected tracking immediately.
- Reacquire trustworthy bounds before covering the new target.
- Retained background-window covers must be re-clipped against current stacking; don't accidentally move them when the foreground pane scrolls.
- No old scroll completion, blur task, or timer may restore coverage after stop/pause.

## 10. Integrate without undoing classifier cost improvements

The tracker must not change canonical region text solely to express movement or a clipped viewport rectangle.

Continue to use:

- `syncClassification()` for current uncached inputs.
- `ClassificationScheduler` for once-per-second rounds, concurrency, deduplication, usage accounting, and lifecycle handling.
- `classificationGateDelay()` / scroll quiet logic for paid dispatch eligibility.
- The current task/model/question/context-aware score cache.

Tracking a cover at 20 Hz must not cause 20 calls to `syncClassification()` with newly fabricated identities, let alone 20 Jev calls. Geometry updates can render directly. Semantic input reconciliation occurs only when content evidence warrants it.

Cached decisions can become visible/covered immediately once tracking/reconciliation establishes valid geometry; they do not need to wait for the next paid dispatch round.

## 11. Suggested file responsibilities

| Path under `app/HeadsDown/` | Work |
|---|---|
| `Controller/SessionController.swift` | Scroll start/update/end lifecycle; owner generation; adaptive motion scheduling; immediate pause/stop cleanup |
| `Controller/SessionController+Pipeline.swift` | Replace all-or-nothing scroll freshness with pane-aware tracking/fallback; motion-aware dirty detection; atomic rendering; post-scroll reconciliation |
| `Controller/Models.swift` | Scroll-container/anchor identity, tracked geometry, transforms, frame generations, fallback reason |
| New small scroll/motion tracker module | Bounded anchor/frame matching and confidence; keep it independent of classifier policy |
| `Capture/AccessibilityReader.swift` | Preserve usable pane ancestry/anchor references; targeted updates rather than full-tree high-frequency scans |
| `Capture/ScreenCapturer.swift` | Fast bounded frame source if streaming is introduced; preserve clean self-exclusion |
| `Capture/Geometry.swift` | Centralize viewport/crop/frame translations and scale conversions |
| `Capture/Thumbnail.swift` | Distinguish coarse semantic diffs, motion evidence, and appearance changes |
| `Capture/ContentEnvelope.swift` | Validated pane fallback envelope and fixed chrome exclusions |
| `Regions/Segmenter.swift` | Attach pane ownership/anchor metadata; stable section identity across translation; reconcile new boundary content |
| `Overlays/BlurRenderer.swift` | Bounded off-main render work, image reuse, generation-tagged outputs |
| `Overlays/OverlayController.swift` | Per-pane masks/clips, safe image transforms, atomic publication, efficient redraw |
| `Controller/ClassificationScheduler.swift` | Preserve current behavior; only adapt integration boundaries if necessary |
| `App/InspectorView.swift` | Concise tracking/fallback status and existing local timing counters |
| `README.md` | Explain actual scroll support/fallback behavior and remaining limits |

New files under the project's synchronized source folder should follow its existing build setup. Do not introduce a project generator or recreate the Xcode project.

## 12. Implementation order

1. **Close the exposure path:** preserve unaffected covers and add a scoped transition mask instead of empty Balanced/Relaxed coverage.
2. **Separate visual work:** move blur filtering off main-actor ingestion, bound pending work, keep atomic image/scene replacement.
3. **Add pane/anchor ownership:** establish which content actually scrolls and which UI stays fixed.
4. **Track verified translation:** move masks and associated holes, clip viewport exits, handle new strips, fall back on uncertainty.
5. **Integrate motion-aware dirty state:** scrolling translation must not immediately invalidate the tracked geometry through the old raw-diff path.
6. **Reconcile after settle:** re-anchor, reuse scores, read newly exposed/changed content, retain the existing Jev dispatch gate.
7. **Improve active-scroll capture cadence:** use a bounded frame stream where needed, with idle backoff and independent appearance refresh.
8. **Update short diagnostics/docs:** state what works and where fallback masking remains necessary.

Do not solve this by lowering the OCR interval, increasing Jev concurrency, deleting geometry safeguards, or hardcoding one page's layout.

## 13. Lightweight runtime status, not new instrumentation infrastructure

Use existing privacy-safe Inspector/log surfaces for a small set of fields:

- Scroll pane identity (session-local only), tracking state and fallback reason.
- Translation source (AX anchors / visual registration / fallback).
- Number of translated/reused regions versus newly exposed regions.
- Geometry/capture/blur cadence and dropped superseded frame count.
- Whether a cover image was reused, rebuilt, or replaced by a placeholder.
- Existing classifier request/cache counters, so moving covers aren't mistaken for rescoring.

No screenshots, task/region text, titles, API keys, or full accessibility trees in logs. Don't create a telemetry system or benchmark workstream.

## 14. Build and report back

Use the existing build command:

```bash
xcodebuild -project app/HeadsDown.xcodeproj -scheme HeadsDown -configuration Debug \
  -derivedDataPath app/build build
```

No automated tests or test plan are requested.

Report:

- What now follows content versus uses a temporary container mask.
- Which scroll layouts are supported: simple pane, nested panes, sticky UI, large jumps.
- How unchanged decisions and blurred imagery are reused.
- The actual visual/geometry refresh approach and any measured timings already available.
- Build status, permission/setup needs, and remaining unverified behavior.

Do not claim visual smoothness, correct live alignment, or a fixed frame rate from source inspection or a successful build alone. Snapshot/stream-based overlays are still an approximation of the target app's own compositor; fallback behavior is part of the product, not a failure to hide.

**Core principle:** keep semantic decisions stable, track geometry independently, and maintain continuous coverage while replacing visual evidence. Scrolling should move or safely replace the cover—not make the content visible until the whole AI pipeline catches up.
