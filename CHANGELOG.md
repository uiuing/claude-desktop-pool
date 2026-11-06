# Changelog

All notable changes to Claude Pool are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/uiuing/claude-desktop-pool/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/uiuing/claude-desktop-pool/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/uiuing/claude-desktop-pool/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/uiuing/claude-desktop-pool/releases/tag/v0.1.0
