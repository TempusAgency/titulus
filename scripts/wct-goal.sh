#!/usr/bin/env bash
# wave-chat-title — get/set the user-defined chat ROLE for the current session.
# Keyed by CLAUDE_CODE_SESSION_ID — the SAME id statusline.sh reads, so whatever is saved here
# the card shows. A user-set value wins over the auto-summary and survives reboots.
#   wct-goal.sh topic "<Слово. уточнення>"   → save / update the role
#   wct-goal.sh get                          → print the current role
#   wct-goal.sh clear                        → remove it (the role falls back to auto)
set -uo pipefail

sid="${CLAUDE_CODE_SESSION_ID:-}"
if [ -z "$sid" ]; then echo "wct-goal: no CLAUDE_CODE_SESSION_ID in env" >&2; exit 1; fi

dir="$HOME/.claude/wave-chat-title"; mkdir -p "$dir"   # PERSISTENT (TMPDIR gets wiped by macOS)
topic_f="$dir/$sid.topic"

# atomic write (tmp + mv) so statusline.sh never reads a half-written value.
save(){ printf '%s' "$2" > "$1.tmp.$$" && mv "$1.tmp.$$" "$1"; }

case "${1:-}" in
  topic) shift; save "$topic_f" "$*"; echo "✓ роль збережено: $*" ;;   # topic file = ROLE (1st card line)
  get)   echo "роль: $( [ -s "$topic_f" ] && cat "$topic_f" || echo '(авто)' )" ;;
  clear) rm -f "$topic_f"; echo "✓ роль очищено (повернеться авто)" ;;
  *)     echo "usage: wct-goal.sh {topic <Слово. уточнення>|get|clear}" >&2; exit 2 ;;
esac
