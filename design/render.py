#!/usr/bin/env python3
"""
render.py — reference renderer for the Titulus launcher card, variant B "Segments".

This reproduces the card layout that was approved for the project after an
intermediate revision had reshuffled it (id moved into the top border, counters
and model merged, movement indicators split into a segment that appeared and
disappeared). That revision was reverted; the layout below is the corrected,
approved one. The SOURCE OF TRUTH is the literal reference frames in
REFERENCE.md. This script must keep reproducing those frames byte-for-byte for
states 1, 2 and 6 — see `--verify`.

This is a DESIGN REFERENCE ONLY. It does not touch statusline.sh; the port
into the production status line script lives there, kept in sync by hand.

Usage:
    python3 render.py                          # print all 7 canonical demo states
    python3 render.py --state 3                # print one canonical state
    python3 render.py --state 6 --width 60 --cut round
    python3 render.py --audit                  # width-gate: 7 states x 2 cut levels x 6 widths
    python3 render.py --verify                 # diff generated output against REFERENCE.md
    python3 render.py --no-color               # force plain text (also respects NO_COLOR env var)
    python3 render.py --layout path/to.conf     # use an alternate layout config (default:
                                                  design/layout.conf, next to this file)

Segments, their order, and which tokens appear in each, are NOT hardcoded here —
they are read from `layout.conf` (see that file's header comment for the format).
statusline.sh (the production status line) reads the SAME file, so editing it
changes both renderers identically. If layout.conf is missing or unparsable,
this script falls back to the built-in default below, which matches the
originally-approved REFERENCE.md layout exactly:
  1. role     — activity glyph + role text (wrapped, hang-indented)
  2. id       — activity glyph + session id + rate/context counters
  3. engine   — model + effort, and on the SAME line any movement indicators
                (agents/workflow/coord) when there is something to show
  4. place    — one row per working directory

The top and bottom border are plain rails — no id, no glyph embedded in them.
"""

import argparse
import os
import re
import sys
import textwrap
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

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
# Static demo representative of the "busy" animation — the live status line
# (statusline.sh) cycles through the full ✦✶✷✸✹✺ frame set once per second;
# this is just the frame used for the fixed reference frames below.
GLYPH_BUSY_DEMO = "✹"
GLYPH_ANIM_FRAMES = ["✦", "✶", "✷", "✸", "✹", "✺"]

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
# Layout config (design/layout.conf) — read by BOTH this renderer and
# statusline.sh. See layout.conf's header comment for the exact format.
# --------------------------------------------------------------------------

DEFAULT_LAYOUT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "layout.conf")

DEFAULT_LAYOUT_ORDER = ["role", "id", "engine", "place"]
DEFAULT_LAYOUT_SEGMENTS: Dict[str, dict] = {
    "role":   {"tokens": ["role"], "narrow_tokens": None, "active": "never", "narrow_layout": "inline"},
    "id":     {"tokens": ["id", "ctx", "rl5", "eta5", "rl7", "eta7"], "narrow_tokens": ["id", "ctx"],
               "active": "never", "narrow_layout": "inline"},
    "engine": {"tokens": ["model", "effort", "pr", "agents", "wf", "coord"], "narrow_tokens": None,
               "active": "busy", "narrow_layout": "inline"},
    "place":  {"tokens": ["dir", "branch", "path"], "narrow_tokens": None, "active": "never",
               "narrow_layout": "split"},
}


def load_layout(path: Optional[str] = None) -> Tuple[List[str], Dict[str, dict]]:
    """Parse layout.conf. Falls back to the built-in default (matching the
    originally-approved REFERENCE.md layout) if the file is missing, empty,
    or doesn't declare an `order:` line."""
    path = path or DEFAULT_LAYOUT_PATH
    order: List[str] = []
    segments: Dict[str, dict] = {}
    cur: Optional[str] = None
    try:
        with open(path, "r", encoding="utf-8") as f:
            raw_lines = f.readlines()
    except OSError:
        raw_lines = []

    for raw in raw_lines:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r"^order:\s*(.+)$", line)
        if m:
            order = m.group(1).split()
            continue
        m = re.match(r"^\[(\w+)\]$", line)
        if m:
            cur = m.group(1)
            segments[cur] = {"tokens": [], "narrow_tokens": None, "active": "never", "narrow_layout": "inline"}
            continue
        if cur is None:
            continue  # directive before any [segment] header — ignore
        m = re.match(r"^tokens:\s*(.*)$", line)
        if m:
            segments[cur]["tokens"] = m.group(1).split()
            continue
        m = re.match(r"^narrow_tokens:\s*(.*)$", line)
        if m:
            segments[cur]["narrow_tokens"] = m.group(1).split()
            continue
        m = re.match(r"^active:\s*(\S+)$", line)
        if m:
            segments[cur]["active"] = m.group(1)
            continue
        m = re.match(r"^narrow_layout:\s*(\S+)$", line)
        if m:
            segments[cur]["narrow_layout"] = m.group(1)
            continue
        # unrecognized directive — ignore (forward-compatible, never crashes the card)

    if not order:
        return list(DEFAULT_LAYOUT_ORDER), {k: dict(v) for k, v in DEFAULT_LAYOUT_SEGMENTS.items()}
    # fill in any segment named in `order:` but missing its own [block] with safe defaults
    for name in order:
        segments.setdefault(name, {"tokens": [], "narrow_tokens": None, "active": "never", "narrow_layout": "inline"})
    return order, segments


LAYOUT_ORDER, LAYOUT_SEGMENTS = load_layout()


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
    busy: bool                     # drives the activity glyph (calm ✻ / busy demo frame)
    # Movement chips, one field per `engine` token in the layout config — kept as separate,
    # already-fully-formatted strings (not a generic list) so the config can reorder or drop
    # them independently, the same way statusline.sh's prchip/agentstok/wftok/coordtok work.
    pr: str = ""
    agents: str = ""
    wf: str = ""
    coord: str = ""
    place: List[PlaceEntry] = field(default_factory=list)
    width: int = 80                # canonical width for the standalone demo print
    cut: str = "round"             # "round" | "none" — canonical cut level for the demo print
    highlight: Optional[bool] = None  # rail double/single override; defaults to `busy` when None.
    # Kept as a separate knob from `busy` for exactly one reason: the byte-exact
    # reference frame (state 2) shows the busy glyph and movement-token content
    # with SINGLE rails (no highlight) — that is the literally approved text.
    # The rail-highlight mechanic itself (double rail when something is truly
    # running) is demonstrated instead by state 3, which is not byte-pinned to
    # any external text. Per the task: "якщо сумніваєшся — пріоритет за
    # структурою еталона, підсвітка вторинна."


SESSION_ID = "093797da"

CTX = "41%"
P5H = "22%"
ETA5H = "1h12m"
P7D = "63%"
ETA7D = "4d"
MODEL = "Opus 5 1M"
EFFORT = "high"

ROLE_ORCH = "Оркестратор. лише запускає агентів, сам не робить"
# Generalized placeholder path — only the trailing path components ever show
# up in a rendered frame (truncate_path() cuts from the left), so the leading
# directory here is a stand-in and does not affect any reference frame below.
COORD_PATH = "/Users/user/Documents/TEMPUSIDIAN Vault 1/Claude Vault/Projects/Titulus/_coord"

# Role for state 5 is intentionally longer than the 160-char cap, so the
# generic truncate_role() below is what produces the "…" — not a hardcoded
# string. Client name is a de-identified placeholder ("exampleclient"), not a
# real client. State 5 is illustrative only, not part of the mandatory
# byte-exact verification set (states 1, 2, 6).
ROLE_EXAMPLECLIENT_RAW = (
    "Rework. seo семантичне ядро exampleclient (клієнт exampleclient professional, "
    "іспанія): продовження кластеризованого ядра + план seo-додатку №2. "
    "exampleclient-seo-semantic-core-v2-professional-spain-cluster-extended-slug-name-for-demo-purposes-only"
)

PLACE_SINGLE = [PlaceEntry("_coord", "—", COORD_PATH)]
PLACE_MULTI = [
    PlaceEntry("_coord", "—", COORD_PATH),
    PlaceEntry("Claude-Artifact-Tempus-1", "main", "/repos/Claude-Artifact-Tempus-1"),
    PlaceEntry("wave-chat-title-plugin", "main", "/repos/wave-chat-title-plugin"),
]

SCENES: List[Scene] = [
    Scene("Стан 1 — спокій", ROLE_ORCH, False, place=PLACE_SINGLE, width=80, cut="round"),
    Scene("Стан 2 — біжать агенти + координаційна пошта (еталонний кадр, без підсвітки рейок)",
          ROLE_ORCH, True, agents="⠹ agents ×1", coord="⇅ coord",
          place=PLACE_SINGLE, width=80, cut="round", highlight=False),
    Scene("Стан 3 — воркфлоу (з підсвіткою рейок)", ROLE_ORCH, True, wf="⚙ wf ×1",
          place=PLACE_SINGLE, width=80, cut="round"),
    Scene("Стан 4 — кілька тек", ROLE_ORCH, False, place=PLACE_MULTI, width=80, cut="round"),
    Scene("Стан 5 — роль на 160+ символів", ROLE_EXAMPLECLIENT_RAW, False,
          place=PLACE_SINGLE, width=80, cut="round"),
    Scene("Стан 6 — 38 колонок, busy", ROLE_ORCH, True, agents="⠹ agents ×1", coord="⇅ coord",
          place=PLACE_SINGLE, width=38, cut="round"),
    Scene("Стан 7 — рівень зрізу none", ROLE_ORCH, False, place=PLACE_SINGLE, width=80, cut="none"),
]

NARROW_THRESHOLD = 60  # "Вузька ширина <60: з лічильників лише CTX."
ROLE_LIMIT = 160        # "Роль обрізається на 160 символів."


# --------------------------------------------------------------------------
# Text helpers
# --------------------------------------------------------------------------

def truncate_role(text: str, limit: int = ROLE_LIMIT) -> str:
    """Rule: 'Роль обрізається на 160 символів.'"""
    if len(text) > limit:
        return text[:limit] + "…"
    return text


def wrap_role(role_text: str, width: int, glyph: str) -> List[str]:
    """
    Word-wrap the role into card body lines, WITH the activity glyph baked
    into the first line ("<glyph> <text>") and a same-width 2-space indent
    baked into every continuation line ("  <text>") — glyph+space and the
    2-space indent are both exactly 2 cells wide, so one wrap budget serves
    both: budget = (width - 3) - 2, where (width - 3) is the max content
    length content_row() can hold (VBAR + 1 leading space + content + VBAR).
    """
    text = truncate_role(role_text)
    budget = max(1, (width - 3) - 2)
    tw = textwrap.TextWrapper(
        width=budget,
        break_long_words=False,
        break_on_hyphens=False,
    )
    lines = tw.wrap(text) or [""]
    out = []
    for i, ln in enumerate(lines):
        out.append((glyph + " " + ln) if i == 0 else ("  " + ln))
    return out


def wrap_tokens(parts, width):
    """
    Greedily pack space-joined tokens (model/effort/movement chips) into as
    few lines as fit `width`, never splitting a token. Used so the engine
    segment degrades gracefully at narrow widths instead of being cut off
    mid-token by content_row's hard ellipsis truncation.
    """
    budget = max(1, width - 3)
    lines = []
    cur = ""
    for p in parts:
        cand = p if cur == "" else cur + "  " + p
        if len(cand) <= budget:
            cur = cand
        else:
            if cur:
                lines.append(cur)
            cur = p
    if cur or not lines:
        lines.append(cur)
    return lines


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


def plain_border(width: int, left: str, right: str, active: bool, color: bool) -> str:
    """Top/bottom border — a plain rail, corner to corner. No id, no glyph:
    those live inside the role/id content segments now, not in the frame."""
    r = rail_char(active)
    rgb = RGB_ACTIVE if active else RGB_INACTIVE
    fill = r * (width - 2)
    line = left + colorize(fill, rgb, enabled=color) + right
    plain_len = 1 + len(fill) + 1
    assert plain_len == width, f"border width mismatch: {plain_len} != {width}"
    return line


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
# Token values — the token catalogue described in layout.conf's header.
# Each function returns "" when the token has no value to show right now
# (e.g. `pr` with no open PR); build_segment_lines() drops empty tokens.
# --------------------------------------------------------------------------

def token_value_id(tok: str, glyph: str) -> str:
    if tok == "id":
        return f"{glyph} {SESSION_ID}"
    if tok == "ctx":
        return f"◷ CTX {CTX}" if CTX else ""
    if tok == "rl5":
        return f"◴ 5h {P5H}" if P5H else ""
    if tok == "eta5":
        return f"↺ {ETA5H}" if ETA5H else ""
    if tok == "rl7":
        return f"◴ 7d {P7D}" if P7D else ""
    if tok == "eta7":
        return f"↺ {ETA7D}" if ETA7D else ""
    return ""


def token_value_engine(tok: str, scene: Scene) -> str:
    if tok == "model":
        return f"◆ {MODEL}" if MODEL else ""
    if tok == "effort":
        return f"↯ {EFFORT}" if EFFORT else ""
    if tok == "pr":
        return scene.pr
    if tok == "agents":
        return scene.agents
    if tok == "wf":
        return scene.wf
    if tok == "coord":
        return scene.coord
    return ""


def token_value_place_lead(tok: str, entry: PlaceEntry) -> str:
    if tok == "dir":
        return f"⌂ {entry.name}"
    if tok == "branch":
        return f"{BRANCH_GLYPH} {entry.branch}"
    return ""


# --------------------------------------------------------------------------
# Segment builders — config-driven
# --------------------------------------------------------------------------

def build_place_lines(entries: List[PlaceEntry], width: int, narrow: bool,
                       tokens: List[str], narrow_layout: str) -> List[str]:
    lines: List[str] = []
    budget_total = width - 3
    has_path = "path" in tokens
    lead_tokens = [t for t in tokens if t != "path"]
    for entry in entries:
        lead_parts = [v for t in lead_tokens if (v := token_value_place_lead(t, entry))]
        lead_str = "  ".join(lead_parts)
        if narrow and narrow_layout == "split" and has_path:
            # icon+branch (etc.) on one line, bare truncated path on its own line, no icon prefix
            lines.append(lead_str)
            path_budget = max(1, budget_total)
            lines.append(truncate_path(entry.path, path_budget))
        elif has_path:
            prefix = (lead_str + "  ↳ ") if lead_str else "↳ "
            path_budget = max(1, budget_total - len(prefix))
            path_text = entry.path if len(entry.path) <= path_budget else truncate_path(entry.path, path_budget)
            line = prefix + path_text
            if len(line) > budget_total:
                line = line[: budget_total - 1] + "…"
            lines.append(line)
        else:
            line = lead_str
            if len(line) > budget_total:
                line = line[: budget_total - 1] + "…"
            lines.append(line)
    return lines


def build_segment_lines(seg_name: str, seg_cfg: dict, width: int, narrow: bool,
                         scene: Scene, glyph: str) -> List[str]:
    tokens = seg_cfg["tokens"]
    if narrow and seg_cfg.get("narrow_tokens") is not None:
        tokens = seg_cfg["narrow_tokens"]

    if seg_name == "role":
        return wrap_role(scene.role, width, glyph)
    if seg_name == "id":
        parts = [v for t in tokens if (v := token_value_id(t, glyph))]
        return ["  ".join(parts)]
    if seg_name == "engine":
        parts = [v for t in tokens if (v := token_value_engine(t, scene))]
        return wrap_tokens(parts, width)
    if seg_name == "place":
        narrow_layout = seg_cfg.get("narrow_layout", "inline")
        return build_place_lines(scene.place, width, narrow, tokens, narrow_layout)
    return []


def segment_active(seg_name: str, seg_cfg: dict, scene: Scene) -> bool:
    if seg_cfg.get("active") != "busy":
        return False
    if seg_name == "engine" and scene.highlight is not None:
        return scene.highlight
    return scene.busy


# --------------------------------------------------------------------------
# Card assembly
# --------------------------------------------------------------------------

def build_card(scene: Scene, width: int, cut: str, color: bool = False,
                layout_order: Optional[List[str]] = None,
                layout_segments: Optional[Dict[str, dict]] = None) -> List[str]:
    order = layout_order if layout_order is not None else LAYOUT_ORDER
    segments = layout_segments if layout_segments is not None else LAYOUT_SEGMENTS

    corners = CUT_ROUND if cut == "round" else CUT_NONE
    tl, tr, bl, br = corners
    narrow = width < NARROW_THRESHOLD
    glyph = GLYPH_BUSY_DEMO if scene.busy else GLYPH_CALM

    # Four segments, always, in the configured order. A separator lights up
    # (double rail) if either segment it sits between is active — so only
    # the rails bordering an "active"-configured segment can ever go double;
    # everything else (including the outer top/bottom borders) stays single.
    blocks: List[Tuple[List[str], bool, str]] = []
    for seg_name in order:
        seg_cfg = segments.get(seg_name, {"tokens": [], "narrow_tokens": None,
                                           "active": "never", "narrow_layout": "inline"})
        lines = build_segment_lines(seg_name, seg_cfg, width, narrow, scene, glyph)
        active = segment_active(seg_name, seg_cfg, scene)
        blocks.append((lines, active, seg_name))

    rows: List[str] = []
    rows.append(plain_border(width, tl, tr, False, color))
    for idx, (lines, active, kind) in enumerate(blocks):
        for ln in lines:
            if kind == "role":
                rows.append(content_row(width, ln, color, rgb=RGB_ROLE_TEXT, bold=True))
            elif kind == "place":
                rgb = RGB_PATH if (ln.startswith("⌂") or ln.startswith("…")) else RGB_COUNTER
                rows.append(content_row(width, ln, color, rgb=rgb))
            else:
                rows.append(content_row(width, ln, color, rgb=RGB_COUNTER))
        if idx < len(blocks) - 1:
            next_active = blocks[idx + 1][1]
            rows.append(separator(width, active or next_active, color))
    rows.append(plain_border(width, bl, br, False, color))
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
    required = {2}  # the one state pinned to literal text handed down in the task
    for state in sorted(blocks.keys()):
        scene = SCENES[state - 1]
        generated = [strip_ansi(l) for l in build_card(scene, scene.width, scene.cut, color=False)]
        expected = blocks[state]
        # The task text uses "/" as a stand-in for the real TempusGlyphs TL/BR
        # codepoints on round-cut frames; state 7 (cut=none) is genuinely
        # square and needs no substitution.
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
    parser.add_argument("--layout", default=None, help="path to layout.conf (default: design/layout.conf)")
    parser.add_argument("--no-color", action="store_true", help="force plain text output")
    args = parser.parse_args()

    color = (not args.no_color) and (os.environ.get("NO_COLOR") is None) and sys.stdout.isatty()

    if args.layout:
        global LAYOUT_ORDER, LAYOUT_SEGMENTS
        LAYOUT_ORDER, LAYOUT_SEGMENTS = load_layout(args.layout)

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
