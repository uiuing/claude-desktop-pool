# Compatibility

The bridge uses the official interactive CLI, driven with a Bun preload tap: the tap copies the reply stream the client receives, and changes nothing the client sends or reads. It never falls back to `-p`, API credentials, copied tokens or forged client identity. A conversation no live run holds is given to a new run as a saved session in Claude Code's own transcript form (two lines, resumed with `--resume`), rather than pasted whole. Turns are read from the session's transcript; hooks are hints and never fail a turn.

## Supported protocol surface

The gateway provides Messages requests, text and image input, standard client tool calls/results, local model aliases and streamed/nonstreamed responses. The aliases select the installed client's Sonnet, Opus, Haiku and Fable families; they are not promises of a particular model version or plan entitlement. Availability and any native usage-credit consent remain with the official client. Pool never answers those consent prompts automatically.

The native client owns its output length and cache policy. `max_tokens` and ephemeral cache markers are advisory; responses identify this with `x-claude-pool-output-limit: official-client` and `x-claude-pool-cache: official-client`. Nothing is refused for asking more than the interactive client can apply: sampling and stop sequences are not applied, `tool_choice` is told to the session (a named tool is the only one offered, `any` asks for a call, `none` answers each call with "No tool can be used for this reply"), a structured answer goes through an answer tool checked against its schema, and the client's web search is the session's own WebSearch. Native-default adaptive thinking does not cause Pool to fabricate signed thinking blocks. Usage is the transcript's measured counts, summed over the reply's messages; a reply that reports none ends with zero, rather than failing. Text streams as Claude Code receives it, through the tap; a client that does not load the tap tells each message whole, as the transcript records it. Desktop compatibility and callback timing are required acceptance gates.

Live tool results can contain standard base64 screenshots and text. User images are validated, written to private run-owned files and pasted as paths through the CLI's normal image input. The adapter waits for a new native image acknowledgment before submitting the contextual prompt, and sends Enter once. Missing acknowledgments fail without sending incomplete input. Images in earlier turns go into the saved session as image blocks and are never pasted. No clipboard is changed. These paths pass fixture tests; real-client image acceptance remains a release gate.

## Observation

The session transcript gives the message taken, text, tool calls, usage, the turn's end (`turn_duration`) and the client's own API errors (`<synthetic>` rows). Permission, notification and session-end hooks remain as hints that only report data and never return permissions, instructions or continuation decisions.

[StatusLine](https://code.claude.com/docs/en/statusline) supplies rate limits after model activity. Redrawing the UI or replaying an unchanged callback does not refresh an observation. Pool's current accounts are those with retained, non-ended workers, including an idle conversation between turns, kept up to an hour. A run let go sooner keeps its session for the conversation's next turn. Working-task counts remain separate. Inactive polling defaults off; dedicated native `/usage` sessions handle initial/manual reads, optional inactive refresh and exact reset confirmation. Pool itself sends no vendor quota request.

## Isolation

Each account has a stable app-owned config directory. Only official login/status/session processes access that account's credentials. Runtime IPC is private. Terminal output stays in memory. Existing account directories, Keychain items and Desktop profiles are not scanned or imported by Pool. The exported Desktop profile contains the local gateway access key and is mode 0600.

First-party cloud history and third-party Desktop history are separate. Pool does not migrate cloud history or make a native process checkpoint. A continuation on another run or account is told the conversation through a saved session as above; it does not transplant a running process.
