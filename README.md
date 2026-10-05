# Heads Down

A macOS focus mode. You type what you're working on; Heads Down reads the text in the front window,
groups it into regions (a card, a message group, a sidebar section, a paragraph group), asks a
local model whether each region would pull you away from the task, and blurs the distracting ones. No blocklist, no site-specific rules, and screen text never leaves the laptop.

Status: development prototype. See [Limitations](#limitations).

## Pieces

| Part | What it is |
|---|---|
| `app/` | Native Swift menu-bar app (SwiftUI + AppKit, ScreenCaptureKit, Accessibility, Vision, Core Image) |
| Jev | TypeSafe's hosted classifier (default after one-time consent); key in `.env` |
| `laya-serve` | Local alternative: Python model server (`laya[serve]` 0.3.26) on `127.0.0.1:8077` |
| `bench/` | Earlier Laya benchmark; see `bench/FINDINGS.md` |

## Run it

### 1. Set up a classifier

**Jev (default, cloud).** Copy `.env.example` to `.env` at the repo root and set `TYPESAFE_API_KEY`
(from https://console.typesafe.ai/settings/keys). `.env` is gitignored. The model is pinned to
`jev-1.13.0`, the version benchmarked here (`jev-latest` resolved to it on 2026-10-03), so an alias
update can't silently change decisions; change `TYPESAFE_DEFAULT_MODEL` deliberately. The app finds it by walking
up from its bundle; set `HEADSDOWN_ENV_FILE` to use another path. On first Start, Heads Down asks once
before sending any screen text to TypeSafe. Declining switches to Laya.

**Laya (local, optional).** Start it if you pick Laya in the panel:

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

### 3. Google Calendar (optional)

Heads Down can start a focus session by itself from the event happening **now** in your primary
Google Calendar. It's off until you connect and turn it on; the typed task works without it.

1. In the [Google Cloud console](https://console.cloud.google.com/), create or pick a project and
   enable the **Google Calendar API**.
2. Configure the **OAuth consent screen** (External is fine for a personal account) and add your
   Google account as a test user while it's in Testing.
3. Create an OAuth client of type **Desktop app**.
4. Put its client ID in `.env` as `GOOGLE_OAUTH_CLIENT_ID` (and `GOOGLE_OAUTH_CLIENT_SECRET` if
   your client has one; for desktop apps it isn't a real secret). See `.env.example`.
5. In the panel: **Connect Google Calendar** → sign in in your browser → **Automatically start from
   the current event**.

Only `https://www.googleapis.com/auth/calendar.events.readonly` is requested. Google's scope covers
events on all your calendars; Heads Down reads only the primary one. Sign-in uses the system browser
with PKCE and a one-time listener on `127.0.0.1`; the refresh token goes to the macOS Keychain.
**Disconnect** stops calendar work, ends a calendar-started session, deletes the token, and asks
Google to revoke it.

While the consent screen is in **Testing**, Google expires the grant after about 7 days; reconnect
when the panel says authorization is needed. Workspace admins can block the app; public
distribution would need Google's OAuth verification.

### 4. Permissions

| Permission | Needed for | Notes |
|---|---|---|
| Screen & System Audio Recording | Reading the screen. Required. | Requested when you press Start. After allowing it, macOS may require quitting and reopening the app. |
| Accessibility | Structured text and container bounds. Optional. | Without it, the app runs OCR-only and says so. |

No other permissions are used. Global shortcuts use Carbon hot keys, which need no Input
Monitoring permission.

**Signing:** builds are signed with a local self-signed certificate, "Heads Down Local Signing".
macOS ties permission grants to the app's designated requirement (bundle ID + certificate), which
stays the same across rebuilds, so **you grant Screen Recording and Accessibility once**. Ad-hoc
signing was used before and made macOS forget the grants after every rebuild.

On a new machine, create the certificate once before building:

```bash
app/scripts/setup-signing.sh
```

It's for local development only (untrusted by anyone else; not for distribution). Remove it with
`security delete-identity -c "Heads Down Local Signing"`. The app is not sandboxed and has no
hardened runtime; it needs no entitlements for this local prototype.

## Using it

1. Click the menu-bar icon, type your task, and press **Start**.
2. **Blur** (default; the mode is remembered) blurs what the **hiding level** marks as distracting.
   **Dim** darkens it instead. **Observe** hides nothing and is for debugging only.

   | Hiding level | What is hidden |
   |---|---|
   | **Relaxed** | Text regions (and their card area) scoring ≥ 0.65 |
   | **Balanced** (default) | Text regions scoring ≥ 0.50; other content stays visible, except pending replacements of previously covered areas |
   | **Strict** | The whole window, except regions scoring < 0.50 |

   Windows you switch away from **keep their blur** while they stay visible and in place. Their
   cover comes from the last read while they were in front and is clipped wherever other windows
   overlap them. It's dropped if the window moves, closes, minimizes, or leaves the Space, and it's
   replaced when the window comes back to the front and is re-read.

   At every level, the window's top chrome (title bar, toolbar, tabs, address bar) and any
   **control** reported by accessibility stay visible: search and text fields, buttons, menus,
   tabs, toolbars, sliders. Links aren't treated as controls, because distracting feed titles are
   usually links. Changing the level re-applies the policy to cached scores without reclassifying.
3. Box colors (toggle "Show numbered region boxes"): green = below the level's cutoff, red = at or
   above it, gray = no score yet, blue = revealed by you.
4. **Open Inspector** shows per-session classifier usage: HTTP requests, provider-reported input
   tokens, an estimated cost at TypeSafe's published $0.042 per million input tokens (an estimate,
   not an invoice), retries/failures, cache hits, in-flight shares, and obsolete inputs skipped.
   It also shows the covered window, the cover actually drawn, the chrome strip left
   visible, each region's submitted text, score, verdict, and on-screen status, and the last cycle's
   trigger, timings, cache hits, and OCR reuse.

| Action | How |
|---|---|
| Pause for 3 min (or 2 min), then resume automatically | **Pause for 3 min** / **2 min** in the menu-bar panel |
| While paused | Countdown ("Paused · resumes in 2:17"), **Resume now**, **Stay paused**, or **Pause again** |
| Pause until you resume / resume | **⌃⌥⌘P** (emergency toggle, never timed), or **Pause** in the panel |
| Reveal one region for 10 minutes | **⌃⌥⌘R** with the pointer over it, or Inspector → Reveal |
| Stop (cancels any timed resume) | **Stop** in the panel (also on Quit) |
| Change task | Edit the task → **Update task**. Scores restart; regions stay covered until re-scored. Editing while paused stays paused. |

Every pause clears all coverage immediately. Overlays are click-through and never take focus.
Pause and Stop work even when OCR or the classifier is slow.

### Calendar auto-start

With auto-start on and Heads Down running in the menu bar (it can't act while quit), the primary
calendar is checked about every 30 s (jittered), right after wake or a clock change, and at known
event starts and ends. Detection is near-real-time: an event you just edited can take up to ~30 s
to be noticed.

- **Eligible events:** active now (start ≤ now < end), timed (not all-day), confirmed, a regular
  or focus-time event, busy (not "free"), and not declined or still awaiting your reply. Birthdays,
  out-of-office, working-location, and Gmail-generated events are ignored.
- **The brief** (the task the classifier sees) is built on the Mac from that one event: its title,
  its description with HTML, links, emails, phone numbers, dial-in/passcode lines, and meeting
  boilerplate removed, a short place name, and up to three attachment titles. At most 400
  characters. Attendees, join links, and attachment contents are never read or sent. Event text is
  treated as data, never as instructions. With Jev selected, this brief is sent to TypeSafe with
  every region (turning auto-start on asks once). No model is called for calendar data; the brief is
  deterministic (a compressor interface exists for a future opt-in model, none is configured).
- **Too little to go on** (e.g. "Busy", "Meeting" with no description, a private busy-only block,
  "Lunch"): the panel says the event has insufficient topic information and nothing starts.
- **Overlapping events:** the one already being followed stays selected. Otherwise, events with
  usable details come first, then focus time, then events you organize or accepted, then the most
  recent start. The panel shows how many others overlap. Events are never merged.
- **While the event runs** the brief stays the same unless its title, agenda, location, or
  attachment titles really change (then the task changes once, like editing it). RSVP churn, a new
  ETag, or a later end time don't reclassify anything; a later end only moves the end.
- **When it ends**, is cancelled, or becomes ineligible, the calendar-started session stops (also
  without network, at the known end time). If Google can't be reached, a calendar-started session
  is kept at most 2 minutes past the last successful check, never past the event's end. A failed
  check is never treated as "no event". A typed task is never affected by calendar problems.

What always wins over the calendar:

| You do | Calendar then |
|---|---|
| Start or apply a typed task (also over a calendar session: **Use my typed task**) | Never replaces or stops it; shows "Your typed task has priority" |
| **Stop** while an event is current | Skips that event (and any other current ones) until it ends, also across restarts; **Resume this event** undoes it |
| **Pause** indefinitely (button or ⌃⌥⌘P) | Starts nothing until you resume (or **Re-arm**) |
| Timed pause | Starts nothing during it; at expiry a calendar session resumes only if its event is still current |
| Turn auto-start off or **Disconnect** | Ends only a calendar-started session; your typed task stays |

**Edit as my task** copies the brief into the task field so you can adjust it and apply it as your
own. Starting automatically never changes the classifier, mode, or hiding level, and never shows a
permission dialog: grant Screen Recording (and Jev consent) when you turn auto-start on; if
something is missing later the panel says so instead.

## How it works

Once started, the loop runs by itself:

- **Every 400 ms (tick):** find the frontmost normal window on the selected display and the windows
  above it, and take a ~192-px capture of it (excluding Heads Down's own windows via
  ScreenCaptureKit's filter, never hide/show). That capture:
  - becomes the **cover**: a plain blur (≈ 22 pt) of the real colors, upscaled, so the cover follows
    the real content at ~2.5 fps without any OCR. The blur runs off the main thread (one render at a
    time, only the newest waiting source kept) and is rebuilt only when a small color grid changes,
    which is separate from the gray threshold that decides re-reading. The previous image (or a
    neutral placeholder) stays up until the new one is ready;
  - is compared in 8×8 cells with the frame the regions were read from. A local change keeps
    existing covers in place. Areas of a pane being scroll-tracked are left out (their movement is
    measured instead); a change to more than 30% of the rest is treated as a layout change.
- **Scrolling** (`Controller/SessionController+Scroll.swift`, `Tracking/`), a geometry-only lane:
  - A wheel event over the window picks the pane under the pointer: the innermost accessibility
    scroll/web area from the last read, else the window's content area below the chrome strip. A
    large unexplained thumbnail change (keyboard or scroll-bar scrolling) starts tracking the
    content area too.
  - While the pane moves, small grayscale captures of just that pane (≤ 1 px per point, ~15 per
    second at most, stopping ~0.5 s after the last wheel event once nothing moves) are compared
    with the previous one. The pane is split into a 6×6 grid and the shift is estimated per cell, so
    parts that stay put (sticky headers, side columns) are told apart from the scrolling body, and
    repeated or blank content can't decide the motion alone. Vertical, or horizontal, translation only.
  - Covers, keep holes, and in-pane control exemptions move by the measured displacement and are
    clipped to the pane; content that leaves the pane loses its cover. Covers grow and keep holes
    shrink by a margin that increases with every measurement step. Each tracking capture also
    refreshes that pane's blur (downscaled, off the main thread, newest wins), so the cover keeps up
    with the content; the image is shifted by any movement since it was captured, and the thin strip
    it can't cover yet is filled with the page's average color rather than a dark placeholder.
  - Every measurement is checked against the previous tracking frame and, if that fails, against
    the frame the regions were read from (captured the same way and at the same scale as the live
    frames), so one bad frame doesn't lose the pane. Until the first measurement arrives, a pane
    that had covered content is masked immediately: content may already be moving, so leaving
    covers at their old positions would briefly reveal it.
  - When movement still can't be verified (too large a jump, navigation, inconsistent cells, nested
    panes scrolled together, failed capture), the pane counts as unknown until a later frame matches
    the read frame again or the window is re-read. In Relaxed/Balanced a pane that
    had covered content is masked: the whole viewport if unmeasurable, otherwise just newly exposed
    strips and unverified cells. A pane where everything was visible isn't masked. Strict closes
    the affected keep holes.
  - After scrolling settles the usual re-read runs. Its commit swaps tracked geometry for the new
    regions in one step, and cached scores apply right away. A read that lands mid-scroll restarts
    tracking from its own frame. Regions replacing covered areas (including newly exposed scroll
    strips) stay covered until their own scores arrive or you explicitly reveal them. This also
    applies when hover changes or OCR regrouping produce new text in an existing covered card.
    Repeated reads and slow/failed classification do not expire that coverage; no old score is
    assigned to new text. Unscored content elsewhere still follows the selected hiding level.
    A region cut by the pane edge keeps the text and identity of the whole region it scrolled from,
    so a shrinking fragment doesn't become a new paid input.
  - Hover tooltips and popups update the holes in the overlay without resetting the underlying
    window's covers. Their appearance/disappearance requests a fresh read; reads captured under
    the old occlusion are rejected. Actual window moves/resizes still invalidate old geometry.
- **Deciding when to re-read:** changes must persist ~0.6 s after content settles (2 s at most for
  content that keeps changing). Changes already captured by a finished read are consumed; changes
  that disappear on their own trigger nothing. Animation (cells changing for 3+ ticks) away from
  anything kept visible only earns a recheck every 15 s.
- **Re-read (one at a time):** capture the window at full resolution, read the accessibility tree
  within limits (4,000 nodes, depth 64, 0.6 s, 0.25 s per call), and run Vision OCR only where needed:
  - nothing changed → previous OCR reused,
  - local change → only full-width horizontal bands around the change are re-OCR'd (grown so no line
    is cut) and the rest reused,
  - large change, new window, or OCR older than 60 s → whole-window OCR.
- **Merge and group:** AX text is kept only where OCR sees text. OCR lines duplicating AX are dropped.
  Accessibility containers and line/column proximity group text into regions (`Regions/Segmenter.swift`).
- **Classify:** each region's payload (app, title, text) is canonicalized once (Unicode NFC,
  whitespace collapsed, leading "(3) " title counters removed, truncated to 1,200 characters). The
  cache key is a hash of exactly that payload plus task revision, provider + pinned model, and
  question version. Position, scroll offset, and region number aren't part of it, so content that
  moves or comes back reuses its score. The cache is in memory, LRU, 2,000 entries, kept across
  pauses and window switches within a task.
- **Dispatch** (`Controller/ClassificationScheduler.swift`), separate from screen reading:
  - Cached scores apply immediately. Only inputs with no cached score are queued, and the queue
    holds just what the current front window still needs. Inputs that leave the screen before
    they're sent are dropped unsent; an input already in flight is never sent twice.
  - At most **one dispatch round per second**, each starting up to the free request slots (Jev: 6
    concurrent requests, one region each; Laya: one batch of up to 16). Nothing runs when there's no
    work. This can add up to ~1 s before a new region gets its score.
  - While you scroll the window, nothing is sent. Dispatch resumes 0.4 s after scrolling stops, once
    a read taken after the last scroll has replaced the queue, so intermediate positions aren't paid for.
  - Each request's score is cached and shown as soon as that request returns, so finished results
    survive sibling failures, cancellation, and window switches.
  - Temporary failures (network, timeout, 429/529/5xx) back off exponentially with jitter
    (2 s → 60 s), honor `Retry-After`, and pause the whole provider meanwhile.
  - An invalid answer is never turned into a score: the input is retried once after 30 s, then
    skipped for 10 minutes.
  - A rejected or missing API key stops all sending (no retries) until you fix `.env` and press
    **Check**, switch provider, or start a new session.
  - Pause/Stop and switching provider cancel in-flight requests and free their slots immediately;
    anything they still return is counted in usage but never applied.
  - Scores are keyed by the model Jev reports actually serving the request. If an alias such as
    `jev-latest` moves to a new model mid-session, results from that moment are discarded and the
    screen is re-scored under the new identity, never mixed with the old model's scores.
- **Apply:** the whole overlay scene (cover, chrome strip, occluders, keep holes, boxes) is rebuilt
  and swapped at once. Results from a paused/stopped session or an old window are discarded.

The chrome strip comes from accessibility layout (the top of the largest web/scroll/group area near
the top, else the bottom of a toolbar). Otherwise it is the top 28 pt.

All geometry uses one coordinate space (Quartz global points); conversions live in
`app/HeadsDown/Capture/Geometry.swift`.

## Privacy

- Screenshots and extracted text stay in memory. Full frames are dropped after OCR; the cover
  uses only the latest ~192-px capture.
  Scroll tracking keeps a grayscale copy (≤ 1 px per point) of the last read and of the latest
  tracking frame of a scrolled pane, in memory only, until the next read replaces them.
- **With Jev selected**, region text, the app name, window title, and your task are sent to
  TypeSafe (`api.typesafe.ai`) for scoring, after a one-time consent prompt. Usage is billed to your
  key. With Laya selected, region text goes only to the local loopback server. Screenshots are
  never sent to either.
- Calendar: only the selected current event's sanitized fields are kept, in memory. The refresh
  token is in the Keychain; skipped events are remembered as opaque IDs with an expiry. Logs record
  check timings, counts, and reason categories, never event titles, descriptions, or tokens.
- A local log (on by default, toggle in the Inspector) is written to
  `~/Library/Logs/HeadsDown/cycles.jsonl` (rotated at 2 MB). It contains only session-local IDs,
  counts, triggers, OCR scope/reuse, cache hits/misses, AX/OCR source flags, timings, scores/verdicts,
  pause events, and error categories. It never contains screen text, task text, window titles, or
  images. Inspector → Delete log removes it.

## Limitations

- Calendar auto-start knows what's scheduled, not what you actually do or what a meeting discusses.
  Sparse or private events can't be used. Only the primary calendar is read; there's no calendar
  picker yet. It works only while the app is running (no login item), and polling means edits show
  up with a delay. The brief is a trimmed copy of the event's own words, so a badly written event
  makes a poor task; edit or override it.

Hiding is a focus aid, not a security boundary.

- **Only the front window is read**, on one display. Background windows keep the cover from when
  they were last in front (up to 6). If a background window's content changes (video, auto-refresh,
  scrolling it without focusing it), its cover goes stale until it's focused again. Windows never
  focused during the session aren't covered. Full-screen windows aren't supported: the app clears
  coverage and says so. Pausing drops all covers.
- Cutoffs (0.50 / 0.65) are uncalibrated starting points picked from one session's scores (median
  0.57; only 4% scored below 0.20, which is why the earlier 0.20 cutoff hid nearly everything).
  On the 48 agent-labeled benchmark cases (`bench/jev_compare.py`), Jev got 47/48 (10/11 tricky)
  versus Laya's 40/48 (5/11); Laya tends to judge the site rather than the content. That's a small
  synthetic set, not a measurement on real screens, so expect wrong calls; reveal or pause.
- Controls are found through accessibility only. Apps that expose little (Electron apps such as
  Slack, VS Code, Discord; Chrome web content) get the top chrome strip but no in-page controls, so
  a search box inside a covered area can still be covered.
- Scroll tracking measures pixels from screenshots (~15 per second at most), not the app's own
  compositor, so covers trail fast scrolling by a frame or so (hence the margin). It handles one pane
  scrolling vertically or horizontally, sticky headers and side columns that fill whole grid cells,
  and a nested pane scrolled on its own. It falls back to masking for jumps larger than ~60% of the
  pane per frame (page down, fast flicks), navigation, diagonal motion, zooming, sticky elements
  that cover only part of a grid cell, and nested panes scrolled in one burst. AX element anchors
  aren't polled: accessibility only says which pane scrolled.
- In Relaxed/Balanced, an unexplained layout change (e.g. navigation) masks the content area until
  the re-read when something there was covered; otherwise new content shows until it's scored.
- Regions are text blocks (or AX container frames where available). In Relaxed/Balanced an image
  next to distracting text stays visible; in Strict an image next to relevant text stays covered.
  Text-free areas can't be revealed individually.
- The cover is a low-resolution blurred copy refreshed ~2.5× a second for the front window (frozen
  for background windows), not a live compositor blur. Large shapes and colors stay recognizable.
- In Strict, a kept region whose content changes is covered again on the next tick (≤ ~0.4 s plus capture
  time), so new content can show briefly inside a kept area. Keyboard scrolling isn't detected
  directly; the pixel comparison catches it on the next tick and starts tracking from there.
- Window chrome stays visible, so tab titles can still distract.
- Cache keys follow the exact text sent. If OCR rewraps or regroups the same prose differently, it
  counts as new input and is scored again. Title changes (other than leading counters) also count,
  because Jev sees the title.
- Windows at layer ≥ 1000 (e.g. a dictation utility's overlay) and non-app windows spanning nearly the
  whole display (e.g. Notification Center's full-screen host) are assumed transparent; the Inspector
  lists them. Areas under any other higher window stay uncovered.
- English text only. Images, video, and canvas content aren't understood.
- Chrome and Electron apps (Slack, VS Code, Discord) expose little to accessibility, so they run
  OCR-only with text-block regions and the default 28-pt chrome strip.
- A Vision request already running can't be interrupted. Pause and stop take effect immediately on
  screen; the abandoned work finishes in the background before the next read starts.
- This is rule-based orchestration of local tools, not an LLM deciding which tools to call.

Run the synthetic cover-continuity regression checks (no screen capture or classifier requests):

```bash
app/scripts/test-cover-continuity.sh
```

These exercise hover/OCR replacement, repeated pending reads, score and reveal release, scroll
startup and capture-time placement, lost tracking, and popup versus window geometry changes.

Checked during builds:

- The app builds with `xcodebuild`, launches as a menu-bar app, and quits cleanly.
- The Laya batch response envelope was confirmed against a real response and `laya/serve.py`.
- Throwaway checks (not kept) ran the real code on synthetic input: OCR → Quartz conversion and
  segmentation on a two-column image; canonical payload/key behavior; strict policy outcomes; OCR
  band expansion; thumbnail cell mapping; cover image generation; the scroll motion estimator on
  synthetic text-like frames (exact vertical/horizontal shifts, a fixed header, rejection of
  oversized jumps and navigation-like changes, ~1–5 ms per frame in an optimized build).

**Not yet verified on a real screen:** cover appearance and alignment, chrome-strip detection,
keep holes, change invalidation, scroll tracking and its fallback masks on real apps, banded OCR in
practice, timed auto-resume with the panel closed, shortcuts, and latency. Google Calendar sign-in,
the Calendar API calls, and auto-start against a real account haven't been run (they need an OAuth
client ID); the resolver and brief builder were checked on synthetic event JSON. These need Screen Recording permission and a hands-on session.

## Developer notes

- Source layout: `App/` (menu bar, inspector, shortcuts), `Controller/` (`SessionController.swift`:
  state, lifecycle, controls, timed pause; `SessionController+Pipeline.swift`: tick, cycle,
  classification, rendering; `SessionController+Scroll.swift`: scroll tracking lane), `Tracking/`
  (tracking frames, motion estimator, per-pane tracker), `Capture/` (window locator, ScreenCaptureKit, AX, geometry, thumbnails,
  content envelope), `Recognition/` (Vision OCR incl. banded OCR, AX/OCR merge), `Regions/`
  (segmenter), `Classification/` (provider protocol, canonical payload/key, Laya client), `Policy/`
  (strict policy, reveals, LRU score cache), `Calendar/` (Google OAuth + Keychain, read-only
  Calendar client, current-event resolver, brief builder, suppressions, automation controller;
  session side in `Controller/SessionController+Calendar.swift`), `Overlays/` (overlay scene, cover image and its render
  queue), `Diagnostics/`.
- The Xcode project uses a file-system-synchronized folder: new files under `app/HeadsDown/` are
  picked up without editing the project file.
- `app/scripts/gen-compile-commands.sh` writes a `compile_commands.json` (gitignored) so
  SourceKit-LSP in editors sees the whole module. Editor tooling only.
