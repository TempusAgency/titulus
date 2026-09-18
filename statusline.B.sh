#!/usr/bin/env bash
# wave-chat-title — Claude Code status line card (5 rows), word-wrapped for narrow blocks:
#   ● Тема: <topic>            blue+bold     ◎ Ціль: <goal>   yellow
#   ▸ Задача: <current>        default        ◃ Попередня: <prev>  dim
#   [⎇ branch · контекст N% · ✻ id]  meta bar, slate fill, wraps at " · "
# Long values wrap onto continuation rows (hang-indented) instead of truncating, because
# Claude Code does NOT expose the block width (COLUMNS unset, no width in JSON). Wrap width
# is a fixed default (~30) overridable via $TMPDIR/wave-chat-title/.wrapwidth.
# AI lines come from Sonnet in the background (topic-update.sh). No Wave RPC / JWT.
set -uo pipefail
# char-aware (not byte) widths for Cyrillic; fall back to C.UTF-8 if en_US.UTF-8 isn't generated.
if locale -a 2>/dev/null | grep -qiE '^en_US\.utf-?8$'; then export LC_ALL="${LC_ALL:-en_US.UTF-8}"
elif locale -a 2>/dev/null | grep -qiE '^C\.utf-?8$';  then export LC_ALL="${LC_ALL:-C.UTF-8}"
else export LC_ALL="${LC_ALL:-en_US.UTF-8}"; fi

INPUT="$(cat)"
transcript="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')"
session_id="$(printf '%s' "$INPUT" | jq -r '.session_id // "nosess"')"
cwd="$(printf '%s' "$INPUT" | jq -r '.cwd // .workspace.current_dir // empty')"
ctx="$(printf '%s' "$INPUT" | jq -r '.context_window.used_percentage // empty | if type=="number" then (floor|tostring) else "" end')"
model_disp="$(printf '%s' "$INPUT" | jq -r '.model.display_name // .model.id // empty' | sed -E 's/ *\([^)]*[Cc]ontext[^)]*\)//')"
model_id="$(printf '%s' "$INPUT" | jq -r '.model.id // empty')"
effort="$(printf '%s' "$INPUT" | jq -r '.effort.level // empty')"; [ -z "$effort" ] && effort="${CLAUDE_EFFORT:-}"
# 1M-context tag if the model id carries it and the display name doesn't already say so
ctxsize=""; case "$model_id" in *1m*|*1M*) case "$model_disp" in *1M*|*1m*) ;; *) ctxsize=" 1M";; esac;; esac

cache_dir="${TMPDIR:-/tmp}/wave-chat-title"   # ephemeral AI cache (macOS wipes TMPDIR)
user_dir="$HOME/.claude/wave-chat-title"      # PERSISTENT user overrides — survives reboot
mkdir -p "$cache_dir" "$user_dir"
ai_file="$cache_dir/$session_id.ai"           # 3 lines: goal / task / prev
name_file="$cache_dir/$session_id.name"       # auto chat name (provisional or frozen)
heur_file="$cache_dir/$session_id.heur"       # 1 line fallback: first user message
name_user="$user_dir/$session_id.topic"       # user-stated NAME (wins, permanent)
goal_user="$user_dir/$session_id.goal"        # user-stated goal  (wins over AI)

name=""; goal=""; task=""; prev=""
# goal / task / prev from the 3-line card
if [ -s "$ai_file" ]; then
  ai="$(cat "$ai_file")"   # ONE read → no torn read across the worker's atomic mv
  goal="$(sed -n '1p' <<< "$ai")"; task="$(sed -n '2p' <<< "$ai")"; prev="$(sed -n '3p' <<< "$ai")"
fi
# NAME: user-set wins (permanent) → auto name → heuristic fallback (first user message)
if [ -s "$name_user" ]; then name="$(cat "$name_user")"
elif [ -s "$name_file" ]; then name="$(cat "$name_file")"
elif [ -s "$heur_file" ]; then name="$(cat "$heur_file")"
else
  if [ -n "$transcript" ] && [ -f "$transcript" ]; then
    raw="$(head -200 "$transcript" 2>/dev/null \
      | jq -sr '[ .[] | select(.type=="user" and (.message.content|type=="string")) ][0].message.content // empty' 2>/dev/null)"
    name="$(printf '%s' "$raw" \
      | perl -0777 -pe 's{<system-reminder>.*?</system-reminder>}{}gs; s{<command-[^>]*>.*?</command-[^>]*>}{}gs; s{<[^>]+>}{}g' 2>/dev/null \
      | tr '\n\t' '  ' | sed -E 's/  +/ /g; s/^ +//; s/ +$//')"
  fi
  [ -z "$name" ] && name="(нова сесія)"
  printf '%s' "$name" > "$heur_file"
fi
# goal user-override still wins
[ -s "$goal_user" ] && goal="$(cat "$goal_user")"

# strip any control/ANSI bytes before they reach the terminal
stripc(){ printf '%s' "$1" | perl -CSA -Mutf8 -pe 's/[\x00-\x1f\x7f]//g' 2>/dev/null; }
name="$(stripc "$name")"; goal="$(stripc "$goal")"; task="$(stripc "$task")"; prev="$(stripc "$prev")"

# name: capitalize first letter (UTF-8)
name="$(printf '%s' "$name" | perl -CS -Mutf8 -pe 's/^(\s*)(\p{L})/$1\U$2/' 2>/dev/null)"

# sanity cap (wrapping handles normal lengths; this just stops a runaway paragraph)
cap=160
[ "${#name}" -gt "$cap" ] && name="${name:0:cap}…"
[ "${#goal}"  -gt "$cap" ] && goal="${goal:0:cap}…"
[ "${#task}"  -gt "$cap" ] && task="${task:0:cap}…"
[ "${#prev}"  -gt "$cap" ] && prev="${prev:0:cap}…"

# wrap width (fixed default, since the block width is unknown; overridable via .wrapwidth)
W="$(cat "$cache_dir/.wrapwidth" 2>/dev/null || echo 38)"
case "$W" in ""|*[!0-9]*) W=38;; esac

BLUE=$'\033[38;2;122;162;247m'; YELLOW=$'\033[38;2;224;175;104m'
CLAUDE=$'\033[38;2;217;119;87m'; BG=$'\033[48;2;49;50;68m'; FGDEF=$'\033[39m'
BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'; UNBOLD=$'\033[22m'
# variant B — high contrast: reverse-video colored label chips + a divider rule.
GREEN=$'\033[38;2;158;206;106m'; MAGENTA=$'\033[38;2;187;154;247m'; REV=$'\033[7m'
chip(){ printf '%b' "${1}${REV}${BOLD} ${2} ${RESET}"; }   # $1=color $2=label → solid colored box
rule(){ printf '%b%s%b' "$DIM" "$(perl -CSA -Mutf8 -e 'print "─" x $ARGV[0]' "${1:-$W}")" "$RESET"; }

# wrapf <width> <initial-indent> <subsequent-indent> <text> → char-wrapped plain text
wrapf() { W="$1" I="$2" S="$3" perl -CSA -Mutf8 -MText::Wrap -e '
  $Text::Wrap::columns=$ENV{W}+1; $Text::Wrap::huge="wrap"; $Text::Wrap::unexpand=0;
  print Text::Wrap::wrap($ENV{I},$ENV{S},$ARGV[0]);' -- "$4"; }

# all labels flush to the left edge (column 0); continuation rows hang-indented by 3
printf '%b %b%s%b'   "$(chip "$BLUE" "Назва")"    "$BOLD" "$(wrapf "$W" "" "        " "$name")" "$RESET"
[ -n "$goal" ] && printf '\n%b %b%s%b' "$(chip "$YELLOW" "Ціль")"   "$BOLD" "$(wrapf "$W" "" "       " "$goal")" "$RESET"
[ -n "$task" ] && printf '\n%b %b%s%b' "$(chip "$GREEN" "Задача")"  "$BOLD" "$(wrapf "$W" "" "         " "$task")" "$RESET"
[ -n "$prev" ] && printf '\n%b %b%s%b' "$(chip "$MAGENTA" "Попер")" "$DIM"  "$(wrapf "$W" "" "        " "$prev")" "$RESET"
printf '\n%s' "$(rule "$W")"

# meta bar at column 0 too: segments joined by " · ", wrapped at separators; slate fill persists
branch=""
[ -n "$cwd" ] && branch="$(git -C "$cwd" branch --show-current 2>/dev/null)"
agents_n=0; sess_sub="${transcript%.jsonl}/subagents"
if [ -d "$sess_sub" ]; then
  nowt=$(date +%s)
  for af in "$sess_sub"/agent-*.jsonl; do
    [ -f "$af" ] || continue
    amt=$(stat -f %m "$af" 2>/dev/null || stat -c %Y "$af" 2>/dev/null || echo 0)
    [ "$(( nowt - amt ))" -le "${WCT_AGENTS_WINDOW:-20}" ] && agents_n=$((agents_n+1))
  done
fi
printf '%b' "\n${BG} "
cur=0; first=1
seg() { # $1=colored text  $2=plain text (for width)
  local plen=${#2}
  if [ "$first" -eq 0 ]; then
    if [ $((cur + 3 + plen)) -gt "$W" ]; then printf '%b' " \n${BG} "; cur=0
    else printf '%b' " │ "; cur=$((cur + 3)); fi
  fi
  printf '%b' "$1"; cur=$((cur + plen)); first=0
}
newrow() { printf '%b' " \n${BG} "; cur=0; first=1; }

# Row 1 (top): SESSION ID · CONTEXT — icons are HTML/Unicode symbols, never emoji
# "working" = explicit marker OR the transcript was just written (no hook needed, works any session)
working=0
[ -f "$cache_dir/$session_id.working" ] && working=1
if [ "$working" = 0 ] && [ -n "$transcript" ] && [ -f "$transcript" ]; then
  tmt="$(stat -f %m "$transcript" 2>/dev/null || stat -c %Y "$transcript" 2>/dev/null || echo 0)"
  [ "$(( $(date +%s) - tmt ))" -le 5 ] && working=1
fi
sicon="✻"
if [ "$working" = 1 ]; then
  sframes=(✦ ✶ ✷ ✸ ✹ ✺); st=$(perl -MTime::HiRes=time -e 'print int(time()*5)' 2>/dev/null || date +%s)
  sicon="${sframes[$(( st % ${#sframes[@]} ))]}"
fi
if [ "$session_id" != "nosess" ] && [ -n "$session_id" ]; then
  seg "${CLAUDE}${BOLD}${sicon} ${session_id:0:8}${UNBOLD}${FGDEF}" "${sicon} ${session_id:0:8}"
fi
[ -n "$ctx" ] && seg "◷ CTX ${ctx}%" "◷ CTX ${ctx}%"

# Row 2: MODEL · EFFORT
newrow
[ -n "$model_disp" ] && seg "◆ ${model_disp}${ctxsize}" "◆ ${model_disp}${ctxsize}"
[ -n "$effort" ]     && seg "↯ ${effort}" "↯ ${effort}"

# Agents row (only while subagents/workflows run) — animated braille spinner, ABOVE the folder
if [ "${agents_n:-0}" -gt 0 ]; then
  newrow
  aframes=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏); at=$(perl -MTime::HiRes=time -e 'print int(time()*8)' 2>/dev/null || date +%s)
  aspin="${aframes[$(( at % ${#aframes[@]} ))]}"
  seg "${GREEN}${BOLD}${aspin} агенти ×${agents_n}${UNBOLD}${FGDEF}" "${aspin} агенти ×${agents_n}"
fi

# One block PER working directory (cwd + every /add-dir'd dir from workspace.added_dirs).
dirs=("$cwd")
while IFS= read -r ad; do [ -n "$ad" ] && dirs+=("$ad"); done < <(printf '%s' "$INPUT" | jq -r '.workspace.added_dirs[]? // empty' 2>/dev/null)
for dd in "${dirs[@]}"; do
  [ -z "$dd" ] && continue
  newrow
  dn="$(basename "$dd")"
  dlink="$(printf '\033]8;;file://%s\033\\\342\214\202 %s\033]8;;\033\\' "$dd" "$dn")"
  seg "${BLUE}${dlink}${FGDEF}" "⌂ ${dn}"
  dbr="$(git -C "$dd" branch --show-current 2>/dev/null)"
  [ -n "$dbr" ] && seg "${BLUE}⎇ ${dbr}${FGDEF}" "⎇ ${dbr}"
  printf '%b' " ${RESET}"
  printf '\n%b%s%b' "$DIM" "$(wrapf "$W" "" "   " "↳ $dd")" "$RESET"
done
exit 0
