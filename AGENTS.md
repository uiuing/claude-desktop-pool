# Claude Pool — notes for coding agents

Claude Pool is a native macOS account pool and local bridge for Claude Desktop. Read [`docs/product.md`](docs/product.md) and [`docs/architecture.md`](docs/architecture.md) before changing behavior. Human contributors: see [CONTRIBUTING.md](CONTRIBUTING.md).

## Boundaries

- Model access goes through the official Claude Code client in a stable app-owned account directory, in interactive mode with the MCP helper, hooks, status line and the Bun preload tap that copies the reply stream. No paid inference API, token replay or credential extraction. Managed policy and the client's permission prompts stay the user's.
- Never read or log credentials. Keep secrets and conversation bodies out of logs, diagnostics and repository artifacts; the app log records decisions, counts and timings. Persistent account metadata is credential-free; temporary conversation files are private to the app. The one exception is the developer recording (`DevRecord`, see architecture): off unless the person turns it on in Settings and confirms twice, clearable there, local and private, never holding Pool's own credentials; new boundaries record through it.
- Text redaction is on unless the person turns it off in Settings after a confirmation, and runs the local AstrLink Guard model: a bounded wait for the model, rules for whatever it has not read yet, and nothing sent to a remote redaction service. Model updates keep the license, label and checksum checks.
- Own only app-created processes and files; never force-kill. Desktop is connected by the user's Connect, which records Desktop's settings before writing Pool's profile; Disconnect restores them. Desktop is restarted only after asking.
- Local networking binds loopback, requires authentication and rejects browser origins.
- Respect a confirmed account limit until recovery; never change identity to retry a content or policy refusal; never repeat a tool call or partial answer already sent.

## Structure and checks

Xcode 26 (Swift 6 toolchain, macOS 26 SDK), Swift 5 language mode, deploying to macOS 14+. Foundation core and native SwiftUI shell, with a pinned official ONNX Runtime package for the local privacy model. `CPTY` is the small owned-process adapter. Preserve third-party licenses and notices in the distribution.

Run `swift build`, `swift test` and `python3 scripts/check-localization.py`. Unit tests never call Claude or outside services; model their fixtures on Claude Code's real request and transcript shapes, not idealized ones. Fixtures use synthetic identities such as `example.com` or `.invalid` hosts. Render demo screenshots through `scripts/screenshots.sh` for UI changes and inspect them; app previews use `--demo`.

UI text uses the localization catalogs in `Sources/PoolCore/Localizations`; every supported language is updated together. Keep copy short, unknown quota explicit and errors actionable. Use original artwork and system symbols. Runtime details stay out of ordinary user flows.
