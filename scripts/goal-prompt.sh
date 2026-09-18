#!/usr/bin/env bash
# wave-chat-title — SessionStart hook. Injects behavior so Claude (1) on a FRESH start asks the
# user for the branch ROLE, (2) surfaces a user-set role as authoritative. stdout = session context.
set -uo pipefail

# don't run inside the background topic-summary subprocess
if [ -n "${CLAUDE_TITLE_GEN:-}" ]; then exit 0; fi

# personal overlay + master kill switch (consistent with topic-update.sh)
WCT_CONFIG="${WCT_CONFIG:-$HOME/.claude/wave-chat-title/config.sh}"
[ -f "$WCT_CONFIG" ] && . "$WCT_CONFIG"
[ -n "${WCT_DISABLE:-}" ] && exit 0

# SessionStart delivers JSON on stdin: {session_id, source, ...}. `source` ∈ startup|resume|
# compact|clear. We only nudge "ask for the role" on a genuine startup, not on resume/compact.
INPUT="$(cat 2>/dev/null || true)"
source_kind="$(printf '%s' "$INPUT" | jq -r '.source // empty' 2>/dev/null)"
sid="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
[ -z "$sid" ] && sid="${CLAUDE_CODE_SESSION_ID:-}"
[ -z "$sid" ] && exit 0

dir="$HOME/.claude/wave-chat-title"   # PERSISTENT — survives reboot / TMPDIR cleanup
# portable path to wct-goal.sh: this script's own dir (works under ${CLAUDE_PLUGIN_ROOT} or anywhere)
WCT="$(cd "$(dirname "$0")" && pwd)/wct-goal.sh"
t=""
[ -s "$dir/$sid.topic" ] && t="$(cat "$dir/$sid.topic")"

{
echo "🎯 ХРАНИТЕЛЬ РОЛІ — постійна поведінка для цієї гілки термінала (Claude-сесії):"
if [ -n "$t" ]; then
  echo "• Роль (задана користувачем): «$t»."
elif [ -z "$source_kind" ] || [ "$source_kind" = "startup" ]; then
  echo "• ПЕРШЕ у новій гілці: одним коротким питанням спитай користувача про РОЛЬ цієї сесії:"
  echo "    – РОЛЬ = хто ця сесія / для чого (формат «Слово. уточнення»: перше ОДНЕ слово — Rework, Дослідник, Фікс, Рефактор; далі крапка й коротке уточнення)."
fi
cat <<EOF
• Коли користувач проговорює роль СЛОВАМИ — це авторитетне значення, збережи його ОДРАЗУ (воно перекриває авто-аналіз і йде в картку):
    роль: "$WCT" topic "<Слово. уточнення>"
  Роль ОБОВ'ЯЗКОВО у форматі «Слово. уточнення» (одне слово, крапка, коротко).
• Якщо користувач одразу почав працювати, не наполягай: роль і задачі визначить авто-аналіз (теж у форматі «Слово. уточнення»).
EOF
}
