#!/usr/bin/env bash
# wave-chat-title — Claude Code status line card: variant B «Сегменти» — a boxed card with
# segments identity (id+role) -> vitals (CTX/5h/7d/model/effort) -> activity (agents/wf/coord,
# only when there is something to show) -> place (working directories). Ported from the approved
# reference renderer `design/render.py` / `design/REFERENCE.md` (do not edit those — they are the
# spec + contract test). Top→bottom:
#   ╭─ <glyph> <id> ───────────────────────────────────────────╮   top border: id + animated glyph
#   │ <role text, wrapped, hang-indented>                      │   identity
#   ├────────────────────────────────────────────────────────── ┤   separator (double rail if active)
#   │ ◷ CTX N%  ◴ 5h N%  ↺ eta  ◴ 7d N%  ↺ eta                 │   vitals row 1
#   │ ◆ model  ↯ effort  [⇄ PR #N state]                       │   vitals row 2
#   ├──────────────────────────────────────────────────────────┤   (only if agents/wf/coord)
#   │ ⠹ agents ×N  ⚙ wf ×N  ⇅ coord                            │   activity
#   ├──────────────────────────────────────────────────────────┤
#   │ ⌂ dir  ↱ branch  ↳ path  (one row per working dir)        │   place
#   ╰──────────────────────────────────────────────────────────╯
# Rails: single ─ = inactive, double ═ = active (2nd signal channel besides colour). "Active" =
# `.working` marker OR live agents/wf (coord mail shows the segment but never lights it up).
# Corners: TL/BR use the TempusGlyphs PUA glyphs (font: ~/Library/Fonts/TempusGlyphs-Regular.ttf,
# U+E87E / U+E881); TR/BL are always the plain ┐ / └. Branch glyph is ↱ (U+21B1), NOT ⎇ — the
# latter is missing from the font stack in use and renders broken.
#
# Removed in this port (2026-09-18, variant B rollout): the old flat "▸ Задача / ◃ Попередня"
# AI-summary lines. The boxed design (render.py Scene / REFERENCE.md) has no slot for them — the
# role line replaces that orienting function. The background writer (topic-update.sh) still writes
# its cache file; this script just no longer reads or displays it. Fully recoverable from git
# history (see `git log -- statusline.sh`) if that turns out to be wrong.
#
# COST DISCIPLINE (rework 2026-06-07, reaffirmed 2026-09-18 during the box-layout port): this
# script runs on a GLOBAL config, so every fork is multiplied by the count of live sessions
# (~40). ALL char-aware work — role word-wrap, path truncation, box-frame drawing (borders,
# separators, padding, rails), colouring — happens in the ONE perl pass (`render_text`), exactly
# as before the port. No python, no extra forks were added for the new layout; see the handback
# report for the before/after subprocess count. Before adding any per-render command, remember it
# costs ×(live sessions).
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
if [ -n "${COLUMNS:-}" ] && [ "$COLUMNS" -gt 0 ] 2>/dev/null; then
  W=$(( COLUMNS > 1 ? COLUMNS - 1 : COLUMNS ))
elif [ -n "${TMUX:-}" ] && _pw="$(tmux display-message -p '#{pane_width}' 2>/dev/null)" && [ "${_pw:-0}" -gt 0 ] 2>/dev/null; then
  W=$(( _pw > 1 ? _pw - 1 : _pw ))
elif [ -f "$cache_dir/.wrapwidth" ]; then
  W="$(<"$cache_dir/.wrapwidth")"
else
  W=38
fi
case "$W" in ""|*[!0-9]*) W=38;; esac

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
# truncation, borders/separators/content-row padding, rails (single/double), colouring. Nothing
# outside this call touches character widths. Emits the finished card (with embedded newlines) on
# stdout — a single command substitution below, no new fork beyond this one perl process.
render_text() {
  W="$W" perl -CSA -Mutf8 -e '
    my $W=$ENV{W}+0;
    my ($glyph,$sid,$busy,$role,$ctx,$rl5,$eta5,$rl7,$day7,$modeldisp,$effort,$prchip,
        $agentstok,$wftok,$coordtok,@rest)=@ARGV;
    $busy = $busy ? 1 : 0;
    $role =~ s/^(\s*)(\p{L})/$1.uc($2)/e;

    my $E="\033"; my $RESET="${E}[0m"; my $BOLD="${E}[1m";
    my $WHITE ="${E}[38;2;245;246;250m";   # role text
    my $GREY  ="${E}[38;2;158;162;172m";   # vitals / activity counters
    my $PATHC ="${E}[38;2;124;138;162m";   # place path
    my $ACTIVE="${E}[38;2;217;119;87m";    # active border/rail — terracotta
    my $INACTIVE="${E}[38;2;58;69;92m";    # inactive border/rail — muted

    my $TL = "\x{E87E}"; my $TR = "┐"; my $BL = "└"; my $BR = "\x{E881}";
    my $VBAR = "│"; my $SEPL = "├"; my $SEPR = "┤";
    my $BRANCHG = "↱";

    my $NARROW_THRESHOLD = 60;
    my $narrow = $W < $NARROW_THRESHOLD;

    sub rail_char { my ($a)=@_; return $a ? "═" : "─"; }
    sub colorize  { my ($t,$rgb,$bold)=@_; return (($bold?$BOLD:"").$rgb.$t.$RESET); }

    sub top_border {
      my ($width,$active,$glyph,$sid)=@_;
      my $r = rail_char($active);
      my $n = $width - (7 + length($sid)); $n = 0 if $n < 0;
      my $rgb = $active ? $ACTIVE : $INACTIVE;
      my $rail_run = $r." ".$glyph." ".$sid." ".($r x $n);
      return $TL.colorize($rail_run,$rgb,0).$TR;
    }
    sub bottom_border {
      my ($width,$active)=@_;
      my $r=rail_char($active); my $rgb=$active?$ACTIVE:$INACTIVE;
      return $BL.colorize($r x ($width-2),$rgb,0).$BR;
    }
    sub separator {
      my ($width,$active)=@_;
      my $r=rail_char($active); my $rgb=$active?$ACTIVE:$INACTIVE;
      return $SEPL.colorize($r x ($width-2),$rgb,0).$SEPR;
    }
    sub content_row {
      my ($width,$text,$rgb,$bold)=@_;
      my $body = $width-2;
      my $inner = " ".$text;
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

    # Greedy word-wrap mirroring python textwrap(width=budget, subsequent_indent="  ",
    # break_long_words=False, break_on_hyphens=False): never split a word or a hyphen, only wrap
    # at whitespace; continuation lines carry a literal 2-space indent baked into the string (so
    # content_row own 1-space pad reproduces the reference 3-space hanging indent).
    sub wrap_role {
      my ($text,$width)=@_;
      my $budget = ($width-3)-1; $budget=1 if $budget<1;
      my $cont_budget = $budget-2; $cont_budget=1 if $cont_budget<1;
      my @words = split /\s+/, $text;
      my @lines; my $cur="";
      for my $w (@words) {
        next if $w eq "";
        my $bud = @lines ? $cont_budget : $budget;
        my $cand = $cur eq "" ? $w : "$cur $w";
        if (length($cand) <= $bud) { $cur = $cand; }
        else { push(@lines,$cur) if $cur ne ""; $cur = $w; }
      }
      push(@lines,$cur) if $cur ne "" || !@lines;
      my @out;
      for my $i (0..$#lines) { push @out, ($i==0 ? $lines[$i] : "  ".$lines[$i]); }
      return @out;
    }

    sub build_place_lines {
      my ($entries,$width,$narrow)=@_;
      my $budget_total = $width-3;
      my @lines;
      for my $e (@$entries) {
        my ($name,$branch,$path) = @$e;
        if ($narrow) {
          push @lines, "⌂ $name  $BRANCHG $branch";
          my $pb = $budget_total; $pb=1 if $pb<1;
          push @lines, truncate_path($path,$pb);
        } else {
          my $prefix = "⌂ $name  $BRANCHG $branch  ↳ ";
          my $pb = $budget_total - length($prefix); $pb=1 if $pb<1;
          my $ptext = length($path) <= $pb ? $path : truncate_path($path,$pb);
          my $line = $prefix.$ptext;
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

    my @v1;
    push @v1, "◷ CTX ${ctx}%" if $ctx ne "";
    push @v1, "◴ 5h ${rl5}%" if $rl5 ne "";
    push @v1, "↺ ${eta5}" if $eta5 ne "";
    push @v1, "◴ 7d ${rl7}%" if $rl7 ne "";
    push @v1, "↺ ${day7}" if $day7 ne "";
    my $vitals1 = join("  ", @v1);

    my @v2;
    push @v2, "◆ ${modeldisp}" if $modeldisp ne "";
    push @v2, "↯ ${effort}" if $effort ne "";
    push @v2, $prchip if $prchip ne "";
    my $vitals2 = join("  ", @v2);

    my @act;
    push @act, $agentstok if $agentstok ne "";
    push @act, $wftok if $wftok ne "";
    push @act, $coordtok if $coordtok ne "";
    my $activity = join("  ", @act);
    my $activity_present = ($activity ne "");

    my @role_lines = wrap_role($role, $W);
    my @rows;

    if ($narrow) {
      # "Вузька ширина <60: злиття identity+vitals, з лічильників лише CTX."
      my @merged = @role_lines;
      push @merged, "◷ CTX ${ctx}%" if $ctx ne "";
      push @merged, $activity if $activity_present;
      my $merged_active = $busy;
      my @place_lines = build_place_lines(\@entries, $W, 1);

      push @rows, top_border($W, $merged_active, $glyph, $sid);
      for my $ln (@merged) {
        if (grep { $_ eq $ln } @role_lines) { push @rows, content_row($W, $ln, $WHITE, 1); }
        else { push @rows, content_row($W, $ln, $GREY, 0); }
      }
      push @rows, separator($W, $merged_active);
      for my $ln (@place_lines) {
        my $rgb = ($ln =~ /^[⌂…\/]/) ? $PATHC : $GREY;
        push @rows, content_row($W, $ln, $rgb, 0);
      }
      push @rows, bottom_border($W, 0);
    } else {
      my @blocks;   # [ \@lines, $active, $kind ]
      push @blocks, [\@role_lines, $busy, "role"];
      my @vlines = grep { $_ ne "" } ($vitals1, $vitals2);
      push @blocks, [\@vlines, 0, "vitals"];
      if ($activity_present) { push @blocks, [[$activity], $busy, "activity"]; }
      my @place_lines = build_place_lines(\@entries, $W, 0);
      push @blocks, [\@place_lines, 0, "place"];

      push @rows, top_border($W, $blocks[0][1], $glyph, $sid);
      for my $bi (0..$#blocks) {
        my ($lines,$active,$kind) = @{$blocks[$bi]};
        for my $ln (@$lines) {
          if    ($kind eq "role")  { push @rows, content_row($W, $ln, $WHITE, 1); }
          elsif ($kind eq "place") {
            my $rgb = ($ln =~ /^[⌂…\/]/) ? $PATHC : $GREY;
            push @rows, content_row($W, $ln, $rgb, 0);
          } else { push @rows, content_row($W, $ln, $GREY, 0); }
        }
        if ($bi < $#blocks) {
          my $next_active = $blocks[$bi+1][1];
          push @rows, separator($W, $active || $next_active);
        }
      }
      push @rows, bottom_border($W, $blocks[-1][1]);
    }

    print join("\n", @rows);
  ' -- "$@"
}

card="$(render_text "$sicon" "${session_id:0:8}" "$busy" "$name" \
  "$ctx" "$rl5" "$eta5" "$rl7" "$day7" "$modeldisp" "$effort" "$prchip" \
  "$agentstok" "$wftok" "$coordtok" ${place_args[@]+"${place_args[@]}"}
)"
printf '%s\n' "$card"
exit 0
