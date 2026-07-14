# Engineering Tools Audit (Device Configuration, BLE Tester, BLE Log)

Audited: `Views/AdvancedView.swift` (container + `BLELogView`), `Views/BLETesterView.swift`, `Views/ToolboxView.swift` (UX-level pass only), with the underlying model in `BLE/BLEManager.swift`, `BLE/ODDevice.swift`, `BLE/CoreBluetoothTransport.swift`, `BLE/ODConstants.swift` (`LogEntry`, `OD.Cmd`), and the send path through `Resources/ble-app-adapter.js` → `Resources/ble-common.js` (`sendHexCommand`/`sendCommand`, read-only). Date: 2026-07-14.

## Overview

The "Engineering Tools" section of the Advanced sheet bundles three debugging surfaces: Device Configuration (the Toolbox), a raw BLE Tester, and a shared session BLE Log. The plumbing underneath is solid — a single bounded shared log (`BLEManager.appendLog`, 500-entry cap), completion-driven send feedback, and clean input validation in the Tester. The main problems are in *observability during real debugging*: the Tester silently hides any packet whose second byte is `0x71` (its own sends included), its auto-scroll permanently stops the moment the 500-entry cap is reached, the BLE Log opens at the oldest entry with its Share/Clear actions buried below up to 500 rows, `lastError` banners are never cleared for the rest of the session, and on-screen timestamps have minute precision on a millisecond-scale protocol. Cross-tool consistency is weak: three different log designs, three different clear-log semantics, and naming that flips between "Toolbox" and "Device Configuration".

## Device Configuration (light pass — see device-configuration.md for protocol depth)

Protocol-level correctness (Simple-mode preset index round-trip, failed-build-still-writes, connect-then-write wedge, schema leakage, numeric wrapping, JSON tail loss) was audited separately — see `docs/audit/device-configuration.md`. The findings below are limited to UX, aesthetics, and code quality of the screen itself.

### Findings

**[MEDIUM] No cancel or timeout affordance while "Configure over Bluetooth" is in flight**
- Location: `Views/ToolboxView.swift:419-444` (`deviceActionsSection`).
- Issue: Tapping Configure sets `isConfiguring = true` and disables the button; the only visible state is a progress bar driven by hardcoded waypoints (`0.1`, `0.3` — synthetic progress, not measured). There is no Cancel button, and per the prior audit the failed-connection path never resets the flag.
- Impact: On any stall the screen reads as hung with no way out except leaving the view; the synthetic progress bar also implies more fidelity than exists.
- Recommendation: Add a Cancel action while `isConfiguring`, and either drive progress from real events (connection → write chunk ACK fraction, which `ODDevice.writeConfig` already counts) or use an indeterminate spinner.

**[LOW] Navigation title mismatch and truncation**
- Location: `Views/AdvancedView.swift:18` (row: "Device Configuration") vs `Views/ToolboxView.swift:93` (title: "OpenDisplay Device Configuration").
- Issue: The row and the destination disagree on the tool's name, and the long title is displayed `.inline`, where it truncates on smaller devices.
- Recommendation: Title the screen "Device Configuration" to match its entry point.

**[LOW] "Toolbox" naming leaks into user-facing text**
- Location: `Views/ToolboxView.swift:73` ("Toolbox mode"), `:481/:486` ("Read Toolbox" / "Write Toolbox"), and `Views/AdvancedView.swift:43` (footer: "via the Toolbox").
- Issue: The menu calls the tool "Device Configuration", but buttons and the Advanced footer use the internal name "Toolbox". A first-time user told to "connect via the Toolbox" will not find anything called Toolbox in the menu.
- Recommendation: Standardize on one name in user-facing strings ("Read Configuration" / "Write Configuration"; footer: "via Device Configuration").

**[LOW] Step numbering starts and ends at "1."**
- Location: `Views/ToolboxView.swift:257` ("1. Choose Hardware"); the preset section header is the unnumbered "Choose a device", and deep sleep / configure are unnumbered.
- Issue: A numbered sequence with a single member reads as unfinished; the intended flow (preset → hardware → sleep → configure) is conveyed only by layout.
- Recommendation: Number all steps or drop the "1.".

**[LOW] Status Log: one-tap destructive clear, no share, 50-entry cap — all unlike the sibling tools**
- Location: `Views/ToolboxView.swift:510-524` (`logSection`), `:757-759` (`addLog`).
- Issue: The Toolbox keeps its own private status log with a different visual language (colored dot + monospaced caption vs `LogEntryRow`), a 50-entry cap, no share/export, and an unconfirmed "Clear Log" — while BLE Tester confirms the equivalent action.
- Impact: Users learn three different log behaviors across three adjacent tools; a config-write error trail can't be exported the way the BLE log can.
- Recommendation: Reuse `LogEntryRow` styling (or at least the confirm-before-clear pattern), and consider mirroring status entries into the shared BLE log so one export captures everything.

**[INFO] Positive observations**
- This is the only Engineering Tool with an in-place connect affordance (`connectionSection`, `ToolboxConnectionSheet`) — the pattern the Advanced sheet itself lacks (see cross-tool findings).
- The dirty-state badge, validation-gated Write button, and confirmation dialogs for destructive actions are the strongest UX patterns in the section and worth propagating to the other two tools.

## BLE Tester

The Tester's command panel is genuinely good: hex inputs are cleaned and validated before send, malformed payloads show an inline error instead of being silently dropped, the spinner is driven by the real send completion, and disconnection is surfaced with a banner and a disabled Send. The findings are concentrated in the log panel and in edge cases of the raw-opcode path.

### Findings

**[HIGH] Sending `Image Data (0x0071)` — a preset in the Tester's own menu — produces no visible sent packet and no visible ACK**
- Location: `BLE/ODDevice.swift:717-726` (`appendLog`: `let isImageChunk = data.count >= 2 && data[1] == 0x71; guard BLELogging.detailedPayloads || !isImageChunk else { return }`); preset offered at `BLE/ODConstants.swift:69-74` / `Views/BLETesterView.swift:54-59`.
- Issue: The image-chunk log suppression (a sensible flood guard for real uploads) keys on "second byte == 0x71" for *all* sent and received packets. A Tester send of the `Image Data (0x0071)` preset (packet `00 71 …`) is suppressed, and so is the device's `00 71` ACK notification. Any raw packet whose second byte happens to be `0x71` (e.g. raw opcode `FF71`) is suppressed too. Only the `sendRaw Image Data (0x0071): NB` system trace appears.
- Impact: An engineer explicitly sends a packet from the Tester and watches it never appear in the log, nor any response — the tool appears broken, or the device appears dead. This defeats the Tester's entire purpose for that command, and the suppression is undiscoverable (the `detailedPayloads` launch flag is mentioned nowhere in the UI).
- Recommendation: Exempt Tester-originated sends from the suppression (e.g. `sendRaw` already traces with a label — pass a "forceLog" flag through, or suppress only when `uploadPhase == .sending`). At minimum, log a one-line system entry: "image-data packets hidden; launch with detailed-payloads flag to show".

**[HIGH] Auto-scroll permanently stops once the log reaches its 500-entry cap**
- Location: `Views/BLETesterView.swift:130` (`.onChange(of: ble.log.count)`) vs `BLE/BLEManager.swift:115-120` (`appendLog` appends then trims within the same call).
- Issue: After the cap is hit, every append is immediately followed by a trim, so `ble.log.count` is pinned at 500 and `onChange` never fires again. New entries still render (the array changes), but the view stops following the tail.
- Impact: Exactly during long or busy sessions — the situation the Tester exists for — the console silently freezes at an old scroll position while traffic continues below the fold. Failure scenario: any session with >500 entries (a single connect + config read plus traces gets a good way there); every subsequent send appears to produce no response until the user manually scrolls.
- Recommendation: Observe `ble.log.last?.id` instead of `count` (fires on every append regardless of trimming).

**[MEDIUM] Auto-scroll fights the user: any incoming entry yanks the view back to the bottom**
- Location: `Views/BLETesterView.swift:130-134`.
- Issue: There is no way to pause following. Scrolling up to inspect an earlier request/response pair while background traces keep arriving (connection chatter, advertisement parses) triggers an animated `scrollTo(bottom)` on each entry.
- Impact: Reading history during live traffic — the core workflow when debugging a flaky connection — is nearly impossible.
- Recommendation: Standard console pattern: track whether the user is scrolled near the bottom (or add an explicit pause/"follow" toggle) and only auto-scroll when following; show a "jump to latest" pill otherwise.

**[MEDIUM] Raw opcode length is unvalidated and packet framing silently shifts**
- Location: `Views/BLETesterView.swift:155-158` (`isOpcodeValid` only checks "parses as hex"), `:178-181` (packet assembly); `Resources/ble-common.js:1582-1590` (`sendHexCommand` auto-prepends `00` only when the *total* packet is one byte).
- Issue: The protocol expects a 2-byte command ID. A 1-byte opcode `43` with an empty payload is silently rewritten to `0043` by the JS layer; the same opcode with payload `01` produces the packet `43 01`, which the JS logs — and the device parses — as command `0x4301` with no payload. A 3-byte "opcode" shifts framing similarly. The behavior of identical opcode input differs depending on whether a payload is present, and nothing in the UI says the field must be 2 bytes.
- Impact: An engineer typing shorthand (`43` for firmware) gets correct behavior in the no-payload case and a silently different command in the payload case — the worst kind of inconsistency in a raw tester.
- Recommendation: Validate the opcode as exactly 2 bytes (the placeholder `0x0043` already implies it), or explicitly document/normalize 1-byte input by prepending `00` on the Swift side before appending the payload.

**[MEDIUM] Stale `lastError` banner is never cleared for the rest of the session**
- Location: `Views/BLETesterView.swift:35-40`; root cause in `BLE/ODDevice.swift` — `lastError` is assigned in ~15 places and set to `nil` nowhere in the codebase.
- Issue: One failed send (or an unrelated failure — a firmware-read timeout at connect, an auth error) pins a red warning banner at the top of the command panel permanently, even after dozens of subsequent successful sends.
- Impact: When debugging flakiness, "is there currently an error?" is the key question, and this banner answers it wrongly. (The same stale value feeds the banner in `BLELogView` — see below.)
- Recommendation: Clear `device.lastError` when a Tester send succeeds (`sendRaw`'s success arm), or timestamp errors and show only ones newer than the last successful send; ideally make it dismissable.

**[MEDIUM] Invalid opcode input gives no inline feedback — Send just goes dead**
- Location: `Views/BLETesterView.swift:81-85` (payload gets a red caption) vs nothing for the opcode field; `cleanHex` at `:142-146`.
- Issue: A malformed opcode (odd length, uppercase `0X43` — `cleanHex` strips only lowercase `"0x"`, so the `X` survives and parsing fails — or a stray character) silently disables Send with no message, while the payload field demonstrates the right pattern. Also note `cleanHex` removes `"0x"` *anywhere* in the string, so `010x02` quietly becomes `0102`.
- Recommendation: Mirror the payload's inline error for the opcode ("Opcode must be 2 hex bytes, e.g. 0x0043"), strip the prefix case-insensitively and only at the start.

**[LOW] Received rows are labeled only "OK"/"ERR", masking which command they answer**
- Location: `BLE/ODDevice.swift:734-738` (`responseLabel`), rendered by `LogEntryRow` (`Views/BLETesterView.swift:203` — `entry.label ?? entry.commandName`).
- Issue: Every notification gets the label "OK" or "ERR" from its status byte; because `label` wins over `commandName`, the row never shows the echoed command (`00 43 …` would otherwise resolve to "Read Firmware (0x0043)" via the `commandName` fallback). With multiple commands in flight or queued, request/response correlation is guesswork.
- Recommendation: Compose the label — e.g. "OK · 0x43" / "Read Firmware OK" — in `responseLabel`.

**[LOW] Sends can leave the spinner stuck while still connected**
- Location: `Views/BLETesterView.swift:184-189`; `BLE/CoreBluetoothTransport.swift:30-57`.
- Issue: `sendRaw` has no watchdog (unlike every other operation in `ODDevice`). If the write sits in the transport queue because `canSendWriteWithoutResponse` never becomes true, the completion never fires and `isSending` disables Send indefinitely. Disconnect *is* handled (`setConnected(false)` rejects pending JS calls), so this is the connected-but-wedged case only.
- Recommendation: Arm a short (2–3 s) watchdog around the Tester send that resets `isSending` and logs a "send still queued" system entry.

**[LOW] Encrypted-session sends log ciphertext with a misleading decode**
- Location: `Resources/ble-common.js:681-701` (`sendCommand` transparently encrypts everything except 0x0043/0x0050 once authenticated); logging at `BLE/ODDevice.swift:180-187` (`onWrite` logs the wire bytes).
- Issue: After authenticating, a Tester send is encrypted before hitting `onWrite`, so the "sent" log row shows ciphertext whose first two bytes may randomly decode to a wrong `commandName`, and never shows the plaintext the user actually typed. Nothing indicates encryption occurred (the JS-side "Encrypting command…" log goes to `ODLog.proto`, not the shared log).
- Recommendation: When the runtime reports encryption (the `log` event carries the message), mirror a system entry into the shared log, or tag the sent entry ("encrypted").

**[LOW] Empty log panel is a blank gray void**
- Location: `Views/BLETesterView.swift:117-136`.
- Issue: Before any traffic (or after Clear), the lower half of the screen is empty with no placeholder; `BLELogView` handles the same state with "No activity yet."
- Recommendation: Add the same placeholder, ideally with a hint ("Sent and received packets appear here").

**[INFO] Minor polish**
- Duplicate `.navigationTitle("BLE Tester")` — set on the destination in `Views/AdvancedView.swift:24` and again in `Views/BLETesterView.swift:20`.
- `Picker("", selection: $usePresetCommand)` (`:47`) has an empty accessibility label; give it a hidden label ("Command mode").
- Preset commands that require payloads (Image Start, LED Pattern, Buzzer, NFC) send bare 2-byte headers with no hint of the expected payload shape — acceptable for a raw tester, but a per-command placeholder in the payload field would save trips to the protocol docs.
- The red trash button clears the *app-wide* shared log; its placement beside Send suggests it clears "this screen". The confirmation dialog does explain this — good — but an icon-only destructive button with an explanatory dialog is doing discoverability work a label could do up front.
- Timestamps on rows are minute-precision — see cross-tool findings.

## BLE Log

Structurally the simplest tool, and mostly correct: the filter enum maps cleanly onto `LogEntry.Direction`, both empty states ("No activity yet." vs "No entries match this filter.") are distinguished and handled, Share/Clear correctly hide when the log is empty, and the export format (`HH:mm:ss.SSS` + direction glyph + label + hex) is genuinely useful. The problems are ordering/reachability, destructive-action safety, and silent truncation.

### Findings

**[HIGH] The log opens at the oldest entry, and Share/Clear are buried beneath up to 500 rows**
- Location: `Views/AdvancedView.swift:112-152` — entries render in chronological (append) order in a plain `List`, with the `ShareLink` and Clear button as the final rows of the same section; no toolbar items, no auto-scroll.
- Issue: The most recent event — almost always the reason the screen was opened — is at the very bottom, and the two actions are below it. With a capped-out log, reaching "what just happened?" or the Share button means flicking through 500 rows.
- Impact: In the field ("it just failed — show me the log / send me the log") this is the slowest possible path; users will screenshot instead of using Share because they can't find it.
- Recommendation: Move Share and Clear into the navigation bar as toolbar items (the standard place), and either reverse the sort (newest first, the convention for diagnostic log screens) or scroll to the bottom on appear.

**[MEDIUM] One-tap, unconfirmed Clear destroys the shared session log**
- Location: `Views/AdvancedView.swift:145-149` vs `Views/BLETesterView.swift:21-26`.
- Issue: The BLE Tester requires a confirmation dialog to clear this exact same shared log ("This clears the app-wide log shown here and on the BLE Log screen."); the BLE Log screen clears it with a single tap and no warning. The action is irreversible and the data may be the only record of a hard-to-reproduce failure.
- Impact: A mis-tap (the button sits directly under the last log row, where a scroll flick lands) erases the evidence an engineer spent an hour collecting.
- Recommendation: Add the same confirmation dialog; ideally share one component/handler between the two screens so they can't drift again.

**[MEDIUM] The 500-entry cap is invisible: trimmed logs and truncated exports look complete**
- Location: `BLE/BLEManager.swift:104-120` (silent `removeFirst` trim), consumed at `Views/AdvancedView.swift:107-110, 128-139` and by `formattedLog` (`:157-172`); the comment at `:128-130` documents showing "the full retained log" but nothing tells the *user* about retention.
- Issue: Once >500 entries have been logged, the oldest are silently gone — from the screen, from every filter, and from the Share export. There is no "showing last 500 entries" row, no count anywhere, and the export has no header noting truncation.
- Impact: An engineer shares a log to prove "the error happened right after connect" and the connect-time entries have been trimmed away without anyone knowing they ever existed. The graceful *memory* handling is not matched by graceful *UI* handling.
- Recommendation: When `ble.log.count == 500` (or better, track a `didTrim`/total-appended counter in `BLEManager`), show a first-row notice ("Older entries were trimmed — showing the most recent 500 of N") and prepend an equivalent header line to the export.

**[MEDIUM] `formattedLog` (and a fresh `DateFormatter`) is rebuilt on every body evaluation**
- Location: `Views/AdvancedView.swift:142` (`ShareLink(item: formattedLog, …)`), `:158-172`.
- Issue: `ShareLink`'s `item` is evaluated eagerly each render, and this screen re-renders on every log append (it observes `ble` directly). At cap, that is a 500-entry string concatenation plus a `DateFormatter()` allocation per BLE event, on the main thread, for a string that is discarded unless the user actually shares.
- Impact: Wasted main-thread work exactly when traffic is heaviest; on older devices this can make the log screen stutter during an active session.
- Recommendation: Use `ShareLink` with a `Transferable` that formats lazily, or gate behind a Share button that computes the string on tap; hoist the formatter to a `static let`.

**[MEDIUM] Stale `lastError` banner (same defect as the Tester)**
- Location: `Views/AdvancedView.swift:122-126`; `ODDevice.lastError` is never reset to `nil`.
- Issue: The red triangle banner pinned above the entries reflects the last error of the *session*, not the current state, and there is no timestamp on it to say when it happened.
- Recommendation: Same fix as the Tester finding; at minimum render the error's age, or derive the banner from the newest system-direction error entry in the log itself (which carries a timestamp).

**[LOW] Share exports the unfiltered log with no context header, as bare text**
- Location: `Views/AdvancedView.swift:142, 157-172`.
- Issue: With "Received" selected, Share still exports everything — a deliberate choice (the doc comment says so) but invisible to the user, who reasonably expects WYSIWYG. The export also lacks any header (device name, firmware, app version, date — all available) and shares as a plain string rather than a named `.txt`/`.log` file, so it arrives in Messages/Mail as an unlabeled wall of text.
- Recommendation: Either respect the active filter or label the action "Share Full Log"; prepend a small metadata header; export via `Transferable` as a named file (`OD-BLE-log-2026-07-14.txt`).

**[LOW] Filter segments give no counts and "All" is dominated by system chatter**
- Location: `Views/AdvancedView.swift:115-118`; system entries are produced by every `trace()` in `BLEManager`/`ODDevice`/transport, typically outnumbering real traffic several-fold.
- Issue: There is no indication of how many entries each filter would show ("Sent (12)"), and no way to see traffic-only (Sent+Received) — the pairing an engineer usually wants — without the system noise.
- Recommendation: Add counts to the segment labels and consider a combined "Traffic" filter.

**[INFO] Correctness notes that check out**
- Filter logic, both empty states, and hiding Share/Clear on an empty log are all correct, including the corner case "entries exist but none match the filter" (`:131-134`).
- Concurrent appends while viewing are safe: all log mutation is main-thread (`BLEManager` uses `queue: .main`; `trace` hops to main), and SwiftUI diffing of the `Identifiable` entries handles live updates. Clearing from the Tester while this screen is open correctly collapses it to the empty state.
- The clear-vs-filter interaction is fine (clear empties the source; the filtered view falls through to "No activity yet.").

## Cross-tool consistency observations

1. **Three log surfaces, three designs, three caps, three clear semantics.** Toolbox `statusLog` (private, 50 entries, colored dot + monospaced caption, unconfirmed clear, no share), BLE Tester (shared log, 500, `LogEntryRow`, confirmed clear, no share, auto-scroll), BLE Log (same shared log, `LogEntryRow`, *un*confirmed clear, share, no auto-scroll). A user cannot form a single mental model of "the log" — most confusingly, clearing in the Tester or BLE Log wipes a shared resource while clearing in the Toolbox does not, and only one of the three warns first. Unify on `LogEntryRow` + one confirm-to-clear component, and consider feeding Toolbox status lines into the shared log as system entries.

2. **On-screen timestamps are minute-precision on a millisecond protocol.** `LogEntryRow` uses `Text(entry.timestamp, style: .time)` (`Views/BLETesterView.swift:210`) — "9:41 AM" — while the export uses `HH:mm:ss.SSS`. For BLE debugging (ACK latency, watchdog windows, retry gaps) seconds and milliseconds are the entire point; the data is already captured, just not shown. One formatter change fixes both Tester and BLE Log.

3. **The disabled "BLE Tester" row is honest but a dead end — and the explanation misdirects.** The greyed label (`Views/AdvancedView.swift:29-32`) correctly signals unavailability, and the section footer does explain why ("Connect a display (via the Toolbox or a saved display) to use the BLE Tester."). But: (a) the footer says "Toolbox" while the menu row above is titled "Device Configuration" — the referenced path doesn't exist by that name on this screen; (b) the row itself is inert with no per-row hint, and footers are easy to skip; (c) the adjacent "Connection" section says "No device connected." yet offers no Connect action, even though a ready-made `ToolboxConnectionSheet` exists one file over. Recommendation: put a "Connect to OpenDisplay" button in the Connection section (reusing `ToolboxConnectionSheet`), fix the footer naming, and optionally keep the Tester row tappable-when-disabled to surface the explanation in place.

4. **Layout idioms diverge more than they need to.** Device Configuration and BLE Log are grouped `Form`/`List` screens; the Tester is a custom split panel. The split-console layout is the right call for a tester, but shared pieces should still match: the Tester's error banner is a bare `Label` while BLE Log's sits in a list row; the Tester lacks BLE Log's empty-state text; BLE Log lacks the Tester's clear confirmation. The SF Symbol language at the menu level (`wrench.and.screwdriver`, `antenna.radiowaves.left.and.right`, `doc.text.magnifyingglass`) is consistent and good.

5. **`lastError` is a session-lifetime global consumed as if it were current state** in both the Tester and BLE Log (and the Toolbox logs it via `onChange`). Fixing it once in `ODDevice` (clear on subsequent success, or timestamp it) repairs all three surfaces.

6. **Duplicated title/navigation setup** (Tester title set both at the `NavigationLink` destination and inside the view) and the Advanced footer's conditional messaging are small, but tidying them alongside item 3 would make `AdvancedView` the single owner of the section's navigation chrome.
