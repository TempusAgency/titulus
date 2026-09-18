#!/usr/bin/env bash
# wave-chat-title — Stop hook. Generates the chat card in the BACKGROUND via ONE model call.
# Fields with DIFFERENT lifecycles:
#   ROLE  — "Слово. уточнення", from the first ≤10 msgs; FROZEN once settled. wct-goal topic wins.
#   GOAL  — why the chat started, from the chat OPENING; FROZEN once settled (no drift). wct-goal set wins.
#   TASK + PREVIOUS — the live pair, from the recent cluster. OPTIONAL, OFF by default (token cost).
#
# TOKEN MODEL (2026-06-10 rework — see docs/OPTIMIZATION-HANDOFF-2026-06-10.md):
#   The old design re-sent the WHOLE chat (≤40000 chars) on EVERY Stop, uncached, forever, only to
#   keep refreshing TASK/PREVIOUS — ~74 Sonnet calls/day across ~49 sessions ≈ 760K tokens/day.
#   New model: NAME + GOAL are generated ONCE from a SMALL early slice, then FROZEN. After that, if
#   TASK/PREVIOUS are off (the default), there is NOTHING left to generate → the worker is NEVER
#   spawned again for that session. A settled session costs ZERO background tokens.
# Never blocks the UI: spawns a detached worker.
set -uo pipefail

if [ -n "${CLAUDE_TITLE_GEN:-}" ]; then exit 0; fi
WCT_CONFIG="${WCT_CONFIG:-$HOME/.claude/wave-chat-title/config.sh}"
[ -f "$WCT_CONFIG" ] && . "$WCT_CONFIG"
[ -n "${WCT_DISABLE:-}" ] && exit 0

# --- token-cost flags (see config.example.sh; all overridable in config.sh) -----------------
# TASK / PREVIOUS are the live, ALWAYS-refreshing pair — every refresh is a background model call.
# OFF by default: once NAME+GOAL freeze, a settled session makes ZERO further calls.
WCT_TASK_FIELD="${WCT_TASK_FIELD:-0}"          # 1 → keep "▸ Задача" live (costs tokens each refresh)
WCT_PREVIOUS_FIELD="${WCT_PREVIOUS_FIELD:-0}"  # 1 → keep "◃ Попередня" live (needs TASK on too)
# normalize to 0/1
case "$WCT_TASK_FIELD" in 1|true|on|yes) WCT_TASK_FIELD=1;; *) WCT_TASK_FIELD=0;; esac
case "$WCT_PREVIOUS_FIELD" in 1|true|on|yes) WCT_PREVIOUS_FIELD=1;; *) WCT_PREVIOUS_FIELD=0;; esac
[ "$WCT_TASK_FIELD" = 0 ] && WCT_PREVIOUS_FIELD=0   # PREVIOUS is meaningless without TASK
live_fields=0; { [ "$WCT_TASK_FIELD" = 1 ] || [ "$WCT_PREVIOUS_FIELD" = 1 ]; } && live_fields=1

INPUT="$(cat)"
session_id="$(printf '%s' "$INPUT" | jq -r '.session_id // empty')"
transcript="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')"
[ -z "$session_id" ] && exit 0
{ [ -z "$transcript" ] || [ ! -f "$transcript" ]; } && exit 0

cache_dir="${TMPDIR:-/tmp}/wave-chat-title"; mkdir -p "$cache_dir"
rm -f "$cache_dir/$session_id.working" 2>/dev/null   # Stop → clear the "working" marker (statusline animation)
ai_file="$cache_dir/$session_id.ai"          # 3 lines: goal / task / prev
name_file="$cache_dir/$session_id.name"      # auto ROLE (provisional until frozen)
namelock="$cache_dir/$session_id.namelock"   # exists once the auto ROLE is frozen
goallock="$cache_dir/$session_id.goallock"   # exists once the auto GOAL is frozen
lock_dir="$cache_dir/$session_id.gen"        # atomic mutex
seen_file="$cache_dir/$session_id.seen"
started_file="$cache_dir/$session_id.started"
user_name="$HOME/.claude/wave-chat-title/$session_id.topic"   # user-set ROLE → permanent
user_goal="$HOME/.claude/wave-chat-title/$session_id.goal"    # user-set GOAL → permanent

now="$(date +%s)"
mtime(){ stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

# Early debounce (cost guard — this Stop hook fires per turn × ~40 live sessions). In a SETTLED
# session (name frozen or user-named) skip the whole-transcript re-scan + worker spawn if the card
# was refreshed very recently. The 600s LLM throttle below still governs regeneration, so this only
# removes the per-Stop parsing churn during rapid turns — it never delays a real regen beyond the
# throttle. Disabled while the name is still forming (that phase wants frequent refreshes).
if { [ -s "$user_name" ] || [ -f "$namelock" ]; } && { [ -s "$user_goal" ] || [ -f "$goallock" ]; } && [ -s "$ai_file" ]; then
  [ "$(( now - $(mtime "$ai_file") ))" -lt "${WCT_MIN_STOP_GAP:-30}" ] && exit 0
fi

# record session start once (anchor for the 5-min name window)
[ -f "$started_file" ] || printf '%s' "$now" > "$started_file"
started="$(cat "$started_file" 2>/dev/null || echo "$now")"; case "$started" in ''|*[!0-9]*) started="$now";; esac
elapsed=$(( now - started ))

# count user messages (the 10-message window)
ucount="$(jq -rc 'select(.type=="user" and (.message.content|type=="string")) | 1' "$transcript" 2>/dev/null | wc -l | tr -d ' ')"

# Restart-primer handling (SPEC § СУМІЖНЕ): the Holocron restart primer is EXCLUDED from every slice
# in `umsgs` (below) by signature, so the goal/task/role never derive from it. A primer-only session
# therefore yields empty slices → the "nothing to generate" guard exits before any model call. No
# separate gate / marker needed; correctness comes from the source filter, not from a coarse skip.

# --- ROLE + GOAL freeze decision (both settle together at the freeze point) -----------------
# WCT_GOAL_REFRESH: once (default — generate GOAL once, then freeze; cheapest) | periodic (re-derive
# GOAL every WCT_GOAL_REFRESH_SECONDS, costs tokens) | off (never generate GOAL — first card line
# falls back to NAME / session_name).
WCT_GOAL_REFRESH="${WCT_GOAL_REFRESH:-once}"
regen_name=1; regen_goal=1; freeze_now=0
{ [ -s "$user_name" ] || [ -f "$namelock" ]; } && regen_name=0   # role: user-set or already frozen
{ [ -s "$user_goal" ] || [ -f "$goallock" ]; } && regen_goal=0   # goal: user-set or already frozen
case "$WCT_GOAL_REFRESH" in
  off)      regen_goal=0 ;;                                        # never derive GOAL
  periodic) # re-derive GOAL on a long interval even after it first settled
            if [ ! -s "$user_goal" ] && [ -s "$ai_file" ]; then
              [ "$(( now - $(mtime "$ai_file") ))" -ge "${WCT_GOAL_REFRESH_SECONDS:-3600}" ] && regen_goal=1
            fi ;;
esac
# THIS run is the settling run if anything is still unfrozen AND there is enough context
if { [ "$regen_name" = 1 ] || [ "$regen_goal" = 1 ]; } \
   && { [ "${ucount:-0}" -ge 10 ] || [ "$elapsed" -ge "${WCT_NAME_FREEZE_SECONDS:-300}" ]; }; then
  freeze_now=1
fi

# --- NOTHING-TO-GENERATE gate (the core token saving) ----------------------------------------
# A background model call is only worth spawning if SOMETHING still needs generating:
#   • NAME is still forming (regen_name=1), OR
#   • GOAL is still forming / due for refresh (regen_goal=1), OR
#   • a live field (TASK/PREVIOUS) is enabled.
# Once NAME+GOAL are frozen and TASK/PREVIOUS are off (the default), a settled session spawns NOTHING
# on every subsequent Stop — this is what collapses ~74 calls/day down to a one-time freeze burst.
if [ "$regen_name" = 0 ] && [ "$regen_goal" = 0 ] && [ "$live_fields" = 0 ]; then
  exit 0
fi

# change-gate: skip if no new content AND both role & goal are already settled (only task/prev
# would change, and those only change with new content)
lines="$(wc -l < "$transcript" 2>/dev/null | tr -d ' ')"
if [ -s "$ai_file" ] && [ -f "$seen_file" ] && [ "$regen_name" = 0 ] && [ "$regen_goal" = 0 ]; then
  seen="$(cat "$seen_file" 2>/dev/null || echo 0)"
  [ "${lines:-0}" -le "${seen:-0}" ] && exit 0
fi

# throttle on last success; refresh faster while role or goal is still forming
thr="${WCT_THROTTLE_SECONDS:-600}"
{ [ "$regen_name" = 1 ] || [ "$regen_goal" = 1 ]; } && thr="${WCT_NAME_THROTTLE_SECONDS:-120}"
if [ -s "$ai_file" ]; then
  [ "$((now - $(mtime "$ai_file")))" -lt "$thr" ] && exit 0
fi

DIR="$(cd "$(dirname "$0")" && pwd)"
[ -x "$DIR/topic-gen-worker.sh" ] || exit 0
if ! mkdir "$lock_dir" 2>/dev/null; then
  [ "$((now - $(mtime "$lock_dir")))" -lt 300 ] && exit 0
  rmdir "$lock_dir" 2>/dev/null; mkdir "$lock_dir" 2>/dev/null || exit 0
fi

# --- conversation slices (UNTRUSTED → sanitized: collapse '=' runs, neutralize labels) ------
sanitize(){ perl -0777 -pe 's{<system-reminder>.*?</system-reminder>}{}gs; s{<command-[^>]*>.*?</command-[^>]*>}{}gs; s{<[^>]+>}{}g' 2>/dev/null \
  | perl -CSA -Mutf8 -pe 's/={2,}/=/g; s/(НАЗВА|ЦІЛЬ|ЗАДАЧА|ПОПЕРЕДНЯ)\s*:/\1./gi;' 2>/dev/null \
  | tr '\n\t' '  ' | sed -E 's/  +/ /g'; }
# EXCLUDE the Holocron restart-primer message from every slice (goal/task/role) — it is restart.py's
# re-entry handoff ("Read .../restart/primer_…md … handoff from the previous session … RE-ENTER the
# team"), and summarising IT gives the bogus goal "Відновити сесію після рестарту". These phrases
# never appear in a real user message → accurate, zero false positives. Real work derives the card.
umsgs(){ jq -rc 'select(.type=="user" and (.message.content|type=="string") and ((.message.content) | test("restart/primer_|handoff from the previous session|RE-ENTER the team";"i") | not)) | .message.content' "$transcript" 2>/dev/null; }

# Input caps (chars). Smaller = fewer tokens. GOAL is generated ONCE then frozen, so its cap mostly
# governs a single call per session — but it is still the largest single input, so we cap it tight.
# GOAL is anchored to the chat OPENING (head -c): intent lives in the first messages, not the latest
# (audit-20). The old code used the WHOLE chat at tail -c 40000.
goal_cap="${WCT_GOAL_INPUT_CHARS:-12000}"
name_cap="${WCT_NAME_INPUT_CHARS:-4000}"
recent_cap="${WCT_RECENT_INPUT_CHARS:-6000}"
case "$goal_cap"   in ''|*[!0-9]*) goal_cap=12000;; esac
case "$name_cap"   in ''|*[!0-9]*) name_cap=4000;;  esac
case "$recent_cap" in ''|*[!0-9]*) recent_cap=6000;; esac

all_file="$cache_dir/$session_id.in.all"; recent_file="$cache_dir/$session_id.in.recent"; early_file="$cache_dir/$session_id.in.early"
# recent cluster → TASK / PREVIOUS — only when a live field is enabled (off by default = no slice, no input)
[ "$live_fields" = 1 ] && umsgs | tail -12 | sanitize | tail -c "$recent_cap" > "$recent_file" || : > "$recent_file"
# chat opening → GOAL (only while goal unfrozen / due); head-anchored so intent isn't truncated away
[ "$regen_goal" = 1 ] && umsgs | sanitize | head -c "$goal_cap" > "$all_file"   || : > "$all_file"
# early → ROLE (only while role unfrozen)
[ "$regen_name" = 1 ] && umsgs | head -10 | sanitize | tail -c "$name_cap" > "$early_file" || : > "$early_file"

# Need real input for SOMETHING we asked to generate; otherwise nothing to do. (recent_file may be
# intentionally empty when live fields are off — that's fine; the freeze run still produces NAME/GOAL.)
if [ ! -s "$recent_file" ] && [ ! -s "$all_file" ] && [ ! -s "$early_file" ]; then
  rm -f "$all_file" "$recent_file" "$early_file"; rmdir "$lock_dir" 2>/dev/null; exit 0
fi

nonce="WCT${$}${RANDOM}${RANDOM}"

# detached worker. Args: ai name namelock goallock regen_name regen_goal freeze_now nonce lines all recent early task_field prev_field
perl -e '
  fork and exit; eval { require POSIX; POSIX::setsid() }; fork and exit;   # setsid in eval: MSYS/Git Bash perl may lack it — stay non-fatal (double-fork still detaches)
  open STDIN,"</dev/null"; open STDOUT,">/dev/null"; open STDERR,">/dev/null";
  exec @ARGV or die $!;
' -- "$DIR/topic-gen-worker.sh" "$ai_file" "$name_file" "$namelock" "$goallock" "$regen_name" "$regen_goal" "$freeze_now" "$nonce" "$lines" "$all_file" "$recent_file" "$early_file" "$WCT_TASK_FIELD" "$WCT_PREVIOUS_FIELD"
exit 0
