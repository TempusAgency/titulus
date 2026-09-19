#!/usr/bin/env bash
# wave-chat-title — Claude Code status line card: variant B «Сегменти» — a boxed card with FOUR
# segments, ALWAYS, in this order: role -> id+counters -> engine+movement -> place. None of them
# ever appears or disappears depending on runtime state — only their CONTENT changes. Ported from
# the reference renderer `design/render.py` / `design/REFERENCE.md` (do not edit those — they are
# the spec + contract test). Top->bottom:
#   ╭──────────────────────────────────────────────────────────╮   top border: plain rail, no id/glyph
#   │ <glyph> <role text, wrapped, hang-indented>               │   role
#   ├──────────────────────────────────────────────────────────┤   separator (single — never borders engine)
#   │ <glyph> <id>  ◷ CTX N%  ◴ 5h N%  ↺ eta  ◴ 7d N%  ↺ eta    │   id + counters
#   ├──────────────────────────────────────────────────────────┤   double rail if engine is active
#   │ ◆ model  ↯ effort  [⇄ PR #N]  [⠹ agents ×N] [⚙ wf ×N] [⇅ coord] │  engine + movement, one segment
#   ├──────────────────────────────────────────────────────────┤   double rail if engine is active
#   │ ⌂ dir  ↱ branch  ↳ path  (one row per working dir)        │   place
#   ╰──────────────────────────────────────────────────────────╯
# Rails: single ─ = inactive, double ═ = active (2nd signal channel besides colour). Only the two
# rails bordering the engine segment can ever go double; the role|id rail and the outer top/bottom
# borders are always single. "Active" = `.working` marker OR live agents/wf (coord mail shows the
# segment but never lights it up).
# Corners: TL/BR use the TempusGlyphs PUA glyphs (font: ~/Library/Fonts/TempusGlyphs-Regular.ttf,
# U+E87E / U+E881); TR/BL are always the plain ┐ / └. Branch glyph is ↱ (U+21B1), NOT ⎇ — the
# latter is missing from the font stack in use and renders broken.
#
# LAYOUT CONFIG (2026-09-19): segment order and which tokens show up in each segment are no longer
# hardcoded here — they are read from the SAME `design/layout.conf` file that `design/render.py`
# reads (see that file's header for the format). This is the ONE description of the card's layout;
# editing it changes both the design demo and this production script identically. COST DISCIPLINE
# still applies: the config file is opened and parsed INSIDE the existing single perl process
# (`render_text`, below) — resolving its path in bash uses only parameter expansion and `[ -f ]`
# tests (bash builtins, zero forks), and reading/parsing it happens with perl's own `open()`, not a
# new subprocess. No fork was added by this change — see the handback report for the exact
# before/after subprocess count.
#
# Removed in this port (2026-09-18, variant B rollout): the old flat "▸ Задача / ◃ Попередня"
# AI-summary lines. The boxed design (render.py Scene / REFERENCE.md) has no slot for them — the
# role line replaces that orienting function. The background writer (topic-update.sh) still writes
# its cache file; this script just no longer reads or displays it. Fully recoverable from git
# history (see `git log -- statusline.sh`) if that turns out to be wrong.
#
# RE-LAYOUT (later fix): an intermediate revision had moved the session id into the top border and
# split model/effort from the movement indicators into a segment that only showed up while
# something was running. That was reverted to the corrected layout documented above and in
# design/REFERENCE.md — four segments, always, id back inside its own segment with the counters,
# engine+movement back on one line.
#
# COST DISCIPLINE (rework 2026-06-07, reaffirmed 2026-09-18 during the box-layout port, and again
# 2026-09-19 during the layout.conf port): this script runs on a GLOBAL config, so every fork is
# multiplied by the count of live sessions (~40). ALL char-aware work — role word-wrap, path
# truncation, box-frame drawing (borders, separators, padding, rails), colouring, AND NOW layout
# config parsing — happens in the ONE perl pass (`render_text`), exactly as before the port. No
# python, no extra forks were added for the new layout or for the config file. Before adding any
# per-render command, remember it costs ×(live sessions).
#
# VISUAL-DEFECT FIX (2026-09-19, real Claude Code screenshot): every card line ended in CC's own
# "…" (right border invisible) and the left margin looked oversized (left border unreadable).
# Three independent causes, three fixes, all inside the existing single perl pass — no new forks:
#   1. Width: $W was COLUMNS-1. Per CC's own docs, COLUMNS is the RAW terminal width, and CC's
#      status-line chrome reserves ADDITIONAL columns of its own that COLUMNS does NOT reflect —
#      so COLUMNS-1 was still too wide and CC truncated the overflow with "…". Now subtracted via
#      $WMARGIN (default 3, safer but still a placeholder — see the width-test mode below for how
#      to measure the exact number on real hardware and drop it in $user_dir/.width_margin).
#   2. Left inset: content_row() used to add its OWN leading space between "│" and the content,
#      on top of CC's un-removable built-in chrome margin. Removed — the card now starts flush
#      against its own border; CC's own margin (undocumented size) is unchanged and out of our
#      control. See design/REFERENCE.md's 2026-09-19 note for the byte-exact effect.
#   3. Border colour: $INACTIVE (58;69;92) had ≈2.2:1 contrast on black — nearly invisible.
#      Brightened ×1.5 (same hue ratio) to 87;104;138, ≈3.7:1. Also: the frame is now ONE colour
#      everywhere, active or not — the old terracotta highlight on the rails was removed
#      (owner's call, after watching the live card: at narrow width the engine segment wraps to
#      2 lines, so a coloured double rail above AND below it read as "two orange stripes"). The
#      double `═` rail is still the (colourless) activity signal.
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

name_file="$cache_dir/$session_id.name"       # auto chat name (provisional or frozen)
heur_file="$cache_dir/$session_id.heur"       # 1 line fallback: first user message
name_user="$user_dir/$session_id.topic"       # user-stated NAME (wins, permanent)

# coord ROLE + coord PRESENCE (SPEC-card-line1-role / activity ⇅ coord): ONLY if a coord inbox
# file for this session exists in cwd. ZERO forks when the file is absent (the common case); one
# grep when present. coord_present drives the activity chip; coord_role feeds the name/role
# precedence chain below — SAME disk read, no extra access for the new indicator.
coord_present=0
coord_role=""
if [ -n "$cwd" ] && [ -f "$cwd/_coord/inbox/$session_id.md" ]; then
  coord_present=1
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
  fi
fi

# ROLE ("Слово. допис") = the card's identity segment text. Precedence: user-set role → coord role
# → CC session_name → background auto-role → first-message heuristic. HARD RULE: the AI auto-role
# and the heuristic NEVER override a KNOWN role (user-set or coord) — that kills the "card
# describes its own restart / shows (нова сесія)" bug.
name=""
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
# bytes never occur inside multibyte sequences).
name="${name//[[:cntrl:]]/}"

# sanity cap — matches design's truncate_role(160): the perl word-wrap only handles normal
# lengths; this stops a runaway paragraph before it ever reaches the box.
cap=160
[ "${#name}" -gt "$cap" ] && name="${name:0:cap}…"

# wrap width — adaptive, with a fallback chain so it works even where CC can't hand us the width:
#   1) $COLUMNS — the real terminal width CC exports (≥2.1.153). Best, and updates on resize.
#   2) tmux pane width — for tmux-based launchers (e.g. Tempus Launcher) where CC runs captured and
#      does NOT export COLUMNS, so the card would otherwise fall back to a narrow 38. This queries
#      the LIVE pane, so it re-adapts when the pane/block is resized. Only runs when COLUMNS absent.
#   3) manual .wrapwidth override → 4) 38.
# This is the box's total outer width (border to border) — content_row/top_border/etc pad or
# truncate every line to exactly this many cells.
#
# WIDTH MARGIN (2026-09-19 — fixes every line ending in CC-added "…"): $COLUMNS is the RAW
# terminal width (CC docs: "Claude Code sets these to the current terminal dimensions" — the
# full terminal, not the usable content area). Separately, CC's own status-line chrome reserves
# some columns of its OWN that are NOT reflected in COLUMNS (docs: the `padding` setting "adds
# extra horizontal spacing... IN ADDITION TO the interface's built-in spacing" — so an
# undocumented built-in margin exists even at padding:0). Drawing a card exactly COLUMNS-1 cells
# wide overflows that real usable width, so CC truncates our own last cell(s) and appends its
# own "…" on every line — this is what was observed on the live card. Subtracting only 1 was
# not enough. WMARGIN below is a SAFER default (not a measured value — do not treat 3 as final).
# Get the exact number for real hardware via the width-test mode a few lines down (touch
# $user_dir/.widthtest), then drop it in $user_dir/.width_margin — no code edit needed.
margin_file="$user_dir/.width_margin"
if [ -s "$margin_file" ]; then WMARGIN="$(<"$margin_file")"; else WMARGIN=3; fi
case "$WMARGIN" in ''|*[!0-9]*) WMARGIN=3;; esac

if [ -n "${COLUMNS:-}" ] && [ "$COLUMNS" -gt 0 ] 2>/dev/null; then
  W=$(( COLUMNS > WMARGIN ? COLUMNS - WMARGIN : 1 ))
elif [ -n "${TMUX:-}" ] && _pw="$(tmux display-message -p '#{pane_width}' 2>/dev/null)" && [ "${_pw:-0}" -gt 0 ] 2>/dev/null; then
  W=$(( _pw > WMARGIN ? _pw - WMARGIN : 1 ))
elif [ -f "$cache_dir/.wrapwidth" ]; then
  W="$(<"$cache_dir/.wrapwidth")"
else
  W=38
fi
case "$W" in ""|*[!0-9]*) W=38;; esac

# WIDTH-TEST MODE (manual, opt-in, zero cost when off — one `[ -f ]` test, no fork): touch
# $user_dir/.widthtest, trigger a re-render (send any message, or wait for refreshInterval),
# read the card, then `rm` the flag file. Prints one ruler line per candidate width, each ending
# in a "[END m=N]" tag where N = how many columns were subtracted from the RAW $COLUMNS for that
# line. Find the LONGEST line whose "[END m=N]" tag is fully visible — i.e. NOT cut off with a
# trailing "…". That line's N is the exact, measured value to put in $user_dir/.width_margin
# (one integer, no quotes). If even m=8 still shows "…", the deficit is bigger — widen the
# `delta` list below and re-test. Uses only bash builtins (printf, arithmetic, a for-loop) — no
# subprocess, so it is safe to leave this block in the shipped script.
if [ -f "$user_dir/.widthtest" ]; then
  base="${COLUMNS:-$W}"
  out=""
  for delta in 0 1 2 3 4 5 6 7 8; do
    len=$(( base - delta )); [ "$len" -lt 8 ] && continue
    tag="[END m=${delta}]"; tlen=${#tag}
    fillcount=$(( len - tlen )); [ "$fillcount" -lt 0 ] && fillcount=0
    fill=""; _i=0; while [ "$_i" -lt "$fillcount" ]; do fill="${fill}-"; _i=$((_i+1)); done
    out="${out}${fill}${tag}"$'\n'
  done
  printf '%s' "$out"
  exit 0
fi

# layout config path — resolution chain, ZERO forks (pure bash builtins: parameter expansion +
# `[ -f ]` tests). Two candidates, checked in order:
#   1) repo/dev mode: a `design/layout.conf` sibling of THIS script's own directory (true when
#      running straight out of the plugin repo — e.g. `bash statusline.sh` from a checkout, or a
#      plugin-cache copy that still carries the whole repo tree next to it).
#   2) installed mode: `$user_dir/layout.conf` — the persistent copy `install.sh` seeds into
#      `~/.claude/wave-chat-title/` (the SAME directory as the stable statusline.sh copy), since
#      the installed copy is detached from the repo and has no `design/` sibling.
# If neither exists, LAYOUT_CONF is left empty and the perl pass below falls back to an embedded
# default that reproduces the original (pre-config) hardcoded layout exactly.
_self="${BASH_SOURCE[0]:-$0}"
script_dir="${_self%/*}"
[ "$script_dir" = "$_self" ] && script_dir="."
layout_conf=""
if   [ -f "$script_dir/design/layout.conf" ]; then layout_conf="$script_dir/design/layout.conf"
elif [ -f "$user_dir/layout.conf" ]; then layout_conf="$user_dir/layout.conf"
fi

# build the clean working-dir list (cwd + every /add-dir'd dir), empties filtered, used for the
# place segment (one row/pair per dir).
rawdirs=("$cwd")
for ad in ${added_dirs[@]+"${added_dirs[@]}"}; do rawdirs+=("$ad"); done
dirs=()
for d in ${rawdirs[@]+"${rawdirs[@]}"}; do [ -n "$d" ] && dirs+=("$d"); done

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

# subagents running? Counted by mtime of agent-*.jsonl within a window (portable stat, no -newermt
# which flaked; 20s window because agents write in bursts and a tight window gets missed; lingers
# ~20s after they finish — acceptable). NOTE (rework 2026-06-07): the official subagent feed is NOT
# reachable here — CC's structured `tasks` array is undocumented and absent from the statusLine
# stdin on 2.1.168 (verified by dumping raw stdin); it only feeds the separate `subagentStatusLine`
# panel.
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
# run): the per-run file <session>/workflows/wf_*.json is written ONLY at COMPLETION, while a
# workflow RUNS there is no file and nothing ever says "running", so grepping those files could
# never detect a live workflow. The ONE reliable live signal is in the transcript:
#   START  = a tool_result whose text is "Workflow launched in background…" (its .tool_use_id)
#   FINISH = a later user message <task-notification> carrying that same <tool-use-id>
# Running = launched ids with no matching completion notification.
# COST GUARD (×N sessions/render): sessions that NEVER ran a workflow have no workflows/ dir → pay a
# single [ -d ] test (0 forks). For the few that have, ONE jq pass over the transcript every tick.
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

# "working" = explicit marker (UserPromptSubmit hook) OR the transcript was written in the last 5s.
working=0
[ -f "$cache_dir/$session_id.working" ] && working=1
if [ "$working" = 0 ] && [ -n "$transcript" ] && [ -f "$transcript" ]; then
  tmt="$(stat -f %m "$transcript" 2>/dev/null || stat -c %Y "$transcript" 2>/dev/null || echo 0)"
  [ "$(( NOW - tmt ))" -le 5 ] && working=1
fi

# «Активний» = маркер .working АБО біжать agents/wf (REFERENCE.md rule). Drives: the animated
# glyph, the identity segment's border colour/rail, and the activity segment's colour/rail.
# Coordination mail alone (coord_present) never sets busy — the segment shows but stays muted.
busy=0
[ "$working" = 1 ] && busy=1
[ "${agents_n:-0}" -gt 0 ] && busy=1
[ "${wf_n:-0}" -gt 0 ] && busy=1

sicon="✻"
if [ "$busy" = 1 ]; then
  # step ONE frame per second off NOW (no perl Time::HiRes); reads fine at any modest refreshInterval.
  sframes=(✦ ✶ ✷ ✸ ✹ ✺); sicon="${sframes[$(( NOW % ${#sframes[@]} ))]}"
fi

# ============================ vitals row fields (builtins only, no forks) ==================
eta5="$(fmt_eta "$rl5_reset")"
# 7-day window: time UNTIL it resets, as a SEPARATE "↺ Nd" chip. Days while ≥1 day remains, else hours.
day7=""
if [ -n "$rl7_reset" ]; then
  rem7=$(( rl7_reset - NOW ))
  if [ "$rem7" -gt 0 ]; then
    dd7=$(( rem7 / 86400 ))
    if [ "$dd7" -ge 1 ]; then day7="${dd7}d"
    else hh7=$(( rem7 / 3600 )); { [ "$hh7" -ge 1 ] && day7="${hh7}h"; } || day7="<1h"; fi
  fi
fi
modeldisp="${model_disp}${ctxsize}"
prchip=""
[ -n "$pr_num" ] && prchip="⇄ PR #${pr_num}${pr_state:+ ${pr_state}}"

# ============================ activity row tokens ===========================================
agentstok=""
if [ "${agents_n:-0}" -gt 0 ]; then
  aframes=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏); aspin="${aframes[$(( NOW % ${#aframes[@]} ))]}"
  agentstok="${aspin} agents ×${agents_n}"
fi
wftok=""
if [ "${wf_n:-0}" -gt 0 ]; then
  wftok="⚙ wf"; [ "$wf_n" -gt 1 ] && wftok="⚙ wf ×${wf_n}"
fi
coordtok=""
[ "$coord_present" = 1 ] && coordtok="⇅ coord"

# ============================ place segment entries (name\x1fbranch\x1fpath per dir) =======
place_args=()
for dd in ${dirs[@]+"${dirs[@]}"}; do
  dn="${dd##*/}"
  dbr="$(git_branch "$dd")"
  [ -z "$dbr" ] && dbr="—"
  place_args+=("${dn}"$'\x1f'"${dbr}"$'\x1f'"${dd}")
done

# ONE perl pass for ALL char-aware (Cyrillic) work AND the entire box frame: role word-wrap, path
# truncation, borders/separators/content-row padding, rails (single/double), colouring, AND (since
# 2026-09-19) parsing `design/layout.conf` to decide segment order + which tokens each segment
# shows. Nothing outside this call touches character widths, and nothing outside it opens the
# layout file. Emits the finished card (with embedded newlines) on stdout — a single command
# substitution below, no new fork beyond this one perl process (config parsing is an in-process
# `open()`, not a subprocess).
render_text() {
  W="$W" LAYOUT_CONF="$layout_conf" perl -CSA -Mutf8 -e '
    my $W=$ENV{W}+0;
    my ($glyph,$sid,$busy,$role,$ctx,$rl5,$eta5,$rl7,$day7,$modeldisp,$effort,$prchip,
        $agentstok,$wftok,$coordtok,@rest)=@ARGV;
    $busy = $busy ? 1 : 0;
    $role =~ s/^(\s*)(\p{L})/$1.uc($2)/e;

    my $E="\033"; my $RESET="${E}[0m"; my $BOLD="${E}[1m";
    my $WHITE ="${E}[38;2;245;246;250m";   # role text
    my $GREY  ="${E}[38;2;158;162;172m";   # id / engine text
    my $PATHC ="${E}[38;2;124;138;162m";   # place path
    # 2026-09-19: border/rail is now ONE colour everywhere, active or not — the terracotta
    # highlight was removed (owner watched the live card: at narrow width the engine segment
    # wraps to 2 lines, so a coloured double-rail top+bottom read as "two orange stripes").
    # The double `═` rail is still the activity signal, just colourless now. $ACTIVE is kept
    # defined (unused by the frame) in case a future TEXT-only accent wants it.
    my $ACTIVE="${E}[38;2;217;119;87m";    # terracotta — reserved, no longer used for the frame
    # inactive border/rail — and now the ONLY frame colour. Was 58;69;92: contrast ≈2.2:1 on
    # black (below the ~3:1 floor for UI-element visibility) — near-invisible. Brightened ×1.5
    # on all channels (58,69,92→87,104,138), same hue ratio/"family", contrast ≈3.7:1.
    my $INACTIVE="${E}[38;2;87;104;138m";  # frame colour, active or not

    my $TL = "\x{E87E}"; my $TR = "┐"; my $BL = "└"; my $BR = "\x{E881}";
    my $VBAR = "│"; my $SEPL = "├"; my $SEPR = "┤";
    my $BRANCHG = "↱";

    my $NARROW_THRESHOLD = 60;
    my $narrow = $W < $NARROW_THRESHOLD;

    sub rail_char { my ($a)=@_; return $a ? "═" : "─"; }
    sub colorize  { my ($t,$rgb,$bold)=@_; return (($bold?$BOLD:"").$rgb.$t.$RESET); }

    # Top/bottom border — a PLAIN rail, corner to corner. No id, no glyph:
    # those live inside the role/id content segments now, not in the frame.
    # Always single/inactive — the outer borders never border the engine
    # segment, so they never take part in the highlight.
    sub plain_border {
      my ($width,$left,$right)=@_;
      my $rgb=$INACTIVE;
      return $left.colorize("─" x ($width-2),$rgb,0).$right;
    }
    sub separator {
      my ($width,$active)=@_;
      my $r=rail_char($active); my $rgb=$INACTIVE;   # uniform frame colour — see $INACTIVE above
      return $SEPL.colorize($r x ($width-2),$rgb,0).$SEPR;
    }
    sub content_row {
      my ($width,$text,$rgb,$bold)=@_;
      my $body = $width-2;
      # No leading space of our own (removed 2026-09-19): that space between "│" and the text
      # was OUR inset, stacked on top of whatever margin the Claude Code status-line chrome
      # already adds outside this script output. Callers that want a visual gap (wrap_role
      # builds "<glyph> <text>") bake it into $text themselves.
      my $inner = $text;
      if (length($inner) > $body) { $inner = substr($inner,0,$body-1)."…"; }
      $inner .= (" " x ($body-length($inner))) if length($inner) < $body;
      my $rendered = $rgb ? colorize($inner,$rgb,$bold) : $inner;
      return $VBAR.$rendered.$VBAR;
    }

    sub truncate_path {
      my ($path,$budget)=@_;
      return $path if length($path) <= $budget;
      my @parts = split m{/}, $path, -1;
      for my $i (1..$#parts) {
        my $cand = "…/".join("/", @parts[$i..$#parts]);
        return $cand if length($cand) <= $budget;
      }
      my $last = $parts[-1];
      my $cand = "…/".$last;
      return $cand if length($cand) <= $budget;
      return "…" if $budget <= 1;
      return "…".substr($last, -($budget-1));
    }

    # Word-wrap the role text, glyph baked into the first line ("<glyph>
    # <text>"), a same-width 2-space indent baked into continuation lines
    # ("  <text>") — both are 2 cells wide, so one wrap budget serves both:
    # budget = (width-2) - 2, where (width-2) is the max content length
    # content_row() can hold (VBAR+content+VBAR — no reserved leading space
    # any more, see content_row() above).
    sub wrap_role {
      my ($text,$width,$glyph)=@_;
      my $budget = ($width-2)-2; $budget=1 if $budget<1;
      my @words = split /\s+/, $text;
      my @lines; my $cur="";
      for my $w (@words) {
        next if $w eq "";
        my $cand = $cur eq "" ? $w : "$cur $w";
        if (length($cand) <= $budget) { $cur = $cand; }
        else { push(@lines,$cur) if $cur ne ""; $cur = $w; }
      }
      push(@lines,$cur) if $cur ne "" || !@lines;
      my @out;
      for my $i (0..$#lines) {
        push @out, ($i==0 ? "$glyph $lines[$i]" : "  $lines[$i]");
      }
      return @out;
    }

    # Greedily pack the engine segment tokens (model/effort/PR/movement
    # chips) into as few lines as fit `width`, never splitting a token —
    # so at a narrow width the segment wraps onto a second line instead of
    # being cut off mid-token by content_row own hard ellipsis truncation.
    sub wrap_tokens {
      my ($parts,$width)=@_;
      my $budget = $width-2; $budget=1 if $budget<1;
      my @lines; my $cur="";
      for my $p (@$parts) {
        next if $p eq "";
        my $cand = $cur eq "" ? $p : "$cur  $p";
        if (length($cand) <= $budget) { $cur = $cand; }
        else { push(@lines,$cur) if $cur ne ""; $cur = $p; }
      }
      push(@lines,$cur) if $cur ne "" || !@lines;
      return @lines;
    }

    # build_place_lines: token-driven — $tokorder is the ordered list of
    # dir/branch/path tokens for THIS segment (from layout.conf), $nlayout
    # is "split" (path gets its own line at narrow width) or "inline".
    sub build_place_lines {
      my ($entries,$width,$narrow,$tokorder,$nlayout)=@_;
      my $budget_total = $width-2;
      my @lead_toks = grep { $_ ne "path" } @$tokorder;
      my $has_path  = grep { $_ eq "path" } @$tokorder;
      my @lines;
      for my $e (@$entries) {
        my ($name,$branch,$path) = @$e;
        my @lead_parts;
        for my $t (@lead_toks) {
          if    ($t eq "dir")    { push @lead_parts, "⌂ $name"; }
          elsif ($t eq "branch") { push @lead_parts, "$BRANCHG $branch"; }
        }
        my $lead_str = join("  ", @lead_parts);
        if ($narrow && $nlayout eq "split" && $has_path) {
          push @lines, $lead_str;
          my $pb = $budget_total; $pb=1 if $pb<1;
          push @lines, truncate_path($path,$pb);
        } elsif ($has_path) {
          my $prefix = $lead_str ne "" ? "$lead_str  ↳ " : "↳ ";
          my $pb = $budget_total - length($prefix); $pb=1 if $pb<1;
          my $ptext = length($path) <= $pb ? $path : truncate_path($path,$pb);
          my $line = $prefix.$ptext;
          if (length($line) > $budget_total) { $line = substr($line,0,$budget_total-1)."…"; }
          push @lines, $line;
        } else {
          my $line = $lead_str;
          if (length($line) > $budget_total) { $line = substr($line,0,$budget_total-1)."…"; }
          push @lines, $line;
        }
      }
      return @lines;
    }

    my @entries;
    for my $r (@rest) {
      my @f = split /\x1f/, $r, -1;
      push @entries, [$f[0]//"", $f[1]//"", $f[2]//""];
    }

    # ---------------------------------------------------------------------
    # layout.conf — parsed HERE, inside the already-running perl process.
    # Format documented in design/layout.conf; kept intentionally simple
    # (line-based, no nesting) so a hand-rolled parser is enough — no JSON
    # module, no extra dependency, no extra fork.
    # ---------------------------------------------------------------------
    my @order;
    my %seg;
    my $layout_conf = $ENV{LAYOUT_CONF} // "";
    if ($layout_conf ne "" && open(my $lf, "<:encoding(UTF-8)", $layout_conf)) {
      my $cur;
      while (my $line = <$lf>) {
        $line =~ s/^\s+|\s+$//g;
        next if $line eq "" || $line =~ /^#/;
        if ($line =~ /^order:\s*(.+)$/) { @order = split /\s+/, $1; next; }
        if ($line =~ /^\[(\w+)\]$/) {
          $cur = $1;
          $seg{$cur} = { tokens=>[], narrow_tokens=>undef, active=>"never", narrow_layout=>"inline" };
          next;
        }
        next unless defined $cur;
        if ($line =~ /^tokens:\s*(.*)$/)        { $seg{$cur}{tokens} = [split /\s+/, $1]; next; }
        if ($line =~ /^narrow_tokens:\s*(.*)$/)  { $seg{$cur}{narrow_tokens} = [split /\s+/, $1]; next; }
        if ($line =~ /^active:\s*(\S+)$/)        { $seg{$cur}{active} = $1; next; }
        if ($line =~ /^narrow_layout:\s*(\S+)$/) { $seg{$cur}{narrow_layout} = $1; next; }
      }
      close $lf;
    }
    unless (@order) {
      # embedded fallback — reproduces the original (pre-config) hardcoded layout exactly, so a
      # missing/unreadable layout.conf never breaks the card.
      @order = qw(role id engine place);
      %seg = (
        role   => { tokens=>["role"], narrow_tokens=>undef, active=>"never", narrow_layout=>"inline" },
        id     => { tokens=>[qw(id ctx rl5 eta5 rl7 eta7)], narrow_tokens=>[qw(id ctx)],
                    active=>"never", narrow_layout=>"inline" },
        engine => { tokens=>[qw(model effort pr agents wf coord)], narrow_tokens=>undef,
                    active=>"busy", narrow_layout=>"inline" },
        place  => { tokens=>[qw(dir branch path)], narrow_tokens=>undef,
                    active=>"never", narrow_layout=>"split" },
      );
    }
    for my $name (@order) {
      $seg{$name} //= { tokens=>[], narrow_tokens=>undef, active=>"never", narrow_layout=>"inline" };
    }

    # token value catalogue — id/engine segments. Empty string = "nothing to show", dropped by
    # the caller, never leaves a gap (same rule as the render.py token_value_* helpers).
    my %idval = (
      id   => "$glyph $sid",
      ctx  => ($ctx  ne "" ? "◷ CTX ${ctx}%"  : ""),
      rl5  => ($rl5  ne "" ? "◴ 5h ${rl5}%"   : ""),
      eta5 => ($eta5 ne "" ? "↺ ${eta5}"      : ""),
      rl7  => ($rl7  ne "" ? "◴ 7d ${rl7}%"   : ""),
      eta7 => ($day7 ne "" ? "↺ ${day7}"      : ""),
    );
    my %engval = (
      model  => ($modeldisp ne "" ? "◆ ${modeldisp}" : ""),
      effort => ($effort    ne "" ? "↯ ${effort}"     : ""),
      pr     => $prchip,
      agents => $agentstok,
      wf     => $wftok,
      coord  => $coordtok,
    );

    sub seg_tokens {
      my ($cfg,$narrow)=@_;
      return @{$cfg->{narrow_tokens}} if ($narrow && defined $cfg->{narrow_tokens});
      return @{$cfg->{tokens}};
    }

    # --- build the lines for each segment, in the CONFIGURED order ---
    my @blocks;
    for my $name (@order) {
      my $cfg = $seg{$name};
      my @lines;
      if ($name eq "role") {
        @lines = wrap_role($role, $W, $glyph);
      } elsif ($name eq "id") {
        my @toks = seg_tokens($cfg,$narrow);
        my @parts; for my $t (@toks) { my $v=$idval{$t}//""; push @parts,$v if $v ne ""; }
        @lines = (join("  ",@parts));
      } elsif ($name eq "engine") {
        my @toks = seg_tokens($cfg,$narrow);
        my @parts; for my $t (@toks) { my $v=$engval{$t}//""; push @parts,$v if $v ne ""; }
        @lines = wrap_tokens(\@parts, $W);
      } elsif ($name eq "place") {
        my @toks = seg_tokens($cfg,$narrow);
        @lines = build_place_lines(\@entries, $W, $narrow, \@toks, $cfg->{narrow_layout});
      } else {
        @lines = ();
      }
      my $active = ($cfg->{active} eq "busy") ? $busy : 0;
      push @blocks, [\@lines, $active, $name];
    }

    my @rows;
    push @rows, plain_border($W, $TL, $TR);
    for my $bi (0..$#blocks) {
      my ($lines,$active,$kind) = @{$blocks[$bi]};
      for my $ln (@$lines) {
        if    ($kind eq "role")  { push @rows, content_row($W, $ln, $WHITE, 1); }
        elsif ($kind eq "place") {
          my $rgb = ($ln =~ /^[⌂…]/) ? $PATHC : $GREY;
          push @rows, content_row($W, $ln, $rgb, 0);
        } else { push @rows, content_row($W, $ln, $GREY, 0); }
      }
      if ($bi < $#blocks) {
        my $next_active = $blocks[$bi+1][1];
        push @rows, separator($W, $active || $next_active);
      }
    }
    push @rows, plain_border($W, $BL, $BR);

    print join("\n", @rows);
  ' -- "$@"
}

card="$(render_text "$sicon" "${session_id:0:8}" "$busy" "$name" \
  "$ctx" "$rl5" "$eta5" "$rl7" "$day7" "$modeldisp" "$effort" "$prchip" \
  "$agentstok" "$wftok" "$coordtok" ${place_args[@]+"${place_args[@]}"}
)"
printf '%s\n' "$card"
exit 0
