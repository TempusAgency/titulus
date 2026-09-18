---
description: Set this chat's Role shown in the wave-chat-title status card
argument-hint: "[topic] <text>"
allowed-tools: Bash
---
The user wants to pin the wave-chat-title status card for the CURRENT session.

Parse `$ARGUMENTS`:
- If it starts with the word `topic`, that word selects the field; the rest is the value.
- Otherwise treat the whole thing as the **topic**.

The `topic` field is the session **ROLE** — the first line of the card, in the format
«Слово. уточнення» (one word, a period, a short note).

Persist it with the bundled `wct-goal.sh` helper. Its **absolute path was given to you at session start**, inside the `🎯 ХРАНИТЕЛЬ РОЛІ` block (the line under "роль:") — use exactly that path. The helper keys off `CLAUDE_CODE_SESSION_ID`, which your Bash tool already has in its environment.

- topic → `<wct-goal.sh path> topic "<value>"`

If for any reason that path isn't in context, find `wct-goal.sh` under the installed `wave-chat-title` plugin directory.

A user-set role wins over the auto-summary and survives reboots. After running it, confirm in one short line what you pinned. Do nothing else.
