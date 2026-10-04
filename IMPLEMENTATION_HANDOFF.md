# Heads Down — implementation handoff

**Recipient:** Opus 5-5 (Cloudbridge)  
**Repository:** `/Users/ankojh/b12/heads-down`  
**Purpose:** Implement the first usable local macOS prototype, following the decisions below.  
**Status:** Planning and benchmarking only; no macOS app has been built. This document does not claim otherwise.

## 1. Read this first

Read these files before implementing:

1. This document: current direction and implementation details.
2. `HANDOFF.md`: previous agent's environment/setup notes.
3. `bench/FINDINGS.md`: measured Laya behavior and limitations.
4. The relevant source in `bench/` when integrating the classifier.

This document supersedes the earlier recommendation to prioritize model quality. The user now explicitly accepts imperfect classification and wants to tackle macOS screen segmentation and the working pipeline.

**User instruction for this handoff: do not spend time adding tests.** Do not create an automated test suite, CI, test fixtures, or a new benchmark project. Preserve the existing benchmark files. Build/run checks and brief hands-on inspection are still needed to avoid handing over an app that does not launch or whose overlays cannot be dismissed; keep those lightweight and do not turn them into a testing workstream.

Do not commit or push without asking the user. Do not delete or rebuild the existing environment unnecessarily. Applicable user instructions say to ask before starting when a request is ambiguous or has several reasonable approaches; don't ask about facts you can inspect locally. The agreed direction below should not be reopened without a concrete blocker.

## 2. Product intent and agreed direction

Heads Down is a focus mode that judges visible content against the user's current task and obscures distracting portions of the screen. It should work dynamically across apps and sites, not rely on a website blocklist or site-specific DOM selectors.

The important unit is a **coherent region**, not a whole app and not every individual OCR line. Examples include a recommendation card, a message group, a sidebar section, or a document paragraph group.

### Decisions established with the user

- Build for the **macOS screen**, not a browser extension.
- Use a **native Swift app** with the existing **Python/Laya local service**.
- Use macOS accessibility information and Apple Vision OCR to derive regions.
- Start by visualizing numbered region boundaries, then attach classification, then blur.
- Classification accuracy is acceptable for now; do not spend the implementation phase tuning prompts or exploring embeddings/checkpoints.
- Keep the classifier replaceable with Jev later. Jev is hosted, so that migration would require explicit privacy disclosure/consent, not just changing a URL silently.
- The user wants the system to be **agentic/autonomous** rather than manually triggering every screen check.
- Use typed task input initially. Calendar integration can wait.
- No implementation was performed during the planning conversation.

### Important nuance about autonomy

A controller that selects when to read accessibility data, OCR, reuse results, classify, and update overlays can operate autonomously. It is not the same as an LLM deciding which tools to call.

Do not claim that Laya is a general planner: the existing work only evaluates its classification ability. Do not add a cloud LLM or a second large local model without approval. Implement a bounded, observable autonomous controller first, with clean tool/service boundaries. If the user requires an LLM-driven planner specifically, that remains a separate decision; do not silently equate rule-based orchestration with that requirement.

### Suggested first-version defaults, not additional user commitments

Use these as a small initial scope unless the user directs otherwise:

- One selected display; no claim of multi-monitor support yet.
- Begin the first segmentation milestone with the frontmost normal application window on that display; explicitly show this coverage limitation in the UI/docs. Expand to other visible windows only when clipping/occlusion can be handled correctly.
- English text initially, consistent with the benchmark model.
- One nonempty user-entered task per session.
- Debug/observe mode first; user explicitly enables dim/blur afterward.
- Initial classification cadence roughly once per second at most, after content settles. Capture/change detection can be more frequent without running OCR/classification on every frame.
- No image/video semantic understanding, browser scripting, calendar connection, accounts, installer, or distribution work.

The ultimate product is screen-based. A frontmost-window-first milestone is an engineering boundary, not a pivot to a browser product or a claim that all visible windows are supported.

## 3. Current repository and environment

Checked while writing this handoff:

- Repository is on `main` with **no commits yet**.
- `.gitignore`, `HANDOFF.md`, and `bench/` were untracked before this handoff was added.
- `.venv/bin/laya-serve` exists.
- Python environment is the previously created Python 3.12 environment.
- Machine: M3 Max, 48 GB RAM, per benchmark findings.
- `sw_vers` reports macOS 27.0.1, build 26A434.
- `xcode-select -p` reports `/Applications/Xcode.app/Contents/Developer`.
- Swift and PDFKit successfully ran while extracting the rubric; the macOS app toolchain has not otherwise been validated.
- Previous handoff says `laya-serve` is stopped. Recheck availability; do not assume the port is free or take ownership of an unrelated existing process.

Existing code:

| Path | Contents |
|---|---|
| `bench/cases.py` | 48 hand-labeled regions, four tasks, 11 tricky cases; `QUESTIONS` and `state_for()` |
| `bench/quality.py` | Direct model invocation, score extraction, accuracy and latency reporting |
| `bench/phrasing.py` | Four question variants and their score decoding |
| `bench/load.py` | Actual single/batch HTTP request construction |
| `bench/FINDINGS.md` | Results, known failure patterns, reproduction commands |

There is no Swift project, app UI, OCR implementation, overlay implementation, calendar integration, or runtime decision controller yet.

## 4. Architecture and stack

```text
SwiftUI menu-bar controls
  task / start / pause / mode / status
                 │
          Session controller
                 │
     ScreenCaptureKit + window metadata
                 │
       Accessibility reader + Vision OCR
                 │
          Region segmentation
                 │
    Region tracking / change detection / cache
                 │
      Classifier protocol → URLSession
                 │
   localhost:8077 → existing laya-serve (Python/MPS)
                 │
        Validated distraction scores
                 │
          Policy / user overrides
                 │
       AppKit overlays + Core Image
```

### Native app

- **SwiftUI** for menu-bar UI, task entry, status, and settings.
- **AppKit** for nonactivating, click-through overlays and window behavior.
- **ScreenCaptureKit** for screen content and filtering the app's own windows out of capture.
- **ApplicationServices / Accessibility APIs** for available UI structure, text, and bounds.
- **Vision** text recognition for content not adequately exposed through accessibility.
- **Core Image** for actual blurred image crops.
- **Foundation / URLSession** for local HTTP requests and small JSONL diagnostics.
- Swift concurrency for processing; UI/overlay updates on the main actor. Bound AX/OCR work so a slow app cannot freeze controls.

Prefer a normal macOS `.app` development target with a stable bundle identifier and signing identity where available. Accessibility permissions and capture permissions are much less pleasant when launching changing, anonymous command-line executables. Use the installed Xcode tools. Keep project creation reproducible and document the launch path. Do not introduce a project generator solely out of habit.

For the local development prototype, do not let App Store sandbox/distribution requirements dominate the implementation. Document the chosen sandbox/signing setup and any actual entitlements needed; do not fabricate permissions or assume an entitlement bypasses user consent.

### Python side

Use the installed `laya-serve` rather than building another API server. No FastAPI wrapper is needed merely to forward the same request. Start with an explicitly documented manual server command; automatic child-process lifecycle management is later convenience work, not a dependency of the first capture milestone.

### Suggested source organization

These are suggested responsibilities, not a demand for one file per tiny type:

```text
app/
  HeadsDown.xcodeproj/
  HeadsDown/
    App/                 # entry point, menu-bar UI, task/settings controls
    Controller/          # session state, scheduling, cancellation, generation IDs
    Capture/             # ScreenCaptureKit, AX reads, coordinate transforms
    Recognition/         # Vision OCR, text observations
    Regions/             # grouping, tracking, fingerprints
    Classification/      # protocol, Laya client, payload/response models
    Policy/              # thresholds and temporary reveal overrides
    Overlays/            # debug boxes, dimming, blurred crops
    Diagnostics/         # bounded local metadata logs and timings
README.md                # build/run/permissions/limitations
bench/                   # preserve existing work
```

## 5. Core data contracts

Keep screen geometry, classification, and policy separate. Suggested internal entities:

### TaskSession

- Session ID and task revision.
- Current task text.
- Selected display ID.
- Mode: observe / dim / blur.
- Run state: stopped / requesting permissions / observing / processing / paused / degraded.
- User overrides scoped to this session and relevant region content.

### ScreenSnapshot

- Monotonic capture timestamp and generation ID.
- Display ID, image dimensions, capture scale/content rect.
- Current target app PID/bundle ID and window identity/bounds.
- Captured image held in memory.
- Coordinate mapping needed to place image-derived bounds in desktop space.

### TextObservation

- Text, bounding rectangle, and source (`accessibility` or `ocr`).
- OCR recognition confidence if available; it is not distraction probability.
- Optional accessibility role/container ancestry.
- Owning window identity and capture generation.

### ScreenRegion

- Transient tracking ID; owner window/display identity.
- Bounds in one documented canonical coordinate space.
- Combined text in reading order.
- Context: app name, window title, optional URL only if actually available.
- Source observations and segmentation provenance/reason.
- Content fingerprint and segmentation-quality metadata.

### RegionDecision

- Region ID, task revision, capture/generation association, content fingerprint.
- Provider ID/question version and validated `pDistracting`.
- Intended action: leave / dim / blur, plus override status.
- Decision timestamp and validity constraints.

Do not invent a model explanation when the model only returns a score. The UI may explain the threshold policy and which input was considered, but that is not a generated rationale from Laya.

Use content/task fingerprints for classification caching, but separately track current geometry. A region moving without changing its text should not necessarily need reclassification; an old rectangle must never be reused merely because the score is cached.

## 6. Screen capture, accessibility, and OCR

### Permissions

- Explain and request Screen Recording permission when the user starts capture.
- Explain and request Accessibility permission for structured UI reads.
- Report denied/revoked permissions clearly and provide a route to the relevant system settings.
- If capture is unavailable, pause rather than pretend to observe.
- If accessibility is unavailable, an explicitly labeled OCR-only mode may still be useful.
- Do not request broad input monitoring, browser automation, or unrelated permissions speculatively. Choose an emergency hotkey mechanism with the least permission footprint that works.

### Capture

- Filter out Heads Down's own app/windows, including overlays and debug labels, using ScreenCaptureKit's supported exclusion mechanism.
- Do not rely on screenshotting the overlays and trying to recover the original text afterward.
- Avoid hide/capture/show loops as the default; they can visibly flicker.
- Track screen/capture metadata rather than assuming image pixels equal screen points.
- Ignore incomplete/invalid frames and handle unavailable/protected content honestly.
- Start with visible pixels, not hidden background windows or arbitrary background app text.

### Accessibility

- Query the intended window's accessible structure with limits on node count, depth, and elapsed time.
- Collect useful text and container/role/bounds metadata; not an unbounded dump of every AX attribute.
- Some apps expose little useful structure; browser accessibility trees are not equivalent to a DOM and may not expose all content.
- Restrict observations to the selected visible area. AX may expose off-screen or occluded elements.
- In the first frontmost-window milestone, conservatively ignore areas overlapped by other visible windows/system surfaces. Do not overlay hidden window content on top of whatever happens to be visible there.
- If the window/content association is uncertain, skip that area rather than guess.
- A browser URL is optional. Do not add AppleScript/browser-specific integrations just to populate it.

### OCR

- Use Vision text recognition and retain bounding boxes, not just a concatenated string.
- Start with a documented recognition configuration suitable for English UI text. Tune speed/accuracy only if actual capture latency warrants it.
- Reuse a captured frame; do not take a different screenshot for every region.
- Where AX provides good text, use OCR as a supplement/fallback; do not blindly double-count the same words.
- Deduplicate overlapping AX/OCR observations using geometry and normalized text.
- Empty/unreadable regions are **unknown**, not proof of distraction or relevance.
- Video thumbnails, images, and canvas UI may remain poorly understood. Do not infer their meaning from empty OCR results.

### Coordinate system warning

This is a high-risk implementation detail:

- Vision boxes are normalized to the analyzed image and use an image-space origin convention.
- Capture images are pixels; AppKit placement is in points.
- AX/Quartz desktop coordinates and AppKit screen coordinates require explicit conversion.
- Cropping/scaling an image changes the transform.
- Desktop arrangements can include negative coordinates; don't bake primary-display-only formulas into reusable geometry code.

Centralize conversions. Record source dimensions, crop origins, scales, and display geometry. Convert deliberately rather than scattering ad hoc Y-axis flips. For the first display-only scope, visually confirm that boxes align at the top, bottom, and corners of the captured window before enabling blur.

## 7. Region segmentation: implement this before classification

Neither OCR nor accessibility returns the final answer automatically. Build a small, inspectable heuristic segmenter.

### Initial algorithm

1. Partition by owning visible window; never group text across windows.
2. Use useful accessibility containers as candidate boundaries where they correspond to visible, reasonably sized content.
3. Order OCR/text observations spatially; infer nearby lines/blocks using gaps relative to observed text height, alignment, and overlap.
4. Merge observations into coherent blocks using shared containers, proximity, column alignment, and whitespace separation.
5. Keep strong column/sidebar separation; avoid merging all text with similar vertical positions.
6. Reject giant containers when useful smaller children exist; don't treat a browser root node as a semantic region.
7. Split excessive blocks at large gaps/container boundaries and bound output count/work per cycle.
8. Add small visual padding and clip to the supported visible content area.
9. Resolve duplicated/nested candidates deterministically so the same content is not classified and blurred repeatedly.
10. Emit bounds, text, provenance, and a numbered debug overlay.

Prefer a handful of readable constants over an elaborate segmentation framework. Initial gap/size parameters are implementation heuristics, not evidence-backed universal thresholds.

Text boxes do not necessarily cover their associated image/card backgrounds. Use plausible container bounds when available; otherwise describe the overlay as text-block coverage. Do not claim semantic card segmentation from OCR line clustering alone.

Do not infer a website blocklist or add rules like “YouTube sidebar selector.” Safety rules about never covering Heads Down's own controls are allowed; they are not distraction classifications.

### Debug experience

The user should be able to:

- Start with a typed task and see numbered region rectangles.
- Inspect a region's extracted text, source, bounds, and grouping reason in a separate panel.
- See which app/window/display is currently covered and which areas were skipped.
- Toggle rectangles without changing capture semantics.
- Pause instantly.

Keep content inspection transient/in-memory by default; it need not be persisted to disk.

If the boxes are poor, show that clearly and improve the grouping before hiding content. Do not paper over poor segmentation by increasing blur area to the whole app.

## 8. Laya integration: preserve the existing question

### Startup command

From the repository root:

```bash
USE_TF=0 \
LAYA_MODELS=english \
LAYA_PORT=8077 \
LAYA_HOST=127.0.0.1 \
LAYA_DEVICE=mps \
.venv/bin/laya-serve
```

- `USE_TF=0` avoids a previously observed transformers/TensorFlow load hang.
- Bind to loopback only.
- Existing package version is `laya[serve]` 0.3.26.
- Model weights are already in the Hugging Face cache according to the previous handoff.
- If a model download is unexpectedly required, disclose it rather than silently installing/replacing the environment.
- If process management is later added, stop only a child process this app owns; avoid broad `pkill` calls.

### HTTP request

`bench/load.py` already sends this batch shape:

```http
POST http://127.0.0.1:8077/v1/systemone/batch
Content-Type: application/json
```

```json
{
  "model": "laya",
  "states": [
    {
      "current_task": "Studying prioritization frameworks for my PM quiz",
      "screen_region": {
        "app": "Safari",
        "title": "Example visible window title",
        "text": "Text extracted from this coherent region"
      }
    }
  ],
  "questions": {
    "distracting": {
      "type": "noul",
      "instructions": "Would looking at this screen region pull the user away from their current task?",
      "criteria": {
        "false": "Relevant to or supports the current task",
        "true": "Unrelated to the current task and likely to distract"
      }
    }
  }
}
```

Include `url` only if legitimately available. Do not submit screenshots; the model takes text/state.

The direct Python API returns per-state scores at:

```python
out["answers"]["distracting"]["noul"]
```

**Inspect the installed server implementation/OpenAPI or an actual batch response before defining the Swift response decoder.** The existing load script checks HTTP status but does not document the HTTP batch response envelope. Do not assume the direct Python list shape is the HTTP wrapper shape.

Validate result count/order association, required fields, and finite probabilities in `[0, 1]`. Missing, malformed, partial, timed-out, or rejected results mean unavailable/unknown, not `0` or `1`.

### Policy

Retain the original baseline:

- `p >= 0.8`: blur.
- `0.5 <= p < 0.8`: dim initially; avoid repeated modal questions.
- `p < 0.5`: leave.
- No valid decision or uncertain geometry: leave/uncover.
- User reveal override: leave until its documented expiry/content change/session boundary.

Call the value a distraction score/probability, not a guarantee. Keep segmentation quality separate from it: a high classifier score does not justify obscuring a badly localized region.

The keep/blur question variant scored slightly better on the small dataset, but the default `noul` question already supports the documented thresholds. Do not change wording or switch variants as incidental cleanup; phrasing is unusually sensitive.

Use a provider protocol along the lines of `classify(task:regions:) async throws -> [RegionScore]`. Geometry, tracking, and overlays should not know provider-specific JSON. Jev gets a separate adapter when requested; identical endpoint naming is not proof of identical authentication, schemas, semantics, or quality.

## 9. Scheduling, cancellation, and autonomous behavior

Use one session controller with explicit state and bounded work.

### Initial loop

1. User starts a nonempty task; permissions and capture readiness are checked.
2. Observe target window/display metadata and content changes.
3. When content settles and the analysis interval permits, capture/read structure.
4. Choose AX-only, OCR supplement, or OCR fallback based on usable observations.
5. Segment and track regions; update debug geometry.
6. Reuse classifications only where task/provider/question/content identity still matches.
7. Batch new/changed regions in one request.
8. Before applying results, verify the task/session/window/content generations still match.
9. Apply policy and current user overrides, then return to observation.

### Required safeguards

- At most one OCR/classification cycle in flight initially; newest work wins.
- Do not build an unbounded queue of old screenshots.
- A task change invalidates all previous decisions even if screen text is unchanged.
- Window switching/movement/resizing, scrolling, display changes, or content invalidation must clear affected overlays promptly; don't wait for the next model response.
- Fast capture-difference detection and AX/window notifications can invalidate coverage; not every app emits reliable scroll/layout notifications. Do not promise perfect tracking solely from AX events.
- Pause/stop cancels pending work and clears overlays immediately. Late results cannot make them reappear.
- Service failures cause a visible degraded state, bounded retry/backoff, and uncovered content.
- Avoid immediate repeated retries for HTTP 503 or other unavailable-service failures.
- No continuous user-input synthesis, automatic clicking, navigation, messaging, or unrelated actions.

Expose concise activity status such as “Reading screen,” “Grouping 8 regions,” “Checking 3 changed regions,” or “Paused: classifier unavailable.” This makes tool chaining visible without inventing a planner's private reasoning.

## 10. Overlays and correction controls

### Start with debug boxes, then dimming

Dimming is technically simpler and useful for validating geometry. It must not be presented as true blur. Add actual blur after placement and invalidation work.

### Actual blur

A practical initial technique is to crop the clean captured image, blur it with Core Image, and draw it in a nonactivating overlay at the corresponding location.

Trade-offs to acknowledge:

- This displays a processed snapshot, not a live compositor blur of arbitrary windows.
- Moving/video content requires refresh and can look frozen or laggy.
- Crop/filter edges need appropriate handling so padding doesn't sample incorrect content or expose unblurred edges.
- `NSVisualEffectView` is not automatically a reliable arbitrary cross-app screen-blur implementation; verify any alternative rather than assuming it solves capture and compositing.

### Window behavior

- Click-through and nonactivating by default; do not steal focus/keyboard input.
- Restrict coverage to the supported visible app content.
- Never cover the menu-bar controls, permission prompts, emergency controls, or unrelated system UI intentionally.
- Handle full-screen/Spaces behavior explicitly; if unsupported initially, pause/clear and disclose that limit rather than leaving orphaned overlays.
- Clear on stop, permission loss, target loss, app termination, and session changes.
- Keep a known-good last user escape mechanism even when the Python service hangs.

### Reveal controls

Provide:

- A global pause/resume shortcut with the actual binding displayed in the UI.
- An always-available menu-bar pause/stop action.
- A temporary reveal action for a selected/pointed region, through the control panel or a documented shortcut. Don't require clicking a click-through overlay.

Scope reveal overrides to task/session and content identity; don't accidentally turn one correction into a permanent site allowlist.

## 11. Performance expectations: measured versus estimated

Measured in `bench/FINDINGS.md` on this M3 Max:

- Warm single region over HTTP, MPS: p50 about 26 ms, p95 about 30 ms.
- Batch of ten regions: about 134 ms.
- CPU single-region inference: about 95 ms.
- Server RSS: about 930 MB.
- Server serializes inference; concurrent requests mainly add queueing. The load run saw 503s when overloaded beyond its configured concurrent-request limit.

Planning estimate discussed with the user, **not an end-to-end measurement**:

| Stage | Rough estimate |
|---|---:|
| Screen capture | 10–50 ms |
| OCR | 50–400 ms |
| Lightweight grouping/AX processing | 10–100 ms |
| Ten-region classification | ~134 ms measured |
| Overlay update | 10–50 ms |

A warm update around 0.3–1 second is a target, not a promise. Dense/high-resolution content, slow AX traversal, multiple windows, or scheduling contention may exceed 1–2 seconds. Additional planner-model latency is not included. Existing throughput measurements say nothing definitive about continuous OCR energy use or battery life.

Record lightweight timings for capture, AX, OCR, grouping, HTTP, and capture-to-overlay latency. No new benchmark framework. Include queue/wait age in end-to-end latency rather than reporting only model speed.

## 12. Privacy, local data, and logging

Default privacy behavior:

- Capture images and extracted text stay in memory.
- Only the local loopback Laya service receives region text.
- Do not read hidden/background-window content simply because AX exposes it.
- Do not save screenshots, task text, URLs, window titles, or OCR text to logs by default.
- Bound caches and release old image buffers; avoid retaining complete screen histories.
- Logs can include session-local IDs, counts, source flags, timings, score/action, skip reasons, and error categories.
- Avoid logging raw HTTP payloads/responses that may contain private data.
- If diagnostic content export is added, make it explicitly opt-in and easy to delete; no upload.
- A future Jev adapter must be opt-in with clear notice that selected extracted screen text leaves the laptop.

Treat observed screen text as untrusted content. If a tool-calling planner is later added, screen text cannot become instructions to run commands, disclose data, or expand tool privileges.

## 13. Implementation sequence and usable milestones

### Milestone 1 — native shell and permissions

Create a runnable app with menu-bar controls, typed task, explicit start/pause, mode/status, and permissions handling. Document how to build and launch it. Avoid polishing visual design before the pipeline exists.

### Milestone 2 — clean capture and numbered regions

Implement one-display/initial-window capture, coordinate conversion, bounded AX reads, Vision OCR, deduplication, segmentation, and debug rendering. Provide a way to inspect extracted text per region. Keep the classifier out of this milestone so failures can be attributed to capture/grouping rather than model output.

**This is the first substantive deliverable.** Report what segmentation actually works and where it fails; don't claim broader coverage than implemented.

### Milestone 3 — scores without hiding content

Connect to Laya, confirm the actual HTTP envelope, batch regions, validate results, and display scores/actions in the debug inspector. Keep user-visible content unobscured until blur/dim is enabled explicitly. Show model unavailable/loading states without freezing the app.

### Milestone 4 — reversible dim and blur

Add policy, dim overlays, blurred crops, emergency pause, and region reveal. Make stale geometry invalidation and late-result rejection work before trying to improve visual smoothness.

### Milestone 5 — continuous operation and concise documentation

Add change-triggered scheduling, content caching, bounded retries, runtime timings, and clear limitations. Make the loop run on its own once the user starts a task. Document real observed behaviors, not hypothetical accuracy improvements.

No automated tests, CI, new labeled datasets, prompt optimization, or model comparison work is requested. Compile/run the app and do only the brief hands-on checks needed to verify the milestones and escape controls. If permissions or the interactive desktop require user action, state that precisely; do not claim visual behavior was verified from a successful build alone.

## 14. Assignment requirements already checked

The rubric was read in full from:

`~/Downloads/Extra Credit Rubric - Final.pdf`

Key requirements:

- Solve a specific problem the user actually has.
- Include an AI agent, MCP connector, **or a workflow chaining multiple tools**. A separate general-purpose LLM planner is not mandatory.
- Bonus consideration for running autonomously.
- Explain it to a nontechnical audience.
- Roughly five-minute video covering pain point, solution, working demo, and challenges/limitations.
- The limitations section is mandatory and must describe specific build failures and how behavior was checked, not merely “AI sometimes gets things wrong.”
- Submission also requires a short written summary, permission-to-share decision, and the provided student-project disclaimer naming actual tools/brands used.

The user's exact personal distraction scenario and time cost are still unknown. Ask when needed for demo content; do not invent personal facts or block the capture plumbing on a marketing story.

Useful honest limitations already supported by evidence:

- Laya often judges the site rather than the content.
- Only 5–6 of 11 tricky benchmark cases were correct.
- The benchmark has only 48 agent-labeled examples, not real-world validation.
- The original >=0.8 blur tier contained 10 distracting regions out of 11; that is not a guarantee on real screens.
- Region grouping across arbitrary app layouts remains unproven.

Add implementation-specific limitations only as observed: missed containers, merged columns, poor OCR, AX gaps, stale blur, unsupported full-screen behavior, etc. The user declined time on tests; this does not justify fabricating demo evidence or omitting actual failures.

## 15. Explicit non-goals and decisions to avoid silently making

Not in the initial build:

- Browser extension or site-specific selectors.
- Whole-app/site blocking as a substitute for coherent regions.
- Calendar/OAuth integration.
- Jev setup, paid services, cloud screenshots, or another planner model.
- General-purpose visual scene understanding or image/video classification.
- New embedding models, Laya checkpoint experiments, or question tuning.
- Multi-monitor support and arbitrary multi-window coverage before geometry/occlusion are correct.
- App Store packaging, notarization, auto-updates, polished installers.
- Automated test/CI infrastructure.
- Git commits/pushes without permission.

Ask the user if implementation genuinely requires changing the chosen stack, introducing a cloud service, granting materially broader permissions, making a major scope cut, or deciding that an explicit LLM planner must be included now.

## 16. What to report back

Keep progress reports practical:

1. What now runs, and the exact build/launch command or Xcode steps.
2. Which milestone is complete and which app/display coverage actually works.
3. Required user permission/setup actions.
4. How to start, pause, reveal, and stop safely.
5. Measured latency if obtained; label unmeasured expectations clearly.
6. Specific known failures and the next smallest implementation step.

Start by inspecting the installed SDK/toolchain and setting up the native app shell, then move directly to the numbered-region capture milestone. The bottleneck to investigate is usable screen regions, not a more elaborate agent framework or a better classifier.
