# Heads Down

A macOS focus mode. You type what you're working on; Heads Down reads the text in the front window,
groups it into regions (a card, a message group, a sidebar section, a paragraph group), asks a
local model whether each region would pull you away from the task, and can dim or blur the
distracting ones. No blocklist, no site-specific rules, and screen text never leaves the laptop.

Status: development prototype. See [Limitations](#limitations).

## Pieces

| Part | What it is |
|---|---|
| `app/` | Native Swift menu-bar app (SwiftUI + AppKit, ScreenCaptureKit, Accessibility, Vision, Core Image) |
| `laya-serve` | The existing local Python model server (`laya[serve]` 0.3.26) on `127.0.0.1:8077` |
| `bench/` | Earlier Laya benchmark; see `bench/FINDINGS.md` |

## Run it

### 1. Start the classifier (optional for region boxes, needed for scores)

From the repo root:

```bash
USE_TF=0 LAYA_MODELS=english LAYA_PORT=8077 LAYA_HOST=127.0.0.1 LAYA_DEVICE=mps .venv/bin/laya-serve
```

Wait for `Application startup complete`. Stop it with Ctrl+C. The app doesn't start or stop the
server itself.

### 2. Build and launch the app

```bash
xcodebuild -project app/HeadsDown.xcodeproj -scheme HeadsDown -configuration Debug \
  -derivedDataPath app/build build
open app/build/Build/Products/Debug/HeadsDown.app
```

Or open `app/HeadsDown.xcodeproj` in Xcode and press Run. Requires Xcode 16+ (built with Xcode 27);
deployment target macOS 15.

An eye icon appears in the menu bar. There's no Dock icon (`LSUIElement`).

### 3. Permissions

| Permission | Needed for | Notes |
|---|---|---|
| Screen & System Audio Recording | Reading the screen. Required. | Requested when you press Start. After allowing it, macOS may require quitting and reopening the app. |
| Accessibility | Structured text and container bounds. Optional. | Without it, the app runs OCR-only and says so. |

No other permissions are used. Global shortcuts use Carbon hot keys, which need no Input
Monitoring permission.

**Signing:** the app is ad-hoc signed (no signing identity on this machine). macOS ties the
permission grants to the exact build, so **after a rebuild you may need to re-enable Heads Down in
both Privacy panes** (toggle off/on, or remove and re-add it). The app is not sandboxed and has no
hardened runtime; it needs no entitlements for this local prototype.

## Using it

1. Click the menu-bar icon, type your task, and press **Start**.
2. **Observe** mode (default) hides nothing: numbered boxes show each region with its score.
   Gray = no score, green < 0.50, orange 0.50–0.80, red ≥ 0.80.
3. **Open Inspector** shows the covered app/window/display, skipped areas, each region's text,
   source (AX/OCR), bounds, grouping reason, score and policy, plus timings for the last cycle.
4. Switch to **Dim** (darkens regions ≥ 0.50) or **Blur** (blurs ≥ 0.80 and dims 0.50–0.80) when
   you're satisfied the boxes are in the right places.

| Action | How |
|---|---|
| Pause / resume (clears every overlay immediately) | **⌃⌥⌘P**, or Pause in the menu-bar panel |
| Reveal one region for 10 minutes | **⌃⌥⌘R** with the pointer over it, or select it in the Inspector → Reveal |
| Stop | Stop in the menu-bar panel (also on Quit) |
| Change task | Edit the task text → **Update task** (drops all previous decisions) |

Overlays are click-through and never take focus. Pause and Stop work even when the classifier is
hung, because classification runs asynchronously with a timeout.

## How it works

Once started, the loop runs by itself:

- **Every 400 ms:** find the frontmost normal window on the selected display and the windows above
  it. Take a 192-px-wide grayscale capture and compare 8×8 cells with the frame the regions came
  from. Any region over a changed cell is hidden immediately, without waiting for the model.
- **When content has settled** (and at most once per second; once per 3 s if it never settles):
  capture the window at full resolution (excluding Heads Down's own windows through
  ScreenCaptureKit's filter, not hide/show), read the accessibility tree within limits (4,000 nodes,
  depth 64, 0.6 s, 0.25 s per call), and run Vision OCR in parallel.
- **Merge:** keep AX text only where OCR also sees text (AX can expose hidden content). Drop OCR
  lines already covered by AX text. Drop anything under a higher window.
- **Group** (`Regions/Segmenter.swift`): accessibility containers of plausible size pull their text
  together and lend their frame to the region. Other text joins by line/column proximity, never
  across containers. Oversized blocks are split; overlapping blocks are merged.
- **Classify:** only regions whose (app, title, text) have no cached score for this task are sent,
  in batches of up to 16, to `POST /v1/systemone/batch` using the exact question from
  `bench/cases.py`. Missing, malformed, or out-of-range scores count as *unknown* and are left
  uncovered. Failures put the app in a visible degraded state with backoff (2 s → 30 s).
- **Apply:** results are discarded unless the session, task revision, cycle, and window geometry
  still match. Policy: ≥ 0.80 blur, 0.50–0.80 dim, otherwise leave alone. Regions with no score,
  regions you revealed, and regions overlapping another window are always left uncovered.

Blur crops the clean captured frame and blurs it with Core Image. It is a snapshot, not live, so
moving content under it looks frozen until change detection removes it.

All geometry uses one coordinate space (Quartz global points); conversions live in
`app/HeadsDown/Capture/Geometry.swift`.

## Privacy

- Screenshots and extracted text stay in memory. Only the newest frame is kept, and only for blur crops.
- Region text goes only to the local loopback Laya server. Screenshots are never sent.
- A local timing log (on by default, toggle in the Inspector) is written to
  `~/Library/Logs/HeadsDown/cycles.jsonl` (rotated at 2 MB). It contains only session-local IDs,
  counts, AX/OCR source flags, timings, scores/actions, and error categories. It never contains
  screen text, task text, window titles, or images. Inspector → Delete log removes it.
- A hosted classifier (e.g. Jev) would need its own adapter and explicit opt-in, because region
  text would then leave the laptop.

## Limitations

Known by design in this version:

- **Front window on one display only.** Other visible windows aren't analyzed. Multi-monitor:
  you pick one display.
- **Full-screen windows aren't covered.** The app clears overlays and says so.
- Areas under other windows are skipped. Windows at layer ≥ 1000 (e.g. a dictation utility's
  always-on-top overlay window) are *assumed transparent* and not treated as covering the target.
  The Inspector lists them. A real opaque window at that level would be wrongly ignored.
- **English text only.** Images, video, and canvas content aren't understood. Empty OCR means
  unknown, not safe or distracting.
- **OCR-only regions (Chrome, Electron apps such as Slack/VS Code/Discord, and any app without
  useful accessibility data) cover text blocks, not whole cards**, so thumbnails/backgrounds next to
  the text stay visible. Chrome and Electron don't expose web content to accessibility unless
  assistive tech asks for it; Heads Down doesn't flip that switch.
- Constantly changing content (video, animations, a ticking clock) keeps its region hidden and
  triggers a re-read at most every 3 s.
- Blur is a frozen snapshot; dim is a dark rectangle, not blur.
- Classification quality is the benchmark's: Laya often judges the site instead of the content
  (see `bench/FINDINGS.md`: 5–6 of 11 tricky cases right, from 48 agent-labeled examples). This
  version doesn't try to fix that.
- Ad-hoc signing means permissions may need re-granting after rebuilds.
- This is rule-based orchestration of local tools (capture → AX/OCR → grouping → classifier →
  overlay), not an LLM deciding which tools to call.

Checked during the build (2026-10-03):

- The project builds with `xcodebuild`, launches as a menu-bar app, and quits cleanly.
- The Laya batch response envelope was confirmed against a real response from the running server
  and `laya/serve.py` (`results[i].answers.distracting.noul`, in request order).
- In a throwaway check (not kept), the real OCR → Quartz conversion, segmentation, and blur
  cropping ran on a synthetic two-column image: boxes landed at the drawn positions with no y-flip,
  the main column and two sidebar cards became separate regions, and the pixel crop math was exact.

**Not yet verified:** live capture, AX reads, overlay alignment on the real screen, dim/blur
appearance, shortcuts, and end-to-end latency. These need Screen Recording permission and a hands-on
session (see the handoff checklist in `IMPLEMENTATION_HANDOFF.md`, §6 coordinate warning).
Record real failures here as they're observed.

## Developer notes

- Source layout: `App/` (menu bar, inspector, shortcuts), `Controller/` (session loop, models),
  `Capture/` (window locator, ScreenCaptureKit, AX, geometry, thumbnails), `Recognition/` (Vision OCR,
  AX/OCR merge), `Regions/` (segmenter), `Classification/` (provider protocol, Laya client),
  `Policy/`, `Overlays/`, `Diagnostics/`.
- The Xcode project uses a file-system-synchronized folder: new files under `app/HeadsDown/` are
  picked up without editing the project file.
- `app/scripts/gen-compile-commands.sh` writes a `compile_commands.json` (gitignored) so
  SourceKit-LSP in editors sees the whole module. Editor tooling only.
