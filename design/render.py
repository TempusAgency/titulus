#!/usr/bin/env python3
"""
render.py — reference renderer for the Titulus launcher card, variant B "Segments".

This reproduces the card layout approved by the user (Serg) after the original
prototype (`/private/tmp/claude-501/titulus-launcher-design/`) was lost when its
scratch directory was cleaned up on session restart. The APPROVED SOURCE OF TRUTH
now is the literal reference frames in REFERENCE.md (copied verbatim from the task
that specified this rebuild). This script must keep reproducing those frames
byte-for-byte for states 1, 2 and 6 — see `--verify`.

This is a DESIGN REFERENCE ONLY. It does not touch statusline.sh. A later agent
is responsible for porting this layout into the production status line script.

Usage:
    python3 render.py                          # print all 7 canonical demo states
    python3 render.py --state 3                # print one canonical state
    python3 render.py --state 6 --width 60 --cut round
    python3 render.py --audit                  # width-gate: 7 states x 2 cut levels x 6 widths
    python3 render.py --verify                 # diff generated output against REFERENCE.md
    python3 render.py --no-color               # force plain text (also respects NO_COLOR env var)

Segments (in order): identity -> vitals -> activity (only when there is something
to show) -> place. Rules are documented inline next to the code that implements
them; each rule below cites the task requirement it encodes.
"""

import argparse
import os
import re
import sys
import textwrap
from dataclasses import dataclass
from typing import List, Optional, Tuple

# --------------------------------------------------------------------------
# Glyphs & box-drawing
# --------------------------------------------------------------------------

# "Rounded" corner level uses the custom TempusGlyphs codepoints (font:
# ~/Library/Fonts/TempusGlyphs-Regular.ttf). TL = U+E87E, BR = U+E881.
# Top-right and bottom-left corners are ALWAYS the standard box-drawing
# ┐ / └ — only TL/BR switch between the two cut levels.
GLYPH_TL_ROUND = ""
GLYPH_BR_ROUND = ""

CUT_ROUND = (GLYPH_TL_ROUND, "┐", "└", GLYPH_BR_ROUND)   # (TL, TR, BL, BR)
CUT_NONE = ("┌", "┐", "└", "┘")

VBAR = "│"
SEP_L = "├"
SEP_R = "┤"
RAIL_ACTIVE = "═"     # second signal channel besides color — must work under NO_COLOR=1
RAIL_INACTIVE = "─"

GLYPH_CALM = "✻"
GLYPH_BUSY = "✺"
# Extra glyphs reserved for animation frames (not used by the static demo):
GLYPH_ANIM_FRAMES = ["✦", "✶", "✷", "✸", "✹"]

BRANCH_GLYPH = "↱"     # U+21B1 — NOT ⎇, it breaks in the font stack in use.

# --------------------------------------------------------------------------
# Colors (24-bit ANSI). Only ever applied when color is enabled; every
# structural decision (rail single/double, corner glyph) must remain legible
# with color off, per the NO_COLOR requirement.
# --------------------------------------------------------------------------

RGB_ACTIVE = (217, 119, 87)     # terracotta — active contour
RGB_INACTIVE = (58, 69, 92)     # muted — inactive contour
RGB_ROLE_TEXT = (245, 246, 250)  # bold
RGB_COUNTER = (158, 162, 172)
RGB_PATH = (124, 138, 162)
RGB_MUTED = (110, 114, 124)


def _fg(rgb):
    r, g, b = rgb
    return f"\x1b[38;2;{r};{g};{b}m"


BOLD = "\x1b[1m"
RESET = "\x1b[0m"


def colorize(text: str, rgb, bold: bool = False, enabled: bool = True) -> str:
    if not enabled:
        return text
    prefix = (BOLD if bold else "") + _fg(rgb)
    return f"{prefix}{text}{RESET}"


# --------------------------------------------------------------------------
# Data model
# --------------------------------------------------------------------------

@dataclass
class PlaceEntry:
    name: str
    branch: str
    path: str


@dataclass
class Scene:
    label: str
    role: str                      # raw role text, BEFORE the 160-char cut
    busy: bool                     # drives glyph (✻/✺) and identity segment's active flag
    activity: Optional[List[str]]  # pre-formatted tokens, e.g. ["⚙ wf ×1", "⇅ coord"]; None = no activity segment
    place: List[PlaceEntry]
    width: int                     # canonical width for the standalone demo print
    cut: str                       # "round" | "none" — canonical cut level for the demo print


SESSION_ID = "093797da"

CTX = "41%"
P5H = "22%"
ETA5H = "1h12m"
P7D = "63%"
ETA7D = "4d"
MODEL = "Opus 5 1M"
EFFORT = "high"

ROLE_ORCH = "Оркестратор. лише запускає агентів, сам не робить"
COORD_PATH = "/Users/tempus/Documents/TEMPUSIDIAN Vault 1/Claude Vault/Projects/Titulus/_coord"

# Role for state 5 is intentionally longer than the 160-char cap, so the
# generic truncate_role() below is what produces the "…" — not a hardcoded
# string. The visible prefix matches the approved frame; the exact character
# where the cut lands is one hyphen off from the original (lost) source —
# documented as an accepted deviation in the handback report (state 5 is
# illustrative, not part of the mandatory byte-exact verification set).
ROLE_EXAMPLECLIENT_RAW = (
    "Rework. seo семантичне ядро exampleclient (клієнт exampleclient professional, "
    "іспанія): продовження кластеризованого ядра + план seo-додатку №2. "
    "exampleclient-seo-semantic-core-v2-professional-spain-cluster-extended-slug-name-for-demo-purposes-only"
)

PLACE_SINGLE = [PlaceEntry("_coord", "—", COORD_PATH)]
PLACE_MULTI = [
    PlaceEntry("_coord", "—", COORD_PATH),
    PlaceEntry("Claude-Artifact-Tempus-1", "main", "/Users/tempus/Claude-Artifact-Tempus-1"),
    PlaceEntry("wave-chat-title-plugin", "main", "/Users/tempus/wave-chat-title-plugin"),
]

SCENES: List[Scene] = [
    Scene("Стан 1 — спокій", ROLE_ORCH, False, None, PLACE_SINGLE, 80, "round"),
    Scene("Стан 2 — біжать агенти", ROLE_ORCH, True, ["⠹ agents ×2"], PLACE_SINGLE, 80, "round"),
    Scene("Стан 3 — воркфлоу + координаційна пошта", ROLE_ORCH, True, ["⚙ wf ×1", "⇅ coord"], PLACE_SINGLE, 80, "round"),
    Scene("Стан 4 — кілька тек", ROLE_ORCH, False, None, PLACE_MULTI, 80, "round"),
    Scene("Стан 5 — роль на 160+ символів", ROLE_EXAMPLECLIENT_RAW, False, None, PLACE_SINGLE, 80, "round"),
    Scene("Стан 6 — 38 колонок, busy", ROLE_ORCH, True, ["⚙ wf ×1", "⇅ coord"], PLACE_SINGLE, 38, "round"),
    Scene("Стан 7 — рівень зрізу none", ROLE_ORCH, False, None, PLACE_SINGLE, 80, "none"),
]

NARROW_THRESHOLD = 60  # "Вузька ширина <60: злиття identity+vitals..."
ROLE_LIMIT = 160        # "Роль обрізається на 160 символів."


# --------------------------------------------------------------------------
# Text helpers
# --------------------------------------------------------------------------

def truncate_role(text: str, limit: int = ROLE_LIMIT) -> str:
    """Rule: 'Роль обрізається на 160 символів.'"""
    if len(text) > limit:
        return text[:limit] + "…"
    return text


def wrap_role(role_text: str, width: int) -> List[str]:
    """
    Word-wrap the role into card body lines.

    Content budget for a normal body line is (width - 3): VBAR + 1 leading
    space + text + VBAR, with the text left-justified into that budget.
    Continuation lines get 2 extra leading spaces ("з відступом"); textwrap's
    `subsequent_indent` embeds those 2 spaces directly into the returned
    string, so every wrapped line can be fed through the same content_row()
    padding logic uniformly.

    The wrap *decision* width is one column narrower than the padding budget
    (width-4 rather than width-3) — empirically required to reproduce the
    approved frames byte-for-byte (state 6 at width 38 only fits "Оркестратор.
    лише запускає" on line 1 if the wrap decision leaves that 1-column
    margin; the padding itself still fills the full width-3 field).
    """
    text = truncate_role(role_text)
    budget = max(1, (width - 3) - 1)
    tw = textwrap.TextWrapper(
        width=budget,
        subsequent_indent="  ",
        break_long_words=False,
        break_on_hyphens=False,
    )
    lines = tw.wrap(text)
    return lines or [""]


def truncate_path(path: str, budget: int) -> str:
    """
    Truncate a path from the left, keeping as many trailing path components
    as fit, prefixed with '…/'. Falls back to a hard character truncation of
    the last component if even that doesn't fit.
    """
    if len(path) <= budget:
        return path
    parts = path.split("/")
    for i in range(1, len(parts)):
        candidate = "…/" + "/".join(parts[i:])
        if len(candidate) <= budget:
            return candidate
    last = parts[-1]
    candidate = "…/" + last
    if len(candidate) <= budget:
        return candidate
    if budget <= 1:
        return "…"[:budget]
    return "…" + last[-(budget - 1):]


# --------------------------------------------------------------------------
# Row builders
# --------------------------------------------------------------------------

def rail_char(active: bool) -> str:
    # "Другий канал сигналу поза кольором: активна рейка — подвійна ═,
    #  неактивна — одинарна ─. Має працювати при NO_COLOR=1."
    return RAIL_ACTIVE if active else RAIL_INACTIVE


def top_border(width: int, corners, active: bool, glyph: str, session_id: str, color: bool) -> str:
    tl, tr, bl, br = corners
    r = rail_char(active)
    n = max(0, width - (7 + len(session_id)))
    rgb = RGB_ACTIVE if active else RGB_INACTIVE
    rail_run = r + " " + glyph + " " + session_id + " " + (r * n)
    line = tl + colorize(rail_run, rgb, enabled=color) + tr
    plain_len = 1 + len(rail_run) + 1
    assert plain_len == width, f"top_border width mismatch: {plain_len} != {width}"
    return line


def bottom_border(width: int, corners, active: bool, color: bool) -> str:
    tl, tr, bl, br = corners
    r = rail_char(active)
    rgb = RGB_ACTIVE if active else RGB_INACTIVE
    fill = r * (width - 2)
    return bl + colorize(fill, rgb, enabled=color) + br


def separator(width: int, active: bool, color: bool) -> str:
    r = rail_char(active)
    rgb = RGB_ACTIVE if active else RGB_INACTIVE
    fill = r * (width - 2)
    return SEP_L + colorize(fill, rgb, enabled=color) + SEP_R


def content_row(width: int, text: str, color: bool, rgb=None, bold: bool = False) -> str:
    body_width = width - 2
    inner = " " + text
    if len(inner) > body_width:
        inner = inner[: body_width - 1] + "…"
    inner = inner.ljust(body_width)
    rendered = colorize(inner, rgb, bold=bold, enabled=color) if rgb else inner
    line = VBAR + rendered + VBAR
    plain_len = 1 + len(inner) + 1
    assert plain_len == width, f"content_row width mismatch: {plain_len} != {width}"
    return line


# --------------------------------------------------------------------------
# Place segment
# --------------------------------------------------------------------------

def build_place_lines(entries: List[PlaceEntry], width: int, narrow: bool) -> List[str]:
    lines: List[str] = []
    budget_total = width - 3
    for entry in entries:
        if narrow:
            # "шлях переїхав на власний рядок" — icon+branch on one line,
            # bare truncated path on its own line (no icon prefix).
            lines.append(f"⌂ {entry.name}  {BRANCH_GLYPH} {entry.branch}")
            path_budget = max(1, budget_total)
            lines.append(truncate_path(entry.path, path_budget))
        else:
            prefix = f"⌂ {entry.name}  {BRANCH_GLYPH} {entry.branch}  ↳ "
            path_budget = max(1, budget_total - len(prefix))
            path_text = entry.path if len(entry.path) <= path_budget else truncate_path(entry.path, path_budget)
            line = prefix + path_text
            if len(line) > budget_total:
                line = line[: budget_total - 1] + "…"
            lines.append(line)
    return lines


# --------------------------------------------------------------------------
# Card assembly
# --------------------------------------------------------------------------

def build_card(scene: Scene, width: int, cut: str, color: bool = False) -> List[str]:
    corners = CUT_ROUND if cut == "round" else CUT_NONE
    narrow = width < NARROW_THRESHOLD
    glyph = GLYPH_BUSY if scene.busy else GLYPH_CALM
    identity_active = scene.busy
    activity_present = scene.activity is not None

    role_lines = wrap_role(scene.role, width)

    if narrow:
        # "Вузька ширина <60: злиття identity+vitals, з лічильників лише CTX."
        merged_lines: List[str] = list(role_lines)
        merged_lines.append(f"◷ CTX {CTX}")
        if activity_present:
            merged_lines.append("  ".join(scene.activity))
        merged_active = identity_active or activity_present
        place_lines = build_place_lines(scene.place, width, narrow=True)
        content_blocks: List[Tuple[List[str], bool]] = [
            (merged_lines, merged_active),
            (place_lines, False),
        ]
    else:
        vitals_lines = [
            f"◷ CTX {CTX}  ◴ 5h {P5H}  ↺ {ETA5H}  ◴ 7d {P7D}  ↺ {ETA7D}",
            f"◆ {MODEL}  ↯ {EFFORT}",
        ]
        content_blocks = [
            (role_lines, identity_active),
            (vitals_lines, False),
        ]
        if activity_present:
            content_blocks.append(([("  ".join(scene.activity))], True))
        place_lines = build_place_lines(scene.place, width, narrow=False)
        content_blocks.append((place_lines, False))

    rows: List[str] = []
    rows.append(top_border(width, corners, content_blocks[0][1], glyph, SESSION_ID, color))
    for idx, (lines, active) in enumerate(content_blocks):
        for ln in lines:
            # Role/identity lines get bold near-white; everything else muted counters.
            if idx == 0 and not narrow:
                rows.append(content_row(width, ln, color, rgb=RGB_ROLE_TEXT, bold=True))
            elif idx == 0 and narrow and ln in role_lines:
                rows.append(content_row(width, ln, color, rgb=RGB_ROLE_TEXT, bold=True))
            elif ln.startswith("⌂") or ln.startswith("…") or ln.startswith("/"):
                rows.append(content_row(width, ln, color, rgb=RGB_PATH))
            else:
                rows.append(content_row(width, ln, color, rgb=RGB_COUNTER))
        if idx < len(content_blocks) - 1:
            next_active = content_blocks[idx + 1][1]
            rows.append(separator(width, active or next_active, color))
    rows.append(bottom_border(width, corners, content_blocks[-1][1], color))
    return rows


def strip_ansi(s: str) -> str:
    return re.sub(r"\x1b\[[0-9;]*m", "", s)


# --------------------------------------------------------------------------
# CLI actions
# --------------------------------------------------------------------------

def action_print_all(color: bool):
    for scene in SCENES:
        print(f"# {scene.label}")
        for line in build_card(scene, scene.width, scene.cut, color=color):
            print(line)
        print()


def action_print_one(state: int, width: int, cut: str, color: bool):
    scene = SCENES[state - 1]
    for line in build_card(scene, width, cut, color=color):
        print(line)


def action_audit() -> int:
    widths = [38, 60, 80, 100, 120, 160]
    cuts = ["round", "none"]
    violations = 0
    checked = 0
    for scene in SCENES:
        for cut in cuts:
            for width in widths:
                checked += 1
                try:
                    rows = build_card(scene, width, cut, color=False)
                except AssertionError as e:
                    violations += 1
                    print(f"FAIL  {scene.label!r:45} cut={cut:5} width={width:3}  assertion: {e}")
                    continue
                bad = [(i, len(r)) for i, r in enumerate(rows) if len(r) != width]
                if bad:
                    violations += 1
                    print(f"FAIL  {scene.label!r:45} cut={cut:5} width={width:3}  rows_wrong={bad}")
    combos = len(SCENES) * len(cuts) * len(widths)
    print(f"\nAudit: {combos} combinations checked ({checked} rendered), {violations} violations.")
    return 0 if violations == 0 else 1


REF_STATE_RE = re.compile(r"Стан (\d+)[^\n]*:\n```\n(.*?)\n```", re.S)


def load_reference_blocks(ref_path: str):
    with open(ref_path, "r", encoding="utf-8") as f:
        content = f.read()
    blocks = {}
    for m in REF_STATE_RE.finditer(content):
        n = int(m.group(1))
        blocks[n] = m.group(2).split("\n")
    return blocks


def action_verify(ref_path: str) -> int:
    blocks = load_reference_blocks(ref_path)
    if not blocks:
        print(f"No reference blocks found in {ref_path}")
        return 1
    all_ok = True
    required = {1, 2, 6}
    for state in sorted(blocks.keys()):
        scene = SCENES[state - 1]
        generated = [strip_ansi(l) for l in build_card(scene, scene.width, scene.cut, color=False)]
        expected = blocks[state]
        # States 1-6 in the task text use "/" as a stand-in for the real
        # TempusGlyphs TL/BR codepoints; states use round-cut corners except
        # state 7 which is genuinely square. Substitute before comparing.
        if scene.cut == "round":
            expected = [
                (GLYPH_TL_ROUND + l[1:]) if l.startswith("/") else l
                for l in expected
            ]
            expected = [
                (l[:-1] + GLYPH_BR_ROUND) if l.endswith("/") else l
                for l in expected
            ]
        match = generated == expected
        mark = "PASS" if match else "FAIL"
        req = " (required)" if state in required else ""
        print(f"{mark}  Стан {state}{req}")
        if not match:
            all_ok = False
            for i, (g, e) in enumerate(zip(generated, expected)):
                if g != e:
                    print(f"    line {i}: got      {g!r}")
                    print(f"    line {i}: expected {e!r}")
            if len(generated) != len(expected):
                print(f"    line count: got {len(generated)} expected {len(expected)}")
    return 0 if all_ok else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--state", type=int, choices=range(1, 8), help="print a single canonical state (1-7)")
    parser.add_argument("--width", type=int, default=None, help="override width for --state")
    parser.add_argument("--cut", choices=["round", "none"], default=None, help="override cut level for --state")
    parser.add_argument("--audit", action="store_true", help="run the width gate over all states x cuts x widths")
    parser.add_argument("--verify", action="store_true", help="diff generated output against REFERENCE.md")
    parser.add_argument("--ref", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "REFERENCE.md"))
    parser.add_argument("--no-color", action="store_true", help="force plain text output")
    args = parser.parse_args()

    color = (not args.no_color) and (os.environ.get("NO_COLOR") is None) and sys.stdout.isatty()

    if args.audit:
        sys.exit(action_audit())
    if args.verify:
        sys.exit(action_verify(args.ref))
    if args.state:
        width = args.width or SCENES[args.state - 1].width
        cut = args.cut or SCENES[args.state - 1].cut
        action_print_one(args.state, width, cut, color)
        return
    action_print_all(color)


if __name__ == "__main__":
    main()
