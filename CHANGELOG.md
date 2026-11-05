# Changelog

All notable changes to Claude Pool are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/uiuing/claude-desktop-pool/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/uiuing/claude-desktop-pool/releases/tag/v0.1.0
