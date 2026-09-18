---
description: Set this chat's Topic or Goal shown in the wave-chat-title status card
argument-hint: "[topic|goal] <text>"
allowed-tools: Bash
---
The user wants to pin the wave-chat-title status card for the CURRENT session.

Parse `$ARGUMENTS`:
- If it starts with the word `topic` or `goal`, that selects the field; the rest is the value.
- Otherwise treat the whole thing as the **topic**.

Persist it with the bundled `wct-goal.sh` helper. Its **absolute path was given to you at session start**, inside the `🎯 ХРАНИТЕЛЬ ТЕМИ Й ЦІЛІ` block (the two lines under "тему:" / "ціль:") — use exactly that path. The helper keys off `CLAUDE_CODE_SESSION_ID`, which your Bash tool already has in its environment.

- topic → `<wct-goal.sh path> topic "<value>"`
- goal  → `<wct-goal.sh path> set   "<value>"`

If for any reason that path isn't in context, find `wct-goal.sh` under the installed `wave-chat-title` plugin directory.

A user-set topic/goal wins over the auto-summary and survives reboots. After running it, confirm in one short line what you pinned. Do nothing else.
