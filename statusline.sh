#!/usr/bin/env bash
# wave-chat-title — Claude Code status line card: a FLAT, full-width layout (no box frame, no
# background fill) that flows straight from the input line. Top→bottom:
#   <glyph> <Name>                          session glyph (orange, animated while working) + name (blue bold)
#   ──────────────────                      zone divider (muted)
#   ▸ Задача / ◃ Попередня                  wrapped, hang-indented
#   ──────────────────
#   <glyph> <id> · CTX N% · 5h · ↺ eta · 7d   meta chips, wrap at " · "
#   ◆ model · ↯ effort · ⇄ PR
#   ──────────────────
#   ⌂ dir · ⎇ branch  /  ↳ path             per working directory
# No left/right edges → nothing ever truncates; adapts to any width. Wrap width from $COLUMNS
# (CC ≥2.1.153) with $TMPDIR/wave-chat-title/.wrapwidth → 38 fallback. AI lines come from Sonnet
# in the background (topic-update.sh).
#
# COST DISCIPLINE (rework 2026-06-07 — after refreshInterval=1 × ~40 sessions pinned the CPU):
# this script runs on a GLOBAL config, so every fork is multiplied by the count of live sessions.
# It is kept deliberately cheap: ONE jq pass for all JSON fields, ONE perl pass for all char-aware
# work (wrapping + capitalisation + colouring of the name/divider/field blocks), git cached ~5s on
# disk, a single date(NOW) reused everywhere, control-char stripping / basename / .ai read done with
# bash builtins, per-session id colour and the locale decision cached. Common idle render ≈ 6-9
# subprocesses (depending on the AI card; was ~80). Before adding any per-render command, remember
# it costs ×(live sessions).
set -uo pipefail

cache_dir="${TMPDIR:-/tmp}/wave-chat-title"   # ephemeral AI cache (macOS wipes TMPDIR)
user_dir="$HOME/.claude/wave-chat-title"      # PERSISTENT user overrides — survives reboot
[ -d "$cache_dir" ] || mkdir -p "$cache_dir"
[ -d "$user_dir" ]  || mkdir -p "$user_dir"

# char-aware (not byte) widths for Cyrillic; resolve once and CACHE the decision (locale -a lists
# every installed locale — too heavy to run on every render ×N sessions).
lc_file="$cache_dir/.lcall"
if [ -s "$lc_file" ]; then export LC_ALL="${LC_ALL:-$(<"$lc_file")}"
else
  if   locale -a 2>/dev/null | grep -qiE '^en_US\.utf-?8$'; then LC_ALL="${LC_ALL:-en_US.UTF-8}"
  elif locale -a 2>/dev/null | grep -qiE '^C\.utf-?8$';     then LC_ALL="${LC_ALL:-C.UTF-8}"
  else LC_ALL="${LC_ALL:-en_US.UTF-8}"; fi
  export LC_ALL; printf '%s' "$LC_ALL" > "$lc_file" 2>/dev/null || true
fi

NOW=$(date +%s)   # single wall-clock read, reused for the spinner, reset countdown, git cache, "working"

INPUT="$(cat)"
# ONE jq pass for every field (was ~13 separate jq calls). Each scalar is emitted on its OWN line,
# then the working dirs one-per-line after them. Newline-per-field (not tab-separated) is used on
# purpose: `read` with a whitespace IFS coalesces empty fields and shifts the columns, whereas one
# `read` per line preserves empty fields exactly. Embedded newlines in values are neutralised
# (clean) so each value stays a single line. Model display has its "(… context)" suffix stripped.
session_id=""; transcript=""; cwd=""; session_name=""; ctx=""; model_disp=""; model_id=""
effort=""; rl5=""; rl5_reset=""; rl7=""; rl7_reset=""; pr_num=""; pr_state=""; added_dirs=()
{
  read -r session_id; read -r transcript; read -r cwd; read -r session_name
  read -r ctx; read -r model_disp; read -r model_id; read -r effort
  read -r rl5; read -r rl5_reset; read -r rl7; read -r rl7_reset; read -r pr_num; read -r pr_state
  while IFS= read -r _ad; do [ -n "$_ad" ] && added_dirs+=("$_ad"); done
} < <(printf '%s' "$INPUT" | jq -r '
  def clean: (. // "") | tostring | gsub("[\\n\\r]";" ");
  def pct:   (if type=="number" then (floor|tostring) else "" end);
  (.session_id // "nosess" | clean),
  (.transcript_path | clean),
  (.cwd // .workspace.current_dir | clean),
  (.session_name | clean),
  (.context_window.used_percentage // null | pct),
  ((.model.display_name // .model.id // "") | gsub(" *\\([^)]*[Cc]ontext[^)]*\\)";"") | clean),
  (.model.id | clean),
  (.effort.level | clean),
  (.rate_limits.five_hour.used_percentage  // null | pct),
  (.rate_limits.five_hour.resets_at        // null | pct),
  (.rate_limits.seven_day.used_percentage  // null | pct),
  (.rate_limits.seven_day.resets_at        // null | pct),
  (.pr.number // "" | clean),
  (.pr.review_state | clean),
  (.workspace.added_dirs // [] | .[] | clean)' 2>/dev/null)
[ -z "${session_id:-}" ] && session_id="nosess"
[ -z "${effort:-}" ] && effort="${CLAUDE_EFFORT:-}"
# 1M-context tag if the model id carries it and the display name doesn't already say so
ctxsize=""; case "$model_id" in *1m*|*1M*) case "$model_disp" in *1M*|*1m*) ;; *) ctxsize=" 1M";; esac;; esac

ai_file="$cache_dir/$session_id.ai"           # 3 lines: <reserved empty> / task / prev
name_file="$cache_dir/$session_id.name"       # auto chat name (provisional or frozen)
heur_file="$cache_dir/$session_id.heur"       # 1 line fallback: first user message
name_user="$user_dir/$session_id.topic"       # user-stated NAME (wins, permanent)

name=""; task=""; prev=""
# 3 lines read with builtins (no sed forks). LINE 1 IS A RESERVED, ALWAYS-EMPTY PLACEHOLDER (the
# former goal): the file format is kept 3-line ON PURPOSE so task/prev keep their positions. The
# worker writes the file atomically (mv), so reading it directly here is torn-read-safe.
if [ -s "$ai_file" ]; then
  { IFS= read -r _unused; IFS= read -r task; IFS= read -r prev; } < "$ai_file"
fi

# coord ROLE (SPEC-card-line1-role): ONLY if a coord inbox file for this session exists in cwd, read
# its `role:` field. ZERO forks when the file is absent (the common case); one grep when present.
# Trim + prettify (capitalise an ASCII slug's first letter, ensure a trailing period) — builtins.
coord_role=""
if [ -n "$cwd" ] && [ -f "$cwd/_coord/inbox/$session_id.md" ]; then
  coord_role="$(grep -m1 '^role:' "$cwd/_coord/inbox/$session_id.md" 2>/dev/null)"
  coord_role="${coord_role#role:}"
  coord_role="${coord_role#"${coord_role%%[![:space:]]*}"}"   # ltrim
  coord_role="${coord_role%"${coord_role##*[![:space:]]}"}"   # rtrim
  coord_role="${coord_role#[\"\']}"; coord_role="${coord_role%[\"\']}"   # strip surrounding quotes
  # placeholder roles are NOT a real role: the coord channel pre-creates inboxes with
  # `role: unassigned` before the orchestrator assigns one. Treat these as empty → fall through to
  # session_name / AI auto-role, so the session still gets a real role (not a frozen "Unassigned").
  case "$coord_role" in
    unassigned|Unassigned|UNASSIGNED|none|None|NONE|tbd|TBD|null|"-"|"?"|"—") coord_role="" ;;
  esac
  if [ -n "$coord_role" ]; then
    case "$coord_role" in [a-z]*)   # capitalise first letter of an ASCII slug (orchestrator → Orchestrator)
      _r="${coord_role#?}"; coord_role="$(printf '%s' "${coord_role%"$_r"}" | tr 'a-z' 'A-Z')$_r";; esac
    # NO forced punctuation: the line is "Role › function" (function optional) — the role word stands
    # alone when there's no function; the › + function come from the source string when present.
  fi
fi

# FIRST LINE = ROLE ("Слово. допис"). Precedence: user-set role → coord role → CC session_name →
# background auto-role → first-message heuristic. HARD RULE: the AI auto-role and the heuristic
# NEVER override a KNOWN role (user-set or coord) — that kills the "card describes its own restart /
# shows (нова сесія)" bug.
if   [ -s "$name_user" ]; then name="$(<"$name_user")"
elif [ -n "$coord_role" ]; then name="$coord_role"
elif [ -n "${session_name:-}" ]; then name="$session_name"
elif [ -s "$name_file" ]; then name="$(<"$name_file")"
elif [ -s "$heur_file" ]; then name="$(<"$heur_file")"
else
  # cold path only (no role/name from any source yet): one-time first-user-message heuristic
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

# strip any control/ANSI bytes before they reach the terminal — bash builtin (UTF-8 safe: control
# bytes never occur inside multibyte sequences), replaces 4 perl spawns.
name="${name//[[:cntrl:]]/}"; task="${task//[[:cntrl:]]/}"; prev="${prev//[[:cntrl:]]/}"

# sanity cap (wrapping handles normal lengths; this just stops a runaway paragraph)
cap=160
[ "${#name}" -gt "$cap" ] && name="${name:0:cap}…"
[ "${#task}" -gt "$cap" ] && task="${task:0:cap}…"
[ "${#prev}" -gt "$cap" ] && prev="${prev:0:cap}…"

# wrap width — adaptive, with a fallback chain so it works even where CC can't hand us the width:
#   1) $COLUMNS — the real terminal width CC exports (≥2.1.153). Best, and updates on resize.
#   2) tmux pane width — for tmux-based launchers (e.g. Tempus Launcher) where CC runs captured and
#      does NOT export COLUMNS, so the card would otherwise fall back to a narrow 38. This queries the
#      LIVE pane, so it re-adapts when the pane/block is resized. Only runs when COLUMNS is absent.
#   3) manual .wrapwidth override → 4) 38.
# The flat layout has no right edge, so using the full width is safe (nothing truncates).
if [ -n "${COLUMNS:-}" ] && [ "$COLUMNS" -gt 0 ] 2>/dev/null; then
  W=$(( COLUMNS > 1 ? COLUMNS - 1 : COLUMNS ))   # -1: leave the last cell so CC never clips a "…"
elif [ -n "${TMUX:-}" ] && _pw="$(tmux display-message -p '#{pane_width}' 2>/dev/null)" && [ "${_pw:-0}" -gt 0 ] 2>/dev/null; then
  W=$(( _pw > 1 ? _pw - 1 : _pw ))               # tmux launcher: live pane width, adaptive on resize
elif [ -f "$cache_dir/.wrapwidth" ]; then
  W="$(<"$cache_dir/.wrapwidth")"
else
  W=38
fi
case "$W" in ""|*[!0-9]*) W=38;; esac

# Tempus brand palette (matches tempus-launcher). CLAUDE terracotta = name + session id;
# LIGHT = folders; meta chips stay subtle (default / dim). No per-session hash colour ("no fantasy").
CLAUDE=$'\033[38;2;217;119;87m'; FGDEF=$'\033[39m'
LIGHT=$'\033[38;2;245;246;250m'
BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'; UNBOLD=$'\033[22m'; AGCOL=$'\033[38;2;158;206;106m'
WFCOL=$'\033[38;2;125;207;225m'   # workflow chip — cyan, distinct from the green agents chip

# build the clean working-dir list (cwd + every /add-dir'd dir), empties filtered, used for BOTH
# the text-wrap pass and the render loop so indices line up.
rawdirs=("$cwd")
for ad in ${added_dirs[@]+"${added_dirs[@]}"}; do rawdirs+=("$ad"); done
dirs=()
for d in ${rawdirs[@]+"${rawdirs[@]}"}; do [ -n "$d" ] && dirs+=("$d"); done

# animated session glyph — computed BEFORE the text pass because the name line embeds it.
# "working" = explicit marker (UserPromptSubmit hook) OR the transcript was written in the last 5s.
working=0
[ -f "$cache_dir/$session_id.working" ] && working=1
if [ "$working" = 0 ] && [ -n "$transcript" ] && [ -f "$transcript" ]; then
  tmt="$(stat -f %m "$transcript" 2>/dev/null || stat -c %Y "$transcript" 2>/dev/null || echo 0)"
  [ "$(( NOW - tmt ))" -le 5 ] && working=1
fi
sicon="✻"
if [ "$working" = 1 ]; then
  # step ONE frame per second off NOW (no perl Time::HiRes); reads fine at any modest refreshInterval.
  sframes=(✦ ✶ ✷ ✸ ✹ ✺); sicon="${sframes[$(( NOW % ${#sframes[@]} ))]}"
fi

# ONE perl pass for ALL char-aware (Cyrillic) work: name capitalisation + wrapping + colouring of
# the name line, the zone divider, and the task/prev/path field blocks (no per-line bash forks).
# Emits NUL-separated blocks: [0]=name [1]=divider [2]=EMPTY PLACEHOLDER (kept so the path blocks
# stay at [5+i] — do NOT renumber) [3]=task [4]=prev [5..]=one path each.
render_text() {
  W="$W" BARMARG="${WCT_NAME_BAR_MARGIN:-1}" perl -CSA -Mutf8 -MText::Wrap -e '
    my $W=$ENV{W}+0;
    $Text::Wrap::columns=$W+1; $Text::Wrap::huge="wrap"; $Text::Wrap::unexpand=0;
    my ($glyph,$name,$task,$prev,@dirs)=@ARGV;
    $name =~ s/^(\s*)(\p{L})/$1.uc($2)/e;
    my $E="\033"; my $RESET="${E}[0m"; my $BOLD="${E}[1m"; my $FGDEF="${E}[39m";
    # Palette (Serg 2026-06-08): blue FILL bar at the top (white name); white dividers;
    # grey task; greyer previous; folders white (in bash); a calm blue-grey for the path.
    my $WHITE ="${E}[38;2;245;246;250m";  # name text on the bar
    my $GREY  ="${E}[38;2;158;162;172m";  # task — grey
    my $GREYER="${E}[38;2;110;114;124m";  # previous — greyer
    my $PATH  ="${E}[38;2;124;138;162m";  # path — calm blue-grey
    my $RULE  ="${E}[38;2;88;91;112m";    # dividers — dim, like Claude Code separators
    my $NBG   ="${E}[48;2;72;142;255m";   # blue colour FILL — the top bar only
    my $marg = ($ENV{BARMARG}//1)+0; $marg=0 if $marg<0;
    my $lp = " " x $marg;                 # shared left text-indent for every text row
    # NAME — full-width BLUE fill bar; white bold text (glyph + name); only the text is inset by $lp.
    my @nl = split /\n/, Text::Wrap::wrap("  ","  ",$name), -1;
    $_ =~ s/^  // for @nl;
    my @nm = ("$glyph $nl[0]");
    for my $i (1..$#nl) { push @nm, "  ".$nl[$i]; }
    my $nameblock = join("\n", map { my $t=$lp.$_; my $p=$W-length($t); $p=0 if $p<0;
                                     $NBG.$WHITE.$BOLD.$t.(" " x $p).$RESET } @nm);
    # one wrapped, single-colour field (label+value share the colour); empty text → "". Every line
    # gets the shared left text-indent ($lp) — applies to all text rows, not the dividers/bar.
    sub field {
      my ($c,$text)=@_; return "" if $text eq "";
      my $lc = $c ne "" ? $c : $FGDEF;   # lead with a colour code (not a space) so CC will not trim the indent
      join("\n", map { $lc.$lp.$_.$RESET } split /\n/, Text::Wrap::wrap("","   ",$text), -1);
    }
    my @b = ($nameblock,
             $RULE.("─" x $W).$RESET,                                 # dividers — dim (CC-like)
             field("",""),                                            # [2] RESERVED empty placeholder
             field($GREY,   $task ne "" ? "▸ Задача: $task"    : ""),  # Задача — grey
             field($GREYER, $prev ne "" ? "◃ Попередня: $prev" : "")); # Попередня — greyer
    push @b, field($PATH,"↳ $_") for @dirs;                          # path — calm blue-grey
    print join("", map { $_."\0" } @b);
  ' -- "$@"
}
tb=()
while IFS= read -r -d '' blk; do tb+=("$blk"); done \
  < <(render_text "$sicon" "$name" "$task" "$prev" ${dirs[@]+"${dirs[@]}"})

# meta-bar: chips joined by " · ", wrapping at $W onto fresh rows. Every row carries the same left
# text-indent as the name bar (WCT_NAME_BAR_MARGIN) — text-only; dividers/the bar are not indented.
mrg="${WCT_NAME_BAR_MARGIN:-1}"; case "$mrg" in ''|*[!0-9]*) mrg=1;; esac
printf -v indent '%*s' "$mrg" ''
cur=0; first=1
# Each row begins with $FGDEF (a colour code) BEFORE the indent spaces, so the raw line never starts
# with whitespace — otherwise Claude Code trims the leading spaces and the indent disappears.
seg() { # $1=colored text  $2=plain text (for width)
  local plen=${#2}
  if [ "$first" -eq 0 ]; then
    if [ $((cur + 3 + plen)) -gt "$W" ]; then printf '\n%b%s' "$FGDEF" "$indent"; cur=$mrg
    else printf '%b' " · "; cur=$((cur + 3)); fi
  fi
  printf '%b' "$1"; cur=$((cur + plen)); first=0
}
newrow() { printf '\n%b%s' "$FGDEF" "$indent"; cur=$mrg; first=1; }
# fmt_eta <epoch>: time left until <epoch> as 1h12m / 12m / <1m; empty if absent/past/invalid.
fmt_eta() {
  local rem h m; [ -z "${1:-}" ] && return 0
  case "$1" in ''|*[!0-9]*) return 0;; esac
  rem=$(( $1 - NOW )); [ "$rem" -le 0 ] && return 0
  h=$(( rem / 3600 )); m=$(( (rem % 3600) / 60 ))
  if   [ "$h" -gt 0 ]; then printf '%dh%02dm' "$h" "$m"
  elif [ "$m" -gt 0 ]; then printf '%dm' "$m"
  else printf '<1m'; fi
}
# git_branch <dir>: current branch, CACHED on disk ~5s (official statusline pattern). Cache hit =
# 1 stat (+ a fork-free $(<file) read); git only runs once per 5s per dir, killing the git-storm.
git_branch() {
  local d="$1" cf m
  cf="$cache_dir/.gb${d//\//_}"
  if [ -f "$cf" ]; then
    m="$(stat -f %m "$cf" 2>/dev/null || stat -c %Y "$cf" 2>/dev/null || echo 0)"
    [ "$(( NOW - m ))" -lt 5 ] && { printf '%s' "$(<"$cf")"; return; }
  fi
  local br; br="$(git -C "$d" branch --show-current 2>/dev/null)"
  printf '%s' "$br" > "$cf" 2>/dev/null || true
  printf '%s' "$br"
}

# subagents running? Counted by mtime of agent-*.jsonl within a window (portable stat, no -newermt
# which flaked; 20s window because agents write in bursts and a tight window gets missed; lingers
# ~20s after they finish — acceptable). NOTE (rework 2026-06-07): the official subagent feed is NOT
# reachable here — CC's structured `tasks` array is undocumented and absent from the statusLine stdin
# on 2.1.168 (verified by dumping raw stdin); it only feeds the separate `subagentStatusLine` panel.
agents_n=0; sess_sub="${transcript%.jsonl}/subagents"
if [ -d "$sess_sub" ]; then
  for af in "$sess_sub"/agent-*.jsonl; do
    [ -f "$af" ] || continue
    amt=$(stat -f %m "$af" 2>/dev/null || stat -c %Y "$af" 2>/dev/null || echo 0)
    [ "$(( NOW - amt ))" -le "${WCT_AGENTS_WINDOW:-20}" ] && agents_n=$((agents_n+1))
  done
fi

# running WORKFLOWS? A workflow is a different beast from an ad-hoc subagent — a background script
# that orchestrates many agents. DETECTION REWRITE (2026-06-19, after the chip never lit for a live
# run): the per-run file <session>/workflows/wf_*.json is written ONLY at COMPLETION (it carries
# durationMs / result / summary / status:"completed") — while a workflow RUNS there is no file and
# nothing ever says "running", so grepping those files could never detect a live workflow (verified:
# every wf_*.json across all sessions is "completed"). The Workflow tool also RETURNS IMMEDIATELY
# ("Workflow launched in background. Task ID: X") and runs detached, so a plain tool_use→tool_result
# pairing reads as done within milliseconds. The ONE reliable live signal is in the transcript:
#   START  = a tool_result whose text is "Workflow launched in background…" (its .tool_use_id)
#   FINISH = a later user message <task-notification> carrying that same <tool-use-id>
# Running = launched ids with no matching completion notification. (Confirmed on a real live run:
# wb3oyklnw ran 23:54→00:06 with no file the whole time.)
# COST GUARD (×N sessions/render): sessions that NEVER ran a workflow have no workflows/ dir → pay a
# single [ -d ] test (0 forks). For the few that have, ONE jq pass over the transcript (~0.04s on a
# 7.6MB file, measured) every refresh tick — cheap and gated.
wf_n=0; wf_dir="${transcript%.jsonl}/workflows"
if [ -d "$wf_dir" ] && [ -n "$transcript" ] && [ -f "$transcript" ]; then
  wf_n=$(jq -rs '
    ([ .[] | select(.message.content|type=="array") | .message.content[]?
       | select(.type=="tool_result" and ((.content|tostring)|test("Workflow launched in background")))
       | .tool_use_id ]) as $launched
    | ([ .[] | (.message.content|tostring) | scan("<tool-use-id>([^<]+)</tool-use-id>") | .[0] ]) as $done
    | [ $launched[] | select(. as $u | ($done|index($u))|not) ] | length' "$transcript" 2>/dev/null)
  case "$wf_n" in ''|*[!0-9]*) wf_n=0;; esac
fi

# ============================ NAME + task/prev ============================================
printf '%s' "${tb[0]}"                                       # <glyph> <Name> colour bar
# content sits directly under the name bar — no divider between them (the bar is the separator).
# NOTE: tb[2] is the RESERVED empty placeholder — never printed, never renumbered (the path rows
# below rely on tb[5+di], so removing the slot would shift them onto the task line).
[ -n "${tb[3]:-}" ] && printf '\n%s' "${tb[3]}"             # ▸ Задача
[ -n "${tb[4]:-}" ] && printf '\n%s' "${tb[4]}"             # ◃ Попередня
printf '\n%s' "${tb[1]}"                                     # divider (content | meta)

# ============================ META ROW 1: id · CTX · 5h · ↺ · 7d ===========================
newrow
if [ "$session_id" != "nosess" ] && [ -n "$session_id" ]; then
  seg "${CLAUDE}${BOLD}${sicon} ${session_id:0:8}${UNBOLD}${FGDEF}" "${sicon} ${session_id:0:8}"
fi
[ -n "$ctx" ] && seg "◷ CTX ${ctx}%" "◷ CTX ${ctx}%"
# Rate-limit chips use English unit letters (5h / 7d), not Cyrillic (Serg 2026-06-11). NOTE: this
# CHANGED the scraped token text — external dashboards (Recon) that matched "◴ 5г N%" / "◴ 7д N%"
# must update their patterns to "◴ 5h N%" / "◴ 7d N%".
[ -n "$rl5" ] && seg "${DIM}◴ 5h ${rl5}%${UNBOLD}" "◴ 5h ${rl5}%"
eta5="$(fmt_eta "$rl5_reset")"; [ -n "$eta5" ] && seg "${DIM}↺ ${eta5}${UNBOLD}" "↺ ${eta5}"
# 7-day window: time UNTIL it resets, as a SEPARATE "↺ Nd" chip (clearer than "day N of 7", which
# read as "7 left"; and consistent with the 5h chip's ↺ countdown). Days while ≥1 day remains, else hours.
day7=""
if [ -n "$rl7_reset" ]; then
  rem7=$(( rl7_reset - NOW ))
  if [ "$rem7" -gt 0 ]; then
    dd7=$(( rem7 / 86400 ))
    if [ "$dd7" -ge 1 ]; then day7="${dd7}d"
    else hh7=$(( rem7 / 3600 )); { [ "$hh7" -ge 1 ] && day7="${hh7}h"; } || day7="<1h"; fi
  fi
fi
[ -n "$rl7" ] && seg "${DIM}◴ 7d ${rl7}%${UNBOLD}" "◴ 7d ${rl7}%"
[ -n "$day7" ] && seg "${DIM}↺ ${day7}${UNBOLD}" "↺ ${day7}"

# ============================ META ROW 2: model · effort · PR ==============================
newrow
[ -n "$model_disp" ] && seg "◆ ${model_disp}${ctxsize}" "◆ ${model_disp}${ctxsize}"
[ -n "$effort" ]     && seg "↯ ${effort}" "↯ ${effort}"
# P7: PR chip from the JSON (no extra git call) — guarded, so it simply doesn't render until a PR exists.
[ -n "$pr_num" ] && seg "${DIM}⇄ PR #${pr_num}${pr_state:+ ${pr_state}}${UNBOLD}" "⇄ PR #${pr_num}${pr_state:+ ${pr_state}}"

# ============================ ACTIVITY ROW (subagents and/or workflows) ====================
if [ "${agents_n:-0}" -gt 0 ] || [ "${wf_n:-0}" -gt 0 ]; then
  newrow
  if [ "${agents_n:-0}" -gt 0 ]; then
    aframes=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏); aspin="${aframes[$(( NOW % ${#aframes[@]} ))]}"
    seg "${AGCOL}${BOLD}${aspin} agents ×${agents_n}${UNBOLD}${FGDEF}" "${aspin} agents ×${agents_n}"
  fi
  if [ "${wf_n:-0}" -gt 0 ]; then
    wflabel="⚙ wf"; [ "$wf_n" -gt 1 ] && wflabel="⚙ wf ×${wf_n}"
    seg "${WFCOL}${BOLD}${wflabel}${UNBOLD}${FGDEF}" "$wflabel"
  fi
fi

# ============================ FOLDER / PATH ROWS ===========================================
# One pair per working dir: ⌂ name · ⎇ branch, then its ↳ full path. ⌂ name is an OSC-8 link.
if [ "${#dirs[@]}" -gt 0 ]; then
  printf '\n%s' "${tb[1]}"                                   # divider (meta | paths)
  di=0
  for dd in ${dirs[@]+"${dirs[@]}"}; do
    newrow
    dn="${dd##*/}"                                           # basename via builtin (no fork)
    printf -v dlink '\033]8;;file://%s\033\\\342\214\202 %s\033]8;;\033\\' "$dd" "$dn"
    seg "${LIGHT}${dlink}${FGDEF}" "⌂ ${dn}"
    dbr="$(git_branch "$dd")"
    [ -n "$dbr" ] && seg "${LIGHT}⎇ ${dbr}${FGDEF}" "⎇ ${dbr}"
    printf '\n%s' "${tb[$((5 + di))]:-↳ $dd}"                # pre-coloured ↳ path block
    di=$((di + 1))
  done
fi
printf '%b' "$RESET"
exit 0
