# Changelog

All notable changes to Claude Pool are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.2] - 2026-11-10

### Changed

- The model limit beside the 5-hour and weekly ones in the menu bar ("F72%") is written in the menu bar's ordinary type instead of a larger bold one.

## [0.2.1] - 2026-11-10

### Fixed

- Images you paste in Desktop, and other files under Claude Code's own folders, can be opened again when redaction is on. Claude Code names these folders after your project's path, so your account name sits between hyphens there (`-Users-<name>-Documents-…`). Pool masked it there but never put it back, so Claude was told such a file does not exist.

### Changed

- The app log follows each message you send while tools run: when it is queued in Claude Code, and when it reaches the model. Only lengths and timings are kept.

## [0.2.0] - 2026-11-10

### Added

- Each model's own weekly limit, such as Fable's, is shown wherever the 5-hour and weekly limits are: in the menu bar, the plan summaries, each account and the routing page, with its reset time. The menu bar keeps the 5-hour limit over the weekly one and shows the tightest model limit beside them in larger type ("F72%").
- Fable 5.2 is priced in the Usage page.

### Changed

- Claude Pool checks for Claude Code updates every four hours instead of once a day, also while it stays open in the background, so new models such as Fable 5.2 arrive sooner. Settings › Services has a Check for updates button that installs a newer Claude Code at once.

### Fixed

- Using up Fable's weekly limit no longer stops the whole account for a week. Only Fable waits for that limit's reset; Sonnet and Opus keep working on the account. Accounts 0.1.9 held back this way are released on update.
- A model's limit named with a version, such as "Fable 5.1", is recognised as that model's limit instead of a limit on every model.
- After Claude refuses Fable on an account, Fable stays off that account until the limit's reset, even when the usage panel still shows some room. Requests no longer go back to it and get refused again.
- When Claude Code asks whether Fable should go on usage credits, as it does on Pro once the included Fable week ends, Pool closes the question without answering and moves the request to another account at once, instead of waiting ten minutes for it to fail. Pool never agrees to spend usage credits.
- A limit Pool does not recognise no longer holds an account back on a reading alone; a refusal at it still moves the request and holds the account until its reset.
- A conversation with many images no longer fails, and keeps being retried, when it moves to another account or starts a new session. Claude Code redraws only the parts of its input that changed, so Pool missed an image it had already shown, gave up after ten seconds and told Desktop to try again; each try typed the whole conversation once more and failed the same way. Pool now reads the image from the input as it appears on screen.
- If a conversation still cannot be typed into Claude Code twice in a row, Desktop shows the error instead of retrying without end.
- Quota in Claude Code's newer status-line layout is read.
- Key text such as limit names, reset times and account names is no longer cut off; long lines wrap instead.

## [0.1.9] - 2026-11-09

### Fixed

- Whatever Desktop sends now reaches Claude as it came, whatever its kind. A block other than text or an image, such as a PDF embedded in a message or in what a tool returned, used to be left out without a word. Files attached in Desktop were not affected: they arrive as paths, and Claude opens them with its tools.
- An image or file sent while a tool runs no longer fails the request and makes the conversation write itself to the cache again. An image goes with the tool's result; anything else goes on from the conversation's session on the same account.
- Redaction leaves a file's encoded bytes as they are and redacts the words in it.
- The app log no longer reports a reply's tools as changed when they were the same.

## [0.1.8] - 2026-11-09

### Changed

- Restarting or updating Claude Pool with redaction on no longer makes open conversations write themselves to the cache again. Their redaction is kept across the restart without any original value: only digests, positions and lengths, in the app's private folder for 24 hours. Parallel tasks of one conversation each keep theirs.
- Redaction no longer holds a request while it reads earlier text the local model had not read yet; that text is read once no request waits. Requests are read faster: the model uses up to four threads and reads one piece at a time.
- This Mac's account name is redacted in Desktop's requests.
- A subagent's turns and one-off asks, such as the auto mode classifier, keep their prompt cache for five minutes, as Claude Code does on a subscription, instead of an hour. Their writes are seldom read again and cost less kept briefly; a main conversation still keeps its cache for an hour.
- The app log says why each reply wrote the prompt cache, and why a run's session could not go on when a turn is told whole.
- A conversation still small on an account nearly used up, such as just after a compaction, moves at its next turn to an account with clearly more left. Moving writes the conversation's whole context on the new account, so it moves while that is cheap instead of growing there until the limit stops it and the move costs far more.

### Fixed

- A reply cut off after a tool's results were sent, because Desktop stopped it or lost the connection, no longer makes the conversation write itself to the cache again when Desktop sends those results once more: it goes on from the session cut before the call, on the same account.
- A long decimal number, such as a time in a test report, is no longer redacted as a card or ID number.
- A secret or password written before Chinese text no longer takes the following words with it, and a link is no longer redacted as a secret.
- A short hex id, such as a commit or a log tag, is no longer redacted as an account or a secret unless a name such as `token=` comes before it.

## [0.1.7] - 2026-11-09

### Fixed

- An account Claude refused at its 5-hour limit now shows that limit at 0 until its reset, matching its status. Before, the ring showed what Claude's usage panel still read, such as 19% left; hovering it now shows that reading.
- A conversation no longer writes itself to the cache again after a note from Claude Code, such as an environment or tool update or a reminder that the user is waiting. Pool used to move the note to the next turn once the conversation went on, so the conversation looked edited and was started over.
- Claude Code's compaction of a long conversation no longer writes the whole conversation to the cache again. It goes on from a copy of the conversation's own session, cut before the call it was made at.
- A restart keeps new conversations leaning toward accounts already warm with their model.
- Desktop's context meter now shows a conversation's real size. Pool used to say what a request read only at the end of each reply, so the meter showed a few hundred tokens while the conversation was nearly full and compacted without warning.

## [0.1.6] - 2026-11-08

### Fixed

- A new conversation now stays on an account that already holds its model's cache when the others have about as much left. In 0.1.5 this almost never applied: it required the same instructions as an earlier conversation and counted too little of what the cache holds.
- Updating or restarting Claude Pool no longer makes each open conversation write itself to the cache again. Conversations go on from their own sessions after the restart.

## [0.1.5] - 2026-11-08

### Changed

- A conversation reads more of its prompt cache. When a tool runs long and its run is let go, or a reply fails or is stopped, the conversation goes on from its own session on the same account instead of writing the whole conversation to the cache again.
- A new conversation with the same instructions and tools as one an account served within the hour leans toward that account when the others have about as much left, so it reads that account's cache. An account with clearly more left still comes first.

## [0.1.4] - 2026-11-07

### Added

- Sensitive data redaction can be turned off in Settings after a confirmation; new requests then go to Claude as written.
- The full log in Settings › General keeps everything Pool receives and sends on this Mac for your own analysis. It asks twice before it turns on, shows its size and can be cleared there. It keeps each conversation once, adding only what is new at each turn, and redaction as each replacement in its context.

### Fixed

- An account whose week resets within two days now ranks ahead of accounts whose weeks have days to go: what its week has used comes back at the reset, so its remaining share is spent first.
- A conversation forked in Claude Desktop stays on the account of the conversation it came from, so it reads that conversation's prompt cache. With redaction on, a fork could go to another account.

## [0.1.3] - 2026-11-06

### Fixed

- Update and restart no longer freezes the app after the download: the quit it starts now runs, the new version is installed and Claude Pool opens again.
- Quitting while a conversation is going on no longer asks you to finish or cancel a sign-in. Quit waits a few seconds for Pool's own account check and goes on. Messages about a sign-in now appear only while you are adding an account, and say what is left to do.
- An account whose week is nearly used up no longer ranks ahead of others just because its 5-hour limit is full: below a quarter of the week left, the 5-hour share counts only in proportion.

## [0.1.2] - 2026-11-06

### Fixed

- Claude Pool could not quit after a session refused a tool call: the run's leftover result file kept the session from being cleaned up, so every quit was refused. A run now ends once its client has exited, and a folder it cannot remove is logged and left behind.
- Sessions replaced or ended during routing leave the app's list, so the session count shown when quitting is correct.

## [0.1.1] - 2026-11-06

### Added

- Before the first account signs in, Pool warns that Anthropic may suspend or ban an account used this way and goes on only once you accept.
- Conversations stay on their accounts after Pool restarts, and when Desktop starts a new client session for the same conversation.
- A small indicator shows while Pool quits and its Claude sessions end.
- A limit the pool will start by itself reads "Starting automatically" instead of waiting for first use.

### Changed

- New conversations go to the account that suits them best, weighing the 5-hour limit, the week, coming resets and the conversations already on it. Accounts are listed in that order.
- Quota is read for up to three accounts at once, and a read you ask for no longer waits out a failed read's retry delay.
- Refresh all takes the click across its whole label, and its arrow turns until the readings are in.
- Quitting ends all sessions together.
- The app log explains problems the first time they happen: state changes, routing decisions, stalled replies and each run's recent steps, still without any content. It now rotates at 10 MiB.

### Fixed

- A conversation whose run cannot take its next turn goes on in a new run on the same account instead of failing.
- An account that lost its sign-in asks you to sign in instead of loading until the read times out or showing old figures.
- A failed read waiting for its retry shows as failed instead of spinning, and old figures are marked stale only when reads are failing.
- A reading taken right after a reset that still shows the ended cycle is recognized as old.
- A tool result that arrives during quit no longer starts a new run, and a client that stops reading no longer holds quit open.
- The menu panel shows use and the next account on their own lines, so neither is cut.

## [0.1.0] - 2026-11-06

First public release.

### Added

- Native macOS menu bar app with a main window, in English, Simplified Chinese, Traditional Chinese, Japanese and Korean, with light and dark appearance.
- Account pool backed by the official Claude Code client: each account signs in through Claude's own login in an isolated, app-owned folder and is identified by its verified email.
- One-click Connect and Disconnect for Claude Desktop, restoring Desktop's previous settings on disconnect. Chat, Cowork and Code in Desktop all use the pool.
- Local authenticated gateway for Desktop's Messages requests, with streamed replies, images and Desktop tools returned through an MCP bridge.
- Routing that keeps a conversation on its account and hands it to an account with more headroom only at a new user turn.
- Quota display in the menu bar, dashboard and accounts page, read from the official client, with exact reset times and an explicit unknown state.
- Optional warm-up that starts limits at their resets.
- Usage page with tokens, replies, cache hit rate and estimated cost by model, plan and account.
- Local sensitive data redaction with the AstrLink Guard model, updated automatically to compatible releases.
- Automatic installation and updates of the managed Claude Code client.
- Update checks against GitHub Releases with verified one-click install.
- Option to hide email addresses throughout the app.

[Unreleased]: https://github.com/uiuing/claude-desktop-pool/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/uiuing/claude-desktop-pool/compare/v0.1.9...v0.2.0
[0.1.9]: https://github.com/uiuing/claude-desktop-pool/compare/v0.1.8...v0.1.9
[0.1.8]: https://github.com/uiuing/claude-desktop-pool/compare/v0.1.7...v0.1.8
[0.1.7]: https://github.com/uiuing/claude-desktop-pool/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/uiuing/claude-desktop-pool/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/uiuing/claude-desktop-pool/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/uiuing/claude-desktop-pool/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/uiuing/claude-desktop-pool/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/uiuing/claude-desktop-pool/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/uiuing/claude-desktop-pool/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/uiuing/claude-desktop-pool/releases/tag/v0.1.0
