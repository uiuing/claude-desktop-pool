# Changelog

All notable changes to Claude Pool are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/uiuing/claude-desktop-pool/compare/v0.1.6...HEAD
[0.1.6]: https://github.com/uiuing/claude-desktop-pool/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/uiuing/claude-desktop-pool/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/uiuing/claude-desktop-pool/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/uiuing/claude-desktop-pool/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/uiuing/claude-desktop-pool/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/uiuing/claude-desktop-pool/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/uiuing/claude-desktop-pool/releases/tag/v0.1.0
