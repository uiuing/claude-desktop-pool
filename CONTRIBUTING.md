# Contributing to Claude Pool

Thanks for your interest in improving Claude Pool. Bug reports, fixes, translations and documentation are all welcome.

## Before you start

- Read the [product contract](docs/product.md) and the [architecture](docs/architecture.md). They describe what Pool promises and what it deliberately does not do.
- For anything larger than a small fix, open an issue first so we can agree on the approach.
- Security problems go through [SECURITY.md](SECURITY.md), not public issues.

## Ground rules

- Model access goes only through the official Claude Code client. Changes that add paid API calls, copy or replay tokens, or read credentials will not be accepted.
- Never log credentials, secrets or conversation text. Logs record decisions, counts and timings.
- Pool owns only the processes and files it creates, and never force-kills.
- The local gateway stays on loopback, authenticated, and closed to browser origins.

## Development setup

macOS 14 or later with a Swift 6 toolchain (Xcode or the command line tools).

```bash
swift build
swift test
python3 scripts/check-localization.py
```

To try the app without accounts or network access:

```bash
zsh scripts/build.sh
open "dist/Claude Pool.app" --args --demo
```

The demo mode shows synthetic data only and starts no Claude process.

## Checks before a pull request

| Change | Run |
| --- | --- |
| Any code | `swift build`, `swift test` |
| UI text | `python3 scripts/check-localization.py` |
| UI layout | `zsh scripts/screenshots.sh`, then look at the images in `.build/screenshots` in light and dark mode |
| Packaging or helpers | `zsh scripts/build.sh --universal`, `python3 scripts/check-package.py`, `python3 scripts/check-packaged-bridge.py` |

Tests never call Claude or any outside service. Use synthetic identities such as `name@example.com` or `.invalid` hosts in fixtures, and model fixtures on the shapes the real client sends.

## Localization

UI strings live in the catalogs under `Sources/PoolCore/Localizations`. English, Simplified Chinese, Traditional Chinese, Japanese and Korean are updated together; the localization check fails if a key is missing in any of them. Keep copy short and errors actionable.

## Pull requests

- Keep each pull request focused on one change, and describe what a user will notice.
- Add a line under `Unreleased` in [CHANGELOG.md](CHANGELOG.md) for user-visible changes.
- Include before and after screenshots for UI changes.

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
