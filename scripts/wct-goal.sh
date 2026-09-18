#!/usr/bin/env bash
# wave-chat-title — get/set the user-defined chat ROLE for the current session.
# Keyed by CLAUDE_CODE_SESSION_ID — the SAME id statusline.sh reads, so whatever is saved here
# the card shows. A user-set value wins over the auto-summary and survives reboots.
#   wct-goal.sh topic "<Слово. уточнення>"   → save / update the role (sanitized, see below)
#   wct-goal.sh get                          → print the current role
#   wct-goal.sh clear                        → remove it (the role falls back to auto)
#
# GAP-007 (2026-09-18): role was saved AND read with zero sanitization — a bad caller (a foreign
# restart script) glued a whole sentence + a "(client, country)" parenthetical + a kebab-slug into
# one 164-char line and force-lowered it (see the case that exposed this: "SEO" → "seo" in
# ~/.claude/wave-chat-title/e4d405e1-7bca-4480-9172-b4a2c81deb05.topic). sanitize_role() below is
# the write-side insurance. It runs ONLY here, on an explicit `topic` call — an interactive
# command, not the ×40-session statusline.sh render path — so a perl subprocess per call is fine.
# It:
#   1. keeps only the FIRST physical line of the input;
#   2. drops a trailing kebab-slug token (pure ASCII lower/digits, 2+ hyphenated parts);
#   3. drops a trailing "(...)" parenthetical (simple, non-nested — matches the defect: a
#      parenthetical stuck to the END of the role; one buried mid-sentence, as in the live 164-char
#      example, is left for the length cap below to deal with);
#   4. caps the result at ~60 chars (word-boundary cut + "…");
#   5. NEVER touches case — the old defect force-lowered "SEO" to "seo", so leaving case alone is
#      deliberate, not an oversight;
#   6. warns (printed after the save line) if anything was cut, or if the result still doesn't
#      look like "Слово. уточнення".
# The ~123 pre-existing *.topic files are legacy data and are NEVER touched by this script —
# sanitization applies only to NEW `topic` calls going forward (no bulk rewrite of legacy files).
set -uo pipefail

sid="${CLAUDE_CODE_SESSION_ID:-}"
if [ -z "$sid" ]; then echo "wct-goal: no CLAUDE_CODE_SESSION_ID in env" >&2; exit 1; fi

dir="$HOME/.claude/wave-chat-title"; mkdir -p "$dir"   # PERSISTENT (TMPDIR gets wiped by macOS)
topic_f="$dir/$sid.topic"

# atomic write (tmp + mv) so statusline.sh never reads a half-written value.
save(){ printf '%s' "$2" > "$1.tmp.$$" && mv "$1.tmp.$$" "$1"; }

# sanitize_role RAW → prints the sanitized value on line 1, then zero or more "WARN\t<message>"
# lines. One perl process per `topic` call — this command is user-driven, not per-render.
sanitize_role() {
  perl -CSA -Mutf8 -e '
    binmode(STDOUT, ":utf8");
    my $raw = shift(@ARGV) // "";
    my @warn;

    my $multiline = ($raw =~ /\r?\n/) ? 1 : 0;
    (my $line = $raw) =~ s/\r?\n.*//s;                       # 1) first physical line only
    push @warn, "багаторядковий ввід — лишено тільки перший рядок" if $multiline;
    $line =~ s/^\s+//; $line =~ s/\s+$//;

    if ($line =~ s/\s+([a-z0-9]+(?:-[a-z0-9]+)+)\s*$//) {    # 2) trailing kebab-slug
      push @warn, "прибрано приклеєний слаг «$1»";
    }
    if ($line =~ s/\s*\(([^()]*)\)\s*$//) {                   # 3) trailing (…) parenthetical
      push @warn, "прибрано хвостову дужку «($1)»";
    }
    $line =~ s/\s+$//;

    push @warn, "рядок не схожий на формат «Слово. уточнення»"
      unless $line =~ /^\S+\.\s+\S/;

    my $CAP = 60;                                             # 4) length cap, ~60 chars
    if (length($line) > $CAP) {
      my $cut = substr($line, 0, $CAP);
      $cut =~ s/\s+\S*$// if $cut =~ /\s/;
      $cut = substr($line, 0, $CAP) if $cut eq "";
      $line = $cut."…";
      push @warn, "довжину обрізано до ~$CAP символів";
    }
    # 5) case is untouched on purpose — no uc/lc anywhere above.

    print "$line\n";
    print "WARN\t$_\n" for @warn;
  ' "$1"
}

case "${1:-}" in
  topic)
    shift
    raw="$*"
    sanitized=""; warnings=()
    {
      IFS= read -r sanitized
      while IFS= read -r _wl; do
        case "$_wl" in WARN$'\t'*) warnings+=("${_wl#WARN$'\t'}") ;; esac
      done
    } < <(sanitize_role "$raw")
    save "$topic_f" "$sanitized"
    echo "✓ роль збережено: $sanitized"
    if [ "${#warnings[@]}" -gt 0 ]; then
      echo "⚠ увага:"
      for w in "${warnings[@]}"; do echo "  - $w"; done
    fi
    ;;
  get)   echo "роль: $( [ -s "$topic_f" ] && cat "$topic_f" || echo '(авто)' )" ;;
  clear) rm -f "$topic_f"; echo "✓ роль очищено (повернеться авто)" ;;
  *)     echo "usage: wct-goal.sh {topic <Слово. уточнення>|get|clear}" >&2; exit 2 ;;
esac
