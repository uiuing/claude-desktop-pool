# Security policy

Claude Pool handles Claude sign-ins, a local gateway and conversation text, so security reports are taken seriously.

## Reporting a vulnerability

Please do **not** open a public issue. Report privately through [GitHub's private vulnerability reporting](https://github.com/uiuing/claude-desktop-pool/security/advisories/new).

Include what you found, how to reproduce it, and the impact you expect. Leave out real credentials, tokens and conversation content; synthetic examples are enough.

You will get an acknowledgement as soon as possible. Once a fix is released, the advisory is published with credit to you unless you prefer otherwise.

## Supported versions

Fixes go into the latest release. Please check that the problem still happens on the [latest version](https://github.com/uiuing/claude-desktop-pool/releases/latest) before reporting.

## Scope

In scope: the Claude Pool app, its local gateway, the bundled helpers and the update installer.

Out of scope: Claude Code, Claude Desktop and Anthropic's services (report those to [Anthropic](https://www.anthropic.com/responsible-disclosure-policy)), and the AstrLink Guard model's detection accuracy, which is a known limitation rather than a vulnerability.
