#!/usr/bin/env bash
# wave-chat-title — UserPromptSubmit hook. Sets a per-session "working" marker so the statusline
# can animate the session icon WHILE a turn is in progress. The Stop hook (topic-update.sh)
# removes it. Marker lives in the TMPDIR cache next to the card files.
set -uo pipefail
[ -n "${CLAUDE_TITLE_GEN:-}" ] && exit 0
sid="$(cat 2>/dev/null | jq -r '.session_id // empty' 2>/dev/null)"
[ -z "$sid" ] && exit 0
d="${TMPDIR:-/tmp}/wave-chat-title"; mkdir -p "$d"
: > "$d/$sid.working"
exit 0
