#!/usr/bin/env bash
# wave-chat-title — get/set the user-defined chat TOPIC/GOAL for the current session.
# Keyed by CLAUDE_CODE_SESSION_ID — the SAME id statusline.sh reads, so whatever is saved here
# the card shows. A user-set value wins over the auto-summary and survives reboots.
#   wct-goal.sh topic "<тема>"   → save / update the topic
#   wct-goal.sh set   "<ціль>"   → save / update the goal
#   wct-goal.sh get              → print current topic + goal
#   wct-goal.sh clear            → remove both
set -uo pipefail

sid="${CLAUDE_CODE_SESSION_ID:-}"
if [ -z "$sid" ]; then echo "wct-goal: no CLAUDE_CODE_SESSION_ID in env" >&2; exit 1; fi

dir="$HOME/.claude/wave-chat-title"; mkdir -p "$dir"   # PERSISTENT (TMPDIR gets wiped by macOS)
goal_f="$dir/$sid.goal"
topic_f="$dir/$sid.topic"

# atomic write (tmp + mv) so statusline.sh never reads a half-written value.
save(){ printf '%s' "$2" > "$1.tmp.$$" && mv "$1.tmp.$$" "$1"; }

case "${1:-}" in
  set)   shift; save "$goal_f"  "$*"; echo "✓ ціль збережено: $*" ;;
  topic) shift; save "$topic_f" "$*"; echo "✓ роль збережено: $*" ;;   # topic file = ROLE (1st card line)
  get)   echo "роль: $( [ -s "$topic_f" ] && cat "$topic_f" || echo '(авто)' )";
         echo "ціль: $( [ -s "$goal_f" ]  && cat "$goal_f"  || echo '(авто)' )" ;;
  clear) rm -f "$goal_f" "$topic_f"; echo "✓ роль і ціль очищено (повернеться авто)" ;;
  *)     echo "usage: wct-goal.sh {topic <Слово. уточнення>|set <ціль>|get|clear}" >&2; exit 2 ;;
esac
