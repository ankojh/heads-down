# Heads Down — optional Google Calendar auto-focus

**For:** the builder agent  
**Repository:** `/Users/ankojh/b12/heads-down`  
**Deliverable requested:** implementation handoff, not implementation in this session.  
**Feature:** Automatically start a focus session from the **currently active Google Calendar event**, while keeping manually entered tasks authoritative.

## 1. Explicit user decisions

The user chose:

- **Builder handoff**, not immediate app changes.
- **Google Calendar directly**, not macOS EventKit/calendar synchronization.
- **The current event only**, not today's events or the upcoming week as task context.
- Automatically turn Heads Down on for the topic of that current event.
- Keep the typed study/work task as the primary manual workflow.
- Calendar is optional.
- A separate external LLM may compress event information if needed.

The clarification about automatic activation supersedes the earlier suggestion that Calendar would merely add background context to a manually started session.

### Important distinction

Calendar contains scheduled event metadata. It does **not** provide what participants are currently saying. Use the event title, description/agenda, timing, and other appropriate metadata. Do not claim to understand a live meeting, listen to audio, retrieve transcripts, or automatically join calls.

### Recommended defaults, not additional user commitments

- Integration disconnected and automation disabled by default.
- One Google account initially; primary calendar selected initially, with explicit calendar selection if multiple calendars are supported.
- Auto-start applies to eligible current study/work/meeting/focus events with useful topic information.
- Manual active/paused sessions are never silently replaced by Calendar.
- No per-event confirmation dialog after the user has enabled automation and completed permissions/consent.
- A manual Stop/Pause cannot be undone by the next calendar poll.
- Optional external summarization is separately configured/consented to; it is not required for the baseline feature.
- No automated test suite, test fixtures, CI, or test workstream; preserve the user's earlier instruction not to spend time on tests.

## 2. Current implementation and boundaries

The native Swift app exists and has a substantial uncommitted working tree newer than HEAD `4bd5cc1`. Do not reset or replace it with the original planning scaffold.

Relevant existing pieces:

- `App/ControlPanelView.swift`: typed task, Start/Update, provider settings, timed/indefinite pause, Stop.
- `Controller/SessionController.swift`: lifecycle, task revision, task text, permission/consent paths, pause timers.
- `Controller/SessionController+Pipeline.swift`: observing regions, policy/rendering, synchronization with classifier scheduler.
- `Controller/ClassificationScheduler.swift`: bounded Jev dispatch, request identity, retry/usage accounting.
- `Classification/Classifier.swift`: provider boundary and existing distraction question.
- `Classification/CanonicalInput.swift`: canonical region inputs.
- `Policy/Policy.swift`: current user-selected hiding behavior and score cache.
- `App/HeadsDownApp.swift`: app setup and termination.

Calendar/OAuth code is not present in the inspected implementation. This feature should supply session intent/context; it must not replace the capture, segmentation, scroll-tracking, or blur pipeline.

Preserve existing fixes and handoffs:

- `JEV_PERFORMANCE_HANDOFF.md`: semantic caching and paid-call scheduling.
- `SCROLL_BLUR_HANDOFF.md`: scroll-following coverage; separate work, not a reason to increase AI calls here.

Do not commit/push without approval. Do not inspect or output `.env` credentials; document configuration through placeholders and the existing configuration conventions.

## 3. Product behavior

### Manual mode remains the main path

The user types a task and starts Heads Down exactly as today.

- A running manual task wins over any calendar event, even if the event changes or ends.
- Editing/applying the task on an automatically started session is a deliberate manual takeover; mark the source manual so an event-end timer cannot terminate the user's chosen task.
- Typing an unsaved draft alone is not a started session and does not implicitly change active task provenance.
- Calendar does not overwrite `taskDraft`, switch provider/strictness/mode, or silently broaden an explicitly entered task.
- Optional manual adoption of calendar context can be added as a clear UI action; it is not required for the first auto-start feature.

### Calendar mode is explicitly armed

After connection and opt-in:

1. Watch the enabled calendars for an event active **now**.
2. Apply deterministic eligibility checks.
3. Classify its activity type if needed, and derive a compact, grounded focus brief.
4. If there is no overriding manual session or suppression, automatically start Heads Down with that brief.
5. Show the task source, event title, and end time in the UI.
6. Reuse the brief while the event topic is unchanged.
7. End or transition only calendar-owned sessions when their underlying event ends, is cancelled, becomes ineligible, or changes.

Examples:

```text
Current event: Product Management study session
Description: Prepare for the prioritization quiz. Review RICE and Kano.
Effective task: Study RICE and Kano prioritization frameworks for the PM quiz.
```

```text
Current event: Backend project sync
Description: Review authentication work and assign remaining API tasks.
Effective task: Participate in the backend project sync about authentication and API task ownership.
```

A bare event like “Busy” or “Meeting” without useful context is not license to invent a topic and hide arbitrary content. Surface “Current event has insufficient topic information” and leave auto-start inactive for that event unless the user manually supplies a task.

Do not turn routine metadata such as a room number, dial-in PIN, or participant list into the semantic focus topic.

## 4. Architecture

```text
Google OAuth connection (read-only)
                 │
GoogleCalendarClient: bounded current-event query
                 │
CurrentEventResolver: time/status/overlap eligibility
                 │
CalendarContextBuilder
   sanitize → activity classification → compact task brief
                 │
CalendarAutomationController
   enabled? manual override? suppressed? event still current?
                 │
SessionController: calendar-owned start/update/end
                 │
existing screen → OCR/AX → Jev/Laya → policy → overlay loop
```

Calendar polling, context preparation, and screen observation have separate lifecycles. An event may begin while the focus pipeline is stopped, so calendar watching cannot live only inside `SessionController.beginLoop()`.

No separate backend or MCP server is required for this native feature. OAuth and the read-only Calendar REST API are sufficient. A connector plus an autonomous policy loop fits the product; do not mislabel it as a general-purpose LLM planner.

## 5. Google OAuth: native desktop flow

Use Google's supported installed/desktop-app OAuth authorization-code flow with **PKCE S256** and a system-browser sign-in.

### Required setup to document

The developer/user must:

1. Create or select a Google Cloud project.
2. Enable the Google Calendar API.
3. Configure the OAuth consent screen and applicable user access.
4. Create a **Desktop app** OAuth client.
5. Configure its client identifier in Heads Down using a nonsecret example placeholder.
6. Authorize the intended Google account through the browser.

Do not use a service account, domain-wide delegation, embedded Google login page, copied browser cookies, or a shared developer access token.

### Flow requirements

- Generate a cryptographically random PKCE verifier and state per authorization attempt.
- Open the Google authorization URL in the system browser.
- Use a supported desktop redirect strategy; a short-lived loopback listener on `127.0.0.1` with an OS-selected available port is a documented option.
- Bind only to loopback, validate callback path/state, time out abandoned attempts, reject unexpected callbacks, and shut down the listener after completion.
- Use the identical redirect URI in authorization and token exchange.
- Request refresh/offline capability using the supported installed-app flow; follow current Google documentation rather than blindly copying web-app-only parameters.
- Do not assume an embedded client secret is a security boundary in a distributed desktop app. If the chosen library/flow requires Google's client credential fields, handle them as documented without pretending they are user secrets.
- Use a maintained native OAuth implementation if already available/appropriate; otherwise keep the small flow isolated rather than mixing it into `SessionController`.

### Scopes

Prefer:

```text
https://www.googleapis.com/auth/calendar.events.readonly
```

Add this only if providing calendar discovery/selection:

```text
https://www.googleapis.com/auth/calendar.calendarlist.readonly
```

Do not request Calendar write/delete, Gmail, Drive, Contacts, Meet recording, or broad account-profile scopes merely for convenience. Calendar selection is an application-level restriction; these scopes may permit access beyond the calendars selected in Heads Down. Describe that honestly in consent/setup copy.

### Token handling

- Store refresh tokens and any retained access tokens securely in macOS Keychain, not `.env`, UserDefaults, source files, or logs.
- Store ordinary preferences such as selected calendar IDs/auto-start enabled separately from secrets.
- Serialize token refresh so concurrent calendar requests do not trigger parallel refresh storms.
- Use expiration-aware refresh and bounded handling for 401; do not retry indefinitely on revoked/invalid credentials.
- On disconnect: disable automation, cancel calendar/context work, stop only calendar-owned focus activity, clear event context, remove tokens, and offer/perform appropriate token revocation. A failed remote revocation must not retain local authorization or keep polling.
- A missing refresh token in a refresh response must not erase a previously valid refresh token.

Google's external OAuth consent screen in **Testing publishing status** commonly issues refresh tokens expiring after seven days when Calendar scopes are requested. That is a development-account limitation to document, not an app scheduling bug. Public distribution may require OAuth verification; organizational accounts may be blocked by administrator policy.

## 6. Fetch only current-event candidates

### API access

Use:

```text
GET https://www.googleapis.com/calendar/v3/calendars/{calendarId}/events
```

For a primary-calendar-only first version, `calendarId=primary` is supported. Properly encode other calendar IDs.

Recommended parameters:

- `singleEvents=true`: expand recurring events into instances.
- `showDeleted=false`.
- `orderBy=startTime` where helpful.
- A narrow time query around now, with explicit timezone offsets.
- Appropriate partial `fields` selection, retaining pagination fields.

Important Google semantics:

- `timeMin` is an exclusive lower bound on **event end time**.
- `timeMax` is an exclusive upper bound on **event start time**.
- `timeMax` must be later than `timeMin`.

For example, query with `timeMin=now` and `timeMax=now+60 seconds`, then apply the actual active predicate locally:

```text
start <= now < end
```

The small future overlap is a query boundary convenience, not permission to use an upcoming event as the current task. Re-evaluate against the actual clock after a delayed network/LLM response.

- Handle pages until `nextPageToken` is exhausted, with sensible request/time bounds and an explicit partial-result status if interrupted.
- Parse RFC3339 timestamps/timezone offsets correctly; do not compare time strings.
- Handle cross-midnight events and DST.
- Ignore all-day events for automatic timed focus initially; don't let a birthday or all-day reminder own the entire day.
- Do not combine moving `timeMin/timeMax` filters with `syncToken`; Google forbids that combination. A bounded current-window poll is simpler than full calendar synchronization for this feature.

### Polling cadence

Suggested starting point: one bounded refresh about every **30 seconds**, with jitter/backoff and refresh on wake/reconnection/manual refresh.

- While the app is running and automation is armed, the watcher remains active even when no focus session is active.
- An already-known upcoming start within the narrow response window can have a local wake timer, but only activate once it is actually current and valid.
- Use a local event-end deadline to avoid depending on the next poll to stop a calendar-owned session.
- Refresh at relevant boundaries and after wake; don't restart ended events from old cache.
- Communicate that detection is near-real-time, not exact real-time, especially for newly edited events.
- Calendar polling must not run at screenshot/scroll cadence.
- Use backoff for rate-limit/transient failures; distinguish a failed query from a successful empty result.

Google push notifications require additional channel/webhook infrastructure and renewal. Do not add a public backend just to avoid a 30-second desktop poll in the first implementation.

## 7. Event eligibility and overlapping events

First use deterministic metadata:

- Within the current time interval.
- Not cancelled/deleted.
- Readable useful event details, not a private “busy only” placeholder.
- Not explicitly declined for the relevant calendar/account attendee.
- Not an all-day item, birthday, working-location marker, or out-of-office block.
- Default eligibility: confirmed regular events or focus-time events with meaningful topic information. Exclude unresolved/tentative invitations by default unless the UI deliberately supports them later.
- Treat free/transparent events conservatively; they should not seize focus merely because they overlap now.

Fetch only participation metadata needed for eligibility. Shared-calendar `attendees[].self` refers to that calendar's event copy; do not blindly assume it identifies the signed-in human on every shared calendar.

### Recommended overlap resolution

Avoid an LLM trying to compare dates or randomly selecting between meetings:

1. Keep the currently selected event while it remains valid and eligible, avoiding poll-to-poll switching.
2. Otherwise use explicit user calendar priority (primary first initially).
3. Prefer confirmed participation/owned focus events over weaker candidates when that evidence is available.
4. Break remaining ties deterministically (e.g. most recent start, then stable instance ID).
5. Show the selected event and that another current event overlaps; allow a manual switch/override without requiring one.

Do not merge unrelated simultaneous meetings into a single fabricated task.

Use a stable **event-instance identity**, scoped to account and calendar. Recurring occurrence identity must distinguish one instance from the series; use instance ID and/or `recurringEventId + originalStartTime` appropriately. A rescheduled instance should not escape a user suppression just because its displayed start time changed. Deduplicate the same invitation mirrored in multiple selected calendars where reliably identifiable.

## 8. Rich context, not indiscriminate data collection

Use all **useful permitted information from the selected current event**, not the user's entire calendar history or every guest's private details.

Useful event fields:

- Summary/title.
- Description/agenda, normalized from any HTML to plain text without executing it or loading remote resources.
- Start/end/timezone and event type for lifecycle.
- Location where semantically meaningful.
- Attachment titles or descriptive link labels already in the event metadata.
- A conference-service hint when useful to recognize meeting-support activity.
- Source/version metadata (`etag`/`updated`) for refresh logic.

Keep out of model input by default:

- OAuth tokens, account identifiers, full attendee email lists.
- Meeting passcodes, phone PINs, access codes, signed URLs, private join tokens.
- Raw conference/attachment URLs whose secret components are irrelevant to the topic.
- Unrelated current events that lost overlap selection.

Do not automatically follow links, download attachments, grant Drive access, or read transcripts. An attachment title is context; retrieving its contents is a different feature/permission boundary.

Calendar descriptions are untrusted data, potentially authored by another attendee. Instructions inside them cannot alter app settings, override pause, cause network navigation, invoke tools, or change OAuth scopes.

## 9. Event classification and optional compression

### Baseline: useful without another LLM

Build a bounded task brief directly from sanitized event title and relevant description. Preserve named topics and explicit agenda items; trim boilerplate and lengths deterministically.

If semantic event eligibility is needed, use a **separate typed decision** for activity kind, such as:

```text
study / work / meeting / personal / insufficient_context
```

A Jev/Laya event classifier can provide that bounded decision, with its own question/schema version and cache. Do not reuse the distraction question against calendar data or mix event-classification scores with region distraction scores.

- Classification should occur on meaningful event-content changes, not every poll.
- Keep date arithmetic, overlap selection, and permissions in code.
- Do not require cloud event classification when the user selected local-only operation or has not consented to calendar data being sent out.
- Focus-time metadata with a useful title may be sufficient without another semantic call.
- Unknown/insufficient context should produce a clear inactive automation status, not repeated dialogs or invented work goals.

### Optional external LLM compression

The user allows an external LLM if needed, but **has not chosen a provider/model or supplied a new key**. Do not silently choose a vendor, repurpose the Jev key, or make this a blocking dependency for Calendar auto-start.

Implement a separate `CalendarContextCompressor` boundary with a local deterministic implementation as default. A configured remote implementation can be added when its provider is selected and access is available.

Remote path requirements:

- Off/unconfigured until selected, with explicit notice of which event fields go to which provider.
- Input contains only sanitized selected-event fields, not screenshots or all calendars.
- A concise, bounded output schema, e.g.:

```json
{
  "topic": "Product management prioritization",
  "objective": "Prepare for the quiz",
  "key_topics": ["RICE", "Kano"],
  "activity": "study",
  "insufficient_context": false
}
```

- Ask for faithful compression/extraction, not invented requirements, arbitrary URLs, actions, or a speculative user biography.
- Validate type/length/enum constraints in code. Reject malformed output and fall back to the deterministic brief.
- Named topics/objectives must be grounded in source fields. Schema validation alone does not prove factual faithfulness; retain provenance and present the resulting brief for inspection/editing.
- No tool access for the compressor. Event content cannot give it authority over the app.
- One in-flight preparation per event version; cache completed outputs.
- Short bounded timeout/retries; event end, disconnect, suppression, task takeover, or source change invalidates pending application of its output.

Do not hot-swap a running fallback brief to a late optional summary merely because it arrived: that can invalidate every region score for little benefit. Prepare a final brief before activation with a bounded wait/fallback, then hold it stable until a meaningful source/task change.

### Keep classification costs bounded

A cached brief is still repeated input when included in every region request. Aim for a small stable brief (for example a few hundred characters, bounded by a documented limit), not a multi-page calendar description. Do not claim preprocessing once makes the downstream tokens free.

Account for event-classification/compression calls separately from screen-region calls, using actual usage metadata where available.

## 10. Task representation and cache invalidation

Add explicit task provenance rather than overloading the editable text field:

```text
TaskSource = manual | calendar(eventInstanceIdentity)
```

Suggested session context fields:

- Manual task draft remains independently editable.
- Effective task text/brief actually sent to the classifier.
- Source and source instance identity.
- Semantic context fingerprint and preparation version.
- Event start/end for lifecycle, separate from semantic task text.
- Automation intent generation and manual-override/suppression state.

For calendar sessions, use the current classifier's `current_task` field with a deterministic brief rather than changing its successful question. If you add a new structured payload shape, version that schema and make it an explicit change—not incidental cleanup.

Cache rules:

- Cache event fetch metadata by account/calendar/instance/version.
- Cache semantic brief by sanitized **relevant content fingerprint** + classifier/compressor model/prompt version.
- Event `etag` changes trigger inspection, not automatic rescoring of every screen region.
- An end-time extension updates the lifecycle deadline without changing the task if the topic/agenda is unchanged.
- Guest RSVP churn, cosmetic formatting, and repeated polls must not churn task revisions.
- A real topic/agenda/task change updates the effective task and its semantic namespace exactly once, invalidating incompatible region scores.
- Existing canonical input, provider/question/model identity and score-cache safeguards remain intact.
- Late region/brief results cannot be applied to a new task or event.

Do not put the ticking time, event end countdown, raw ETag, or poll timestamp into the semantic task string sent for every region.

## 11. Automation lifecycle and manual priority

Model calendar watching separately from focus activity. Suggested automation states:

```text
Disabled
Disconnected / Needs authorization
Watching
Preparing current event
Calendar session active
Suppressed / Manual session has priority
Degraded (calendar or context unavailable)
```

Recommended transition rules:

| Situation | Behavior |
|---|---|
| Automation off/disconnected | Manual workflow unchanged; no event/model polling |
| Armed, eligible event current, no manual session/suppression | Prepare once and auto-start calendar-owned session |
| Same event and semantic brief unchanged | No restart, no revision bump, no reclassification |
| Same event, end time changes | Reschedule end boundary only |
| Same event, meaningful topic changes | Replace calendar task once, with generation checks |
| Event ends/cancels/becomes ineligible | End only its calendar-owned session, then re-evaluate current candidates |
| User starts or applies a manual task | Manual source wins; calendar cannot overwrite or stop it |
| User pauses indefinitely | Suspend focus and auto-start until explicit resume/re-arm |
| User pauses for 2/3 minutes | Calendar cannot reactivate during the pause; expiry revalidates source/event before resuming |
| User stops during a current event | Suppress that occurrence; do not immediately auto-start it again |
| User disables/disconnects Calendar | Stop calendar-owned focus and cancel calendar/context work; preserve an unrelated manual session |
| App quits | Cancel all watchers, timers, pending work, and focus activity |

### Stop must mean stop

Existing `SessionController.stop()` clears the session but knows nothing about calendar suppression. A watcher calling Start again would undo the user's explicit action.

- Distinguish a user stop from automatic event completion/internal cleanup.
- On user stop, suppress the selected/current eligible occurrences for the rest of those occurrences, including equivalent mirrored copies. Otherwise an overlapping event can immediately restart the app after the chosen event is suppressed.
- The watcher may remain armed for a genuinely new future occurrence; show “Skipped for this event.”
- Provide “Resume this event”/re-arm explicitly if the user changes their mind.
- Keep suppression keyed to stable occurrence identity, not `etag`; an RSVP/update must not bypass it.
- Preserve suppression across an app restart if automation preferences persist. Store only minimal local IDs/expiry metadata, not event bodies, and bound/prune it.

### Pauses and event expiry

- Indefinite pause remains authoritative across event changes until resumed/re-armed.
- Timed pause expiry must not resurrect an ended/cancelled event. Re-resolve current state and permissions before any auto-resumption.
- Manual paused sessions remain manual even if Calendar advances.
- Use existing `ContinuousClock` logic for pause durations; event schedules are absolute date/time boundaries and must be reconciled on wake or clock changes.

### Poll/network failures

- A failed request is not a successful “no event.” Do not stop/start on every transient network error.
- Do not start a new calendar session from stale unverified data.
- For a currently calendar-owned session, retain its known brief only within its known end time and a bounded documented freshness grace (e.g. two minutes), then suspend calendar-owned focus if freshness cannot be re-established.
- Never extend an event indefinitely because Google is unreachable.
- Calendar failure never stops a manual task.
- On reconnect/wake, re-evaluate the current event; do not replay missed historical events.

## 12. Safe programmatic start: do not call the UI button blindly

Current `start()` consumes `taskDraft` and may trigger cloud consent or permission prompts. `beginSession(task:)` also performs permission setup. The auto-start path needs a deliberate reusable lifecycle API.

Refactor narrowly into operations equivalent to:

```text
startManualTask(text)
startCalendarTask(brief, occurrence, intentGeneration)
updateCalendarTaskIfCurrent(...)
endCalendarTaskIfOwnedBy(occurrence, reason)
```

- Preserve existing manual behavior.
- Keep `taskDraft` unchanged during calendar starts.
- Capture immutable source/task/intent metadata before awaiting OAuth/context/permission work.
- Recheck automation enabled, source still current, suppression, manual priority, and generation after every asynchronous boundary.
- A manual action performed while an event brief is being prepared must win.
- Avoid repeated modal prompts from polling. Complete Screen Recording/accessibility/provider consent setup when the user enables auto-start; if readiness later fails, show an actionable blocked status rather than prompting every 30 seconds.
- Existing consent for sending screen text to Jev should be updated to explain that the task may now include calendar-derived information. A second external compressor requires its own disclosure.
- Do not silently fall back to a different provider or change hiding mode for an automatic session.

The app must remain running in the menu bar for monitoring. Do not add a login agent/launch daemon or claim it can auto-start while the app is quit. Launch-at-login can be a separately requested option later.

## 13. UI

Keep typed task controls visually primary. Add a compact optional Calendar section/settings panel:

- **Connect Google Calendar** / account connection status / Disconnect.
- Enabled calendars and priority if multiple are supported.
- **Automatically start from the current event** toggle, off initially.
- Current selected event title and local start/end time.
- “Task source: You” or “Task source: Google Calendar.”
- Short effective topic/brief with a way to inspect/edit it.
- Status: watching, no current event, preparing, active until time, skipped for this event, manual task has priority, authorization needed, insufficient context, offline/stale.
- Manual takeover or “Use my typed task.”
- Optional compression configuration/status, with clear outbound-data disclosure.

Do not require clicking “Use event” for every event once auto-start is enabled; that defeats the clarified request. Manual inspection/correction remains available.

Show event-derived context in UI without logging it by default. Avoid putting sensitive descriptions into menu-bar notifications visible on a locked/shared screen.

## 14. Suggested modules and code touchpoints

New small modules under `app/HeadsDown/Calendar/`:

- `GoogleCalendarAuth`: desktop OAuth/PKCE, refresh/revocation, Keychain boundary.
- `GoogleCalendarClient`: read-only REST, partial fields, pagination, response/error models.
- `CurrentEventResolver`: time eligibility, recurrence identities, overlap selection.
- `CalendarContextBuilder`: sanitized deterministic brief, optional activity classifier/compressor interfaces and caching.
- `CalendarAutomationController`: independent watcher, event boundaries, suppression, intent generations.
- `CalendarModels`: source identity, brief, connection/automation state.

Existing files:

| File | Work |
|---|---|
| `Controller/SessionController.swift` | Provenance-aware lifecycle; manual priority; source-scoped start/end; pause/stop integration |
| `Controller/Models.swift` | Task source/effective semantic context representation |
| `Controller/SessionController+Pipeline.swift` | Read stable effective task; retain existing geometry/rendering behavior |
| `Controller/ClassificationScheduler.swift` | Preserve current bounded region dispatch and correct task namespaces |
| `Classification/Classifier.swift` | Keep distraction question unchanged; event classification gets separate contract/question if implemented |
| `App/ControlPanelView.swift` | Calendar controls/status, task-source display, manual takeover |
| `App/InspectorView.swift` | Brief provenance, freshness, preparation status and separate usage counters |
| `App/HeadsDownApp.swift` | Watcher setup/teardown independent of active capture |
| `Diagnostics/DiagnosticsLog.swift` / callers | Minimal events/counts/error categories, no raw calendar data |
| `README.md`, `.env.example` or equivalent | Google Cloud/OAuth setup, nonsecret client-ID placeholder, permissions/limitations |

Do not introduce calendar API calls in the OCR loop or one compression call per region.

## 15. Privacy and failure constraints

- Google access is read-only.
- No event creation/editing, RSVP changes, invitations, or automatic meeting joins.
- Process only selected current-event context; do not store a calendar history database.
- Do not follow descriptions as commands or access arbitrary linked URLs.
- Optional external compression and Jev classification may transmit calendar-derived text; disclose this even if only a brief is sent.
- Use local-only preparation when external transmission is not configured/consented to.
- Store refresh tokens in Keychain and redact auth/API errors before surfacing/logging them.
- Keep bounded metadata logs: poll/preparation duration, selected/skipped reason category, cache hit, start/end/suppression reason, provider usage. No event titles, descriptions, attendee emails, join links, OAuth codes, or tokens in default logs.
- Disconnect removes credentials/context and stops background calendar work.
- Unknown context/permissions result in inactive/degraded automation—not a fabricated goal or an uncontrollable mask.

## 16. Implementation order

1. Add task provenance and source-aware lifecycle boundaries without changing manual behavior.
2. Add Google desktop OAuth, Keychain storage, connect/disconnect, and narrow read-only Calendar API access.
3. Resolve the current event with deterministic temporal/status/overlap rules and display it without activating focus yet.
4. Build/cached sanitized task briefs; add a separate event-kind decision only where useful.
5. Wire explicit auto-start opt-in, independent watching, event end, suppression, manual priority, and pause interactions.
6. Integrate stable semantic task revisions/cache keys and existing bounded classification dispatch.
7. Add optional compressor boundary/configuration; deterministic preparation remains usable if no external model has been chosen.
8. Document setup, actual automation behavior, and limits.

No automated tests/test workstream. Use the existing normal build process; report actual build/runtime status rather than inventing results.

## 17. Unselected optional choices and honest limitations

Already settled: builder handoff, direct Google Calendar, current-event automatic activation, typed-task priority.

Not selected by the user:

- External compression provider/model/key. Keep this configurable/disabled until supplied; do not block core Calendar integration on it.
- A live meeting transcript source. Not part of this feature.
- Always-running background service/launch-at-login. Not authorized by the request.

Recommended scope defaults above cover overlap handling, event eligibility, polling, and suppression. If implementation requires materially changing those behaviors or expanding data access, explain the concrete reason rather than silently broadening permissions.

Known limitations to describe:

- Calendar topic may not match what the person actually does or what a meeting actually discusses.
- Sparse/private event details can be insufficient for useful focus decisions.
- Overlapping events require a deterministic best-effort choice and a manual override.
- A poll-based desktop app observes edits with delay and only while running.
- Google account policy/verification can limit authorization.
- LLM compression can omit or invent meaning; it is optional, bounded, inspectable, and has a non-LLM fallback.

## 18. First-party references consulted

- Desktop OAuth, PKCE, system browser, loopback redirect: https://developers.google.com/identity/protocols/oauth2/native-app
- OAuth lifecycle/refresh-token restrictions: https://developers.google.com/identity/protocols/oauth2
- Calendar read-only scopes: https://developers.google.com/workspace/calendar/api/auth
- Events list, time filters, recurrence expansion, pagination, sync-token restrictions: https://developers.google.com/workspace/calendar/api/v3/reference/events/list?hl=en
- Event resource, participation, occurrence identity, inclusive start/exclusive end: https://developers.google.com/workspace/calendar/api/v3/reference/events

Recheck official documentation when implementing OAuth details; don't copy a deprecated mobile redirect flow into this macOS app.

## 19. Builder report-back

State:

- How to configure Google OAuth and connect the account.
- Which calendars/event types are eligible and the exact auto-start behavior.
- How manual task entry, Stop, indefinite pause, and timed pause remain authoritative.
- What metadata becomes the task brief and where it is transmitted.
- Whether compression is deterministic or uses a configured external model.
- What was built/run and what remains unverified or blocked by credentials/permissions.

**Core principle:** Calendar can autonomously supply a timely, grounded focus goal when the user opts in. It must never outrank an explicit manual task or turn itself back on against a pause/stop instruction.
