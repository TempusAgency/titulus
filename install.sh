#!/usr/bin/env bash
# wave-chat-title — post-install wiring.
#
# The HOOKS (Stop summarizer + SessionStart goal-keeper) activate automatically when the
# plugin is enabled. This script wires the ONE piece a plugin cannot self-register: the status
# line (a single global setting, so it must be opted in), plus it seeds the persistent data dir.
#
# Idempotent: safe to run repeatedly. Uses jq (already required by the plugin's hooks). Writes
# settings.json atomically (tmp + mv); backs it up only when the value actually changes.
# NOTE: re-run this after a plugin UPDATE so the stable renderer copy tracks the new version.
set -euo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
DATA="$HOME/.claude/wave-chat-title"
SETTINGS="$HOME/.claude/settings.json"
STATUSLINE_STABLE="$DATA/statusline.sh"   # stable path → survives plugin-cache version churn

# Preflight: check EVERY dependency (bash/perl+Text::Wrap/jq/coreutils) and, for anything missing,
# print the exact install command for this OS. On Windows this is the main gate — Claude Code runs
# the .sh statusline/hooks through Git Bash, which ships bash+perl+coreutils but NOT jq.
if ! bash "$SELF/scripts/doctor.sh"; then
  echo
  echo "! Встанови те, що бракує (команди вище), потім запусти install.sh ще раз."
  exit 1
fi
mkdir -p "$DATA"

# 1) copy the renderer to a stable, version-independent location
cp "$SELF/statusline.sh" "$STATUSLINE_STABLE"
chmod +x "$STATUSLINE_STABLE"

# 2) seed the personal overlay if the user has none yet (never overwrite)
if [ ! -f "$DATA/config.sh" ]; then
  cp "$SELF/config.example.sh" "$DATA/config.sh"
  echo "• seeded personal overlay → $DATA/config.sh (edit to tune)"
fi

# 3) set .statusLine in settings.json, preserving every other key AND any sibling statusLine
#    keys the user set (padding/refreshInterval); seeds refreshInterval:300 (seconds) for new installs
#    — global setting, cost ×(live sessions); floor is 30 per CLAUDE.md. Validate first; back up + write only on change.
tmp="$(mktemp "${TMPDIR:-/tmp}/wct-settings.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

if [ -f "$SETTINGS" ]; then
  jq empty "$SETTINGS" 2>/dev/null || { echo "! $SETTINGS is not valid JSON — fix it by hand, aborting"; exit 1; }
  base="$SETTINGS"
else
  base=/dev/stdin; echo '{}' > "$tmp.base"; base="$tmp.base"
fi

# merge: keep existing statusLine keys, default padding:0 + refreshInterval:300 if none, always set
# our type+command. refreshInterval is in SECONDS (min 1). It is a GLOBAL setting → its cost is
# multiplied by EVERY live session (~35-40 here), so the safe default is 300 (5 min). The card's
# animation is event-driven (it re-renders on each tool call); the interval only governs IDLE
# freshness of the reset countdown / working→idle transition, which doesn't need to be frequent.
# History: refreshInterval=1 (2026-06-07) AND =5 (2026-06-08) BOTH pinned the CPU ×~35 sessions.
# Per ~/.claude/CLAUDE.md the hard floor is now 30 (prefer 300); anything below needs Serg's approval.
# A user-set value still wins (middle object overrides this default).
jq --arg cmd "$STATUSLINE_STABLE" \
   '.statusLine = ({"padding":0,"refreshInterval":300} + (if (.statusLine|type)=="object" then .statusLine else {} end) + {"type":"command","command":$cmd})' \
   "$base" > "$tmp"

if [ -f "$SETTINGS" ] && cmp -s "$SETTINGS" "$tmp"; then
  echo "• statusLine already current — no change"
else
  [ -f "$SETTINGS" ] && cp "$SETTINGS" "$SETTINGS.bak-$(date +%Y%m%d-%H%M%S)-$$"
  prev="$( [ -f "$SETTINGS" ] && jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null || true )"
  [ -n "$prev" ] && [ "$prev" != "$STATUSLINE_STABLE" ] && echo "• NOTE: replaced existing statusLine: $prev"
  mv "$tmp" "$SETTINGS"
  echo "• statusLine → $STATUSLINE_STABLE"
fi
rm -f "$tmp.base" 2>/dev/null || true

echo "✓ wave-chat-title wired. Open a new Claude Code session to see the card."
echo "  Re-run this after updating the plugin. Uninstall the card: remove the \"statusLine\" key from $SETTINGS (or restore a .bak)."
