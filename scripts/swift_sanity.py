#!/usr/bin/env python3
"""Fast Linux-side guard for the iOS code, run before pushing.

There is no Swift compiler for SwiftUI on Linux, so this catches the
mechanical mistakes that would otherwise burn a macOS CI run:

  * bracket balance per Swift file: (), [], {} — ignoring strings (incl.
    multi-line, raw and interpolated strings) and comments (incl. nested)
  * Xcode project integrity: every 24-hex object id referenced in a
    project.pbxproj is defined exactly once; the synchronized root group
    folders and local Swift packages exist; shared schemes reference real
    targets
  * model annotations: every type declaring `CodingKeys` in the app carries
    a `// table: <name>` or `// rpc: <name>` comment directly above it
  * forbidden patterns in app code: PostgREST `.not(` (there is no
    `.not(in:)` — chain `.neq`), `try!`, force-unwrapped `URL(string:)`
    outside Supa.swift, hard-coded colors outside Theme.swift, negative
    frames, types nested inside generic functions, `AnyJSON` without
    `import Supabase`, `safeAreaInset` combined with preference-key
    observers in one file, and `AsyncImage` (a nil URL stays in its
    loading phase forever and an expired signed link has no retry: Storage
    images go through `JobStorageImage`)
  * accessibility: a tone *fill* color (`Theme.amber/success/warning/
    danger`) used as text via `foregroundStyle`/`foregroundColor` (too
    light to read in light mode — use the matching `…Ink` token); white
    `Theme.onAccent` text over a plain fill color (`Theme.glacier/danger/
    success/warning/amber/textTertiary` — white on the dark-mode Glacier is
    3.26:1; use the `…Solid` fill), and Glacier text on a Glacier tint
    (`Theme.fill(for: .info)`, `Theme.glacier.opacity(…)`: 3.85:1 in light
    mode — use `Theme.glacierInk`) or on a white chip (3.26:1 in dark mode —
    use `Theme.glacierSolid`), paired within a few lines; an icon-only
    Button/Menu label with a fixed `.frame(width:height:)` under 44 pt (below
    Apple's minimum, and it does not grow with Dynamic Type — use
    `.iconTapTarget()`); and two
    or more theme buttons side by side in a bare `HStack` (labels
    truncate at accessibility text sizes — use `AdaptiveButtonRow`)
  * Theme contrast: the WCAG ratios of Theme.swift's own values, both
    modes — every text token (`textPrimary/Secondary/Tertiary`, the `…Ink`
    tones) on `background`, `surface`, `surfaceElevated` and
    `surfaceMuted`, and white `onAccent` on every `…Solid` fill — must be
    at least 4.5:1 (WCAG AA for normal text)
  * auth: a `SupabaseClient(` built without `flowType: .implicit` (the
    app's reset/confirmation links open the web app, which can't redeem a
    PKCE code whose verifier is on the phone)
  * row caps: a PostgREST `.limit(N)` literal above the server's 1,000-row
    `max_rows` (the reply is cut short without a word; read a list that
    must be complete with `PagedQuery.all`)
  * auth email links: `auth.signUp(` and `resetPasswordForEmail(` pass
    `redirectTo:` (without it GoTrue links the Site URL root, where the web
    scrubs and refuses link tokens: see `AuthLinks`)
  * edge-function calls: every `functions.invoke(` / `EdgeFunctions.invoke(`
    / `MoneyEdge.invoke(` in app code names its function with a string
    literal, and that function exists (supabase/functions/<name>/index.ts);
    only the wrappers themselves pass their `functionName` parameter on
  * sign-out: app code calls `appState.signOut()` only through
    `ConfirmationRequest.signOut` (SignOutConfirmation.swift, which warns
    about unsent job videos that signing out deletes) or after deleting the
    account (AccountDeletionView.swift)
  * iOS toolchain: the workflows that run Xcode pick it with
    ios/ci/select_xcode.sh (no hard-coded `Xcode_1x` / own `xcode-select`),
    and its MIN_XCODE_MAJOR matches MIN_UPLOAD_SDK_MAJOR in the Fastfile
    (App Store Connect accepts only builds from the current minimum SDK)
  * FEATURE_STUB markers: counted and reported; `--strict` fails if any
    remain

Usage:
  python3 scripts/swift_sanity.py            # check ios/ under the repo root
  python3 scripts/swift_sanity.py --strict   # also fail on FEATURE_STUB
  python3 scripts/swift_sanity.py --self-test
  python3 scripts/swift_sanity.py --root PATH

Exit status is 0 when clean, 1 when any error is found.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

HEX_ID = re.compile(r"\b[0-9A-F]{24}\b")
STUB_MARKER = "FEATURE_STUB"
PAIRS = {")": "(", "]": "[", "}": "{"}
STRING_START = re.compile(r'(#*)("""|")')
OPENERS = set(PAIRS.values())


@dataclass
class Report:
    errors: list[str] = field(default_factory=list)
    stubs: list[str] = field(default_factory=list)
    swift_files: int = 0
    projects: int = 0

    def error(self, path: Path | str, line: int | None, message: str) -> None:
        where = f"{path}:{line}" if line else f"{path}"
        self.errors.append(f"{where}: {message}")


# ---------------------------------------------------------------------------
# Swift lexing
# ---------------------------------------------------------------------------


class LexError(Exception):
    def __init__(self, line: int, message: str) -> None:
        super().__init__(message)
        self.line = line


def code_only(source: str) -> str:
    """Returns `source` with comments removed and string-literal contents
    blanked (quotes kept, interpolated code kept). Newlines are preserved so
    line numbers stay valid. Raises LexError on unterminated constructs."""
    out: list[str] = []
    i = 0
    n = len(source)
    line = 1
    # Stack of contexts. Each entry is ("code", paren_depth) for an
    # interpolation body or top level, or ("string", hashes, multiline).
    stack: list[tuple] = [("code", 0)]

    def emit(ch: str) -> None:
        out.append(ch)

    while i < n:
        ch = source[i]
        top = stack[-1]
        if top[0] == "code":
            if source.startswith("//", i):
                j = source.find("\n", i)
                if j == -1:
                    j = n
                out.append(" " * (j - i))
                i = j
                continue
            if source.startswith("/*", i):
                depth = 1
                start_line = line
                j = i + 2
                while j < n and depth:
                    if source.startswith("/*", j):
                        depth += 1
                        j += 2
                    elif source.startswith("*/", j):
                        depth -= 1
                        j += 2
                    else:
                        j += 1
                if depth:
                    raise LexError(start_line, "unterminated block comment")
                chunk = source[i:j]
                line += chunk.count("\n")
                out.append("".join("\n" if c == "\n" else " " for c in chunk))
                i = j
                continue
            # String start (optionally raw: #"...", ##"..."#, and multi-line).
            # A '#' not followed by a quote (e.g. #available) is plain code.
            m = STRING_START.match(source, i)
            if m:
                hashes = len(m.group(1))
                quote = m.group(2)
                multiline = quote == '"""'
                token = source[i:i + hashes + len(quote)]
                out.append(token)
                i += len(token)
                stack.append(("string", hashes, multiline, line))
                continue
            if ch == "(" and len(stack) > 1:
                stack[-1] = ("code", top[1] + 1)
            elif ch == ")" and len(stack) > 1:
                if top[1] == 0:
                    # End of an interpolation: back into the string.
                    stack.pop()
                    emit(ch)
                    i += 1
                    continue
                stack[-1] = ("code", top[1] - 1)
            if ch == "\n":
                line += 1
            emit(ch)
            i += 1
            continue

        # Inside a string literal.
        _, hashes, multiline, start_line = top
        closing = ('"""' if multiline else '"') + "#" * hashes
        escape = "\\" + "#" * hashes
        if source.startswith(escape + "(", i):
            out.append(escape + "(")
            i += len(escape) + 1
            stack.append(("code", 0))
            continue
        if source.startswith(escape, i) and i + len(escape) < n:
            # Escaped character: blank it (keep newlines).
            nxt = source[i + len(escape)]
            if nxt == "\n":
                line += 1
                out.append(" " * len(escape) + "\n")
            else:
                out.append(" " * (len(escape) + 1))
            i += len(escape) + 1
            continue
        if source.startswith(closing, i):
            out.append(closing)
            i += len(closing)
            stack.pop()
            continue
        if ch == "\n":
            if not multiline:
                raise LexError(start_line, "unterminated string literal")
            line += 1
            out.append("\n")
        else:
            out.append(" ")
        i += 1

    if len(stack) != 1:
        kind = stack[-1]
        if kind[0] == "string":
            raise LexError(kind[3], "unterminated string literal")
        raise LexError(line, "unterminated string interpolation")
    return "".join(out)


def check_balance(path: Path, code: str, report: Report) -> None:
    stack: list[tuple[str, int]] = []
    line = 1
    for ch in code:
        if ch == "\n":
            line += 1
        elif ch in OPENERS:
            stack.append((ch, line))
        elif ch in PAIRS:
            if not stack:
                report.error(path, line, f"unmatched '{ch}'")
                return
            opener, open_line = stack.pop()
            if opener != PAIRS[ch]:
                report.error(path, line, f"'{ch}' closes '{opener}' opened on line {open_line}")
                return
    if stack:
        opener, open_line = stack[-1]
        report.error(path, open_line, f"'{opener}' is never closed")


# ---------------------------------------------------------------------------
# Structural checks on code-only text
# ---------------------------------------------------------------------------

TYPE_DECL = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:(?:public|private|fileprivate|internal|open|final|indirect)\s+)*"
    r"(struct|class|enum|actor|extension|protocol)\s+([A-Za-z_][\w.]*)"
)
GENERIC_FUNC = re.compile(r"\bfunc\s+[A-Za-z_]\w*\s*<")
NESTED_TYPE = re.compile(r"^\s*(?:(?:private|fileprivate|public|internal|final)\s+)*(struct|class|enum|actor)\s+\w+")
ANNOTATION = re.compile(r"^\s*//\s*(table|rpc):\s*[a-z_][a-z0-9_]*\s*$")


def check_structure(path: Path, source_lines: list[str], code_lines: list[str], report: Report,
                    is_app: bool) -> None:
    # Track the stack of open braces with what opened them.
    brace_owner: list[tuple[str, int]] = []  # (kind, line_index); kind in type/genericfunc/other
    pending_type: tuple[str, int] | None = None
    pending_generic: int | None = None

    for index, text in enumerate(code_lines):
        decl = TYPE_DECL.match(text)
        if decl:
            pending_type = (decl.group(1), index)
            # A type declared inside a generic function body.
            if any(kind == "genericfunc" for kind, _ in brace_owner) and NESTED_TYPE.match(text):
                report.error(path, index + 1, "type declared inside a generic function (runtime metadata crash risk)")
        if GENERIC_FUNC.search(text):
            pending_generic = index

        if is_app and re.search(r"\benum\s+CodingKeys\b", text):
            owner = next((line for kind, line in reversed(brace_owner) if kind == "type"), None)
            if owner is None:
                report.error(path, index + 1, "CodingKeys outside of a type")
            elif not has_annotation(source_lines, owner):
                report.error(path, owner + 1,
                             "Codable model with CodingKeys needs a '// table: <name>' or "
                             "'// rpc: <name>' comment directly above it")

        for ch in text:
            if ch == "{":
                if pending_type is not None:
                    brace_owner.append(("type", pending_type[1]))
                    pending_type = None
                    pending_generic = None
                elif pending_generic is not None:
                    brace_owner.append(("genericfunc", pending_generic))
                    pending_generic = None
                else:
                    brace_owner.append(("other", index))
            elif ch == "}":
                if brace_owner:
                    brace_owner.pop()


def has_annotation(source_lines: list[str], decl_index: int) -> bool:
    """True when the comment block directly above the declaration (doc
    comments and attributes may sit in between) holds a table/rpc tag."""
    i = decl_index - 1
    while i >= 0:
        text = source_lines[i].strip()
        if ANNOTATION.match(source_lines[i]):
            return True
        if text.startswith("///") or text.startswith("@") or (text.startswith("//") and not text.startswith("// MARK")):
            i -= 1
            continue
        return False
    return False


FORBIDDEN = [
    (re.compile(r"\.not\("), "PostgREST has no .not(in:) — use chained .neq(...) filters"),
    (re.compile(r"\btry!"), "'try!' is not allowed in app code — handle the error"),
    (re.compile(r"\.frame\([^)]*\b(?:width|height|minWidth|minHeight|maxWidth|maxHeight)\s*:\s*-\s*\d"),
     "negative frame size"),
    (re.compile(r"\bAsyncImage\s*[({]"),
     "AsyncImage stays 'loading' forever for a nil URL and can't re-sign an expired Storage link — "
     "use JobStorageImage (sign, retry, visible failure)"),
]
FILL_AS_TEXT = re.compile(r"\.foreground(?:Style|Color)\(.*\bTheme\.(amber|success|warning|danger)\b")
INK_FOR = {"amber": "moneyInk", "success": "successInk", "warning": "warningInk", "danger": "dangerInk"}
URL_FORCE = re.compile(r"URL\(string:[^)]*\)\s*!")
# Text/background pairs that fail WCAG AA 4.5:1 (Theme.swift values): the
# foreground is set by .foregroundStyle/.foregroundColor, the background by
# a .fill(...) or .background(...) a few lines away in the same chain.
FOREGROUND_CALL = re.compile(r"\.foreground(?:Style|Color)\((.*)")
BACKGROUND_CALL = re.compile(r"\.(?:fill|background)\((.*)")
THEME_TOKEN = re.compile(
    r"Theme\.fill\(for:\s*\.(\w+)\)|Theme\.accent\(for:\s*\.(\w+)\)(\.opacity\()?|Theme\.(\w+)(\.opacity\()?")
TONE_FILL = {"info": "glacier", "success": "success", "warning": "warning", "danger": "danger", "money": "amber",
             "neutral": "textSecondary"}
PAIR_WINDOW = 8
# (text token, background token) -> the fix
BAD_PAIRS = {
    **{("onAccent", fill): f"white text on Theme.{fill} fails contrast (3.1-4.4:1) — fill with Theme.{fix}"
       for fill, fix in (("glacier", "glacierSolid"), ("danger", "dangerSolid"), ("success", "successSolid"),
                         ("warning", "a darker solid token"), ("amber", "Theme.onAmber text"),
                         ("textTertiary", "neutralSolid"), ("textSecondary", "neutralSolid"))},
    ("glacier", "tint:glacier"): "Glacier text on a Glacier tint is 3.85:1 — use Theme.glacierInk",
    ("glacier", "onAccent"): "Glacier text on a white fill is 3.26:1 in dark mode — use Theme.glacierSolid",
}


# An icon-only control's label sized with a fixed small square.
FIXED_FRAME = re.compile(r"\.frame\(\s*width:\s*(\d+(?:\.\d+)?)\s*,\s*height:\s*(\d+(?:\.\d+)?)\s*\)")
CONTROL_LABEL = re.compile(r"label:\s*\{|\bButton\s*(?:\(|\{)")
MIN_TAP = 44


def check_icon_targets(path: Path, code_lines: list[str], report: Report) -> None:
    for index, text in enumerate(code_lines):
        match = FIXED_FRAME.search(text)
        if not match or (float(match.group(1)) >= MIN_TAP and float(match.group(2)) >= MIN_TAP):
            continue
        icon = "\n".join(code_lines[max(0, index - 3):index + 1])
        control = "\n".join(code_lines[max(0, index - 6):index + 1])
        if "Image(systemName:" in icon and CONTROL_LABEL.search(control):
            report.error(path, index + 1, f"icon-only control with a fixed {match.group(1)}x{match.group(2)} pt hit "
                                          f"area (under {MIN_TAP} pt, and it does not grow with Dynamic Type) — "
                                          "use .iconTapTarget()")


def theme_tokens(text: str) -> set[str]:
    """Theme colors named in `text`; tints (a fill at an opacity) as `tint:<fill>`."""
    tokens: set[str] = set()
    for tone_fill, accent, accent_opacity, name, opacity in THEME_TOKEN.findall(text):
        if tone_fill:
            tokens.add("tint:" + TONE_FILL.get(tone_fill, tone_fill))
        elif accent:
            base = TONE_FILL.get(accent, accent)
            tokens.add(("tint:" if accent_opacity else "") + base)
        elif name:
            tokens.add(("tint:" if opacity else "") + name)
    return tokens


def check_contrast_pairs(path: Path, code_lines: list[str], report: Report) -> None:
    backgrounds: list[set[str]] = []
    for text in code_lines:
        found: set[str] = set()
        for match in BACKGROUND_CALL.finditer(text):
            found |= theme_tokens(match.group(1))
        backgrounds.append(found)
    for index, text in enumerate(code_lines):
        match = FOREGROUND_CALL.search(text)
        if not match:
            continue
        foreground = theme_tokens(match.group(1))
        if not foreground:
            continue
        nearby: set[str] = set()
        for other in range(max(0, index - PAIR_WINDOW), min(len(code_lines), index + PAIR_WINDOW + 1)):
            nearby |= backgrounds[other]
        for fg in sorted(foreground):
            for bg in sorted(nearby):
                message = BAD_PAIRS.get((fg, bg))
                if message:
                    report.error(path, index + 1, message)
HARD_COLOR = re.compile(r"\b(?:UIColor|Color)\((?:red:|white:|hue:|\.sRGB|light:|hex:)")

# ---------------------------------------------------------------------------
# Theme contrast (computed from Theme.swift's own values)
# ---------------------------------------------------------------------------

THEME_COLOR = re.compile(r"static\s+let\s+(\w+)\s*=\s*Color\(\s*light:\s*0x([0-9A-Fa-f]{6})\s*,\s*dark:\s*0x([0-9A-Fa-f]{6})\s*\)")
THEME_ENUM = re.compile(r"^\s*enum\s+Theme\b", re.M)
THEME_WHITE = re.compile(r"static\s+let\s+(\w+)\s*=\s*Color\.white\b")
MIN_TEXT_CONTRAST = 4.5
TEXT_SURFACES = ("background", "surface", "surfaceElevated", "surfaceMuted")
TEXT_TOKENS = ("textPrimary", "textSecondary", "textTertiary",
               "moneyInk", "successInk", "warningInk", "dangerInk", "glacierInk")
SOLID_FILLS = ("glacierSolid", "dangerSolid", "successSolid", "neutralSolid")
# (text token, background token): each must reach MIN_TEXT_CONTRAST in both modes.
REQUIRED_CONTRAST = [(text, surface) for text in TEXT_TOKENS for surface in TEXT_SURFACES] + \
                    [("onAccent", fill) for fill in SOLID_FILLS]


def relative_luminance(rgb: int) -> float:
    def channel(value: int) -> float:
        c = value / 255
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF
    return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)


def contrast_ratio(first: int, second: int) -> float:
    """WCAG 2.x contrast ratio of two sRGB colors (1.0 … 21.0)."""
    a, b = relative_luminance(first), relative_luminance(second)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)


def theme_colors(source_lines: list[str]) -> dict[str, tuple[int, int, int]]:
    """token -> (light, dark, line) for `Color(light: 0x…, dark: 0x…)` and `Color.white` tokens."""
    colors: dict[str, tuple[int, int, int]] = {}
    for index, text in enumerate(source_lines):
        match = THEME_COLOR.search(text)
        if match:
            colors[match.group(1)] = (int(match.group(2), 16), int(match.group(3), 16), index + 1)
            continue
        white = THEME_WHITE.search(text)
        if white:
            colors[white.group(1)] = (0xFFFFFF, 0xFFFFFF, index + 1)
    return colors


def check_theme_contrast(path: Path, source_lines: list[str], report: Report) -> None:
    colors = theme_colors(source_lines)
    for text, background in REQUIRED_CONTRAST:
        if text not in colors or background not in colors:
            report.error(path, None, f"contrast check: Theme.{text} or Theme.{background} is not a "
                                     "`Color(light: 0x…, dark: 0x…)` token — keep both readable here")
            continue
        fg, bg = colors[text], colors[background]
        for mode, index in (("light", 0), ("dark", 1)):
            ratio = contrast_ratio(fg[index], bg[index])
            if ratio < MIN_TEXT_CONTRAST:
                report.error(path, fg[2], f"Theme.{text} on Theme.{background} is {ratio:.2f}:1 in {mode} mode "
                                          f"(#{fg[index]:06X} on #{bg[index]:06X}) — needs {MIN_TEXT_CONTRAST}:1")


def check_forbidden(path: Path, code_lines: list[str], source: str, report: Report) -> None:
    name = path.name
    for index, text in enumerate(code_lines):
        for pattern, message in FORBIDDEN:
            if pattern.search(text):
                report.error(path, index + 1, message)
        if URL_FORCE.search(text) and name != "Supa.swift":
            report.error(path, index + 1, "force-unwrapped URL(string:) — build URLs with guard/URLComponents")
        if HARD_COLOR.search(text) and name != "Theme.swift":
            report.error(path, index + 1, "hard-coded color — add a token to Theme.swift instead")
        fill = FILL_AS_TEXT.search(text)
        if fill and name != "Theme.swift":
            report.error(path, index + 1, f"Theme.{fill.group(1)} is a fill color and fails contrast as text — "
                                          f"use Theme.{INK_FOR[fill.group(1)]}")
    if name != "Theme.swift":
        check_contrast_pairs(path, code_lines, report)
        check_icon_targets(path, code_lines, report)
    code = "\n".join(code_lines)
    if re.search(r"\bSupabaseClient\(", code) and not re.search(r"\bflowType:\s*\.implicit\b", code):
        report.error(path, None, "SupabaseClient built without `flowType: .implicit` — password-reset and "
                                 "confirmation links open the web app, which can't redeem a PKCE code")
    check_button_rows(path, code, report)
    check_row_caps(path, code, report)
    check_auth_links(path, code, report)
    if re.search(r"\bAnyJSON\b", code) and not re.search(r"^\s*import\s+Supabase\b", source, re.M):
        report.error(path, None, "uses AnyJSON without 'import Supabase'")
    if ".safeAreaInset(" in code and "onPreferenceChange" in code:
        report.error(path, None, "safeAreaInset combined with preference-key observation "
                                 "(state-driven layout loop risk) — restructure")


# PostgREST returns at most `max_rows` rows per request (1,000 on hosted
# Supabase and in supabase/config.toml) and says nothing when it cuts one.
SERVER_MAX_ROWS = 1000
LIMIT_LITERAL = re.compile(r"\.limit\(\s*([0-9][0-9_]*)\s*\)")


def check_row_caps(path: Path, code: str, report: Report) -> None:
    for match in LIMIT_LITERAL.finditer(code):
        value = int(match.group(1).replace("_", ""))
        if value > SERVER_MAX_ROWS:
            line = code.count("\n", 0, match.start()) + 1
            report.error(path, line, f".limit({value}) is above the server's {SERVER_MAX_ROWS}-row cap, which "
                                     "truncates the reply silently — page with PagedQuery.all")


AUTH_EMAIL_CALL = re.compile(r"\b(?:auth\.signUp|resetPasswordForEmail)\(")


def call_arguments(code: str, open_index: int) -> str:
    """Text between the `(` at `open_index - 1` and its matching `)`."""
    depth, index = 1, open_index
    while depth and index < len(code):
        if code[index] == "(":
            depth += 1
        elif code[index] == ")":
            depth -= 1
        index += 1
    return code[open_index:index - 1]


def check_auth_links(path: Path, code: str, report: Report) -> None:
    """Auth emails from the app must link a web page that accepts their
    tokens (AuthLinks); the Site URL root scrubs and refuses them."""
    for match in AUTH_EMAIL_CALL.finditer(code):
        if not re.search(r"\bredirectTo\s*:", call_arguments(code, match.end())):
            line = code.count("\n", 0, match.start()) + 1
            report.error(path, line, "auth email without `redirectTo:` links the Site URL root, where the web "
                                     "refuses link tokens — pass AuthLinks.signUpConfirmation / passwordReset")


SIGN_OUT_CALL = re.compile(r"\bappState\.signOut\(\)")
SIGN_OUT_ALLOWED = {"SignOutConfirmation.swift", "AccountDeletionView.swift"}


def check_sign_out(path: Path, code_lines: list[str], report: Report) -> None:
    if path.name in SIGN_OUT_ALLOWED:
        return
    for index, text in enumerate(code_lines):
        if SIGN_OUT_CALL.search(text):
            report.error(path, index + 1, "sign out through `confirmation = .signOut(appState)` — it warns about "
                                          "unsent job videos, which signing out deletes")


HSTACK_OPEN = re.compile(r"\bHStack\b[^{\n]*\{")
THEME_BUTTON = re.compile(r"\.buttonStyle\(\.theme(?:Primary|Money|Secondary|Destructive)")


def check_button_rows(path: Path, code: str, report: Report) -> None:
    """Two or more filled/outlined theme buttons directly side by side in an
    HStack truncate at accessibility text sizes; AdaptiveButtonRow stacks
    them instead. `code` has strings blanked, so braces are structural."""
    for match in HSTACK_OPEN.finditer(code):
        depth, index = 1, match.end()
        while depth and index < len(code):
            if code[index] == "{":
                depth += 1
            elif code[index] == "}":
                depth -= 1
            index += 1
        if len(THEME_BUTTON.findall(code, match.end(), index)) >= 2:
            line = code.count("\n", 0, match.start()) + 1
            report.error(path, line, "theme buttons side by side in an HStack truncate at accessibility "
                                     "text sizes — use AdaptiveButtonRow")


EDGE_INVOKE = re.compile(r"\b(?:functions|EdgeFunctions|MoneyEdge)\.invoke\(\s*")
EDGE_LITERAL = re.compile(r'"([A-Za-z0-9_-]+)"')
EDGE_IDENT = re.compile(r"[A-Za-z_]\w*")
# The wrappers forward their own parameter; every caller passes a literal.
EDGE_WRAPPER_PARAM = "functionName"


def check_edge_calls(path: Path, code: str, source: str, report: Report, functions_dir: Path | None) -> None:
    """Edge-function names must be literals naming an existing function."""
    if len(code) != len(source):
        return  # positions differ (never expected): nothing reliable to check
    for match in EDGE_INVOKE.finditer(code):
        start = match.end()
        line = code.count("\n", 0, start) + 1
        if code.startswith('"', start):
            literal = EDGE_LITERAL.match(source, start)
            if not literal:
                report.error(path, line, "edge function name must be a plain string literal")
                continue
            name = literal.group(1)
            if functions_dir is not None and not (functions_dir / name / "index.ts").is_file():
                report.error(path, line, f"edge function '{name}' does not exist (supabase/functions/{name}/index.ts)")
            continue
        ident = EDGE_IDENT.match(code, start)
        if ident and ident.group(0) == EDGE_WRAPPER_PARAM:
            continue
        report.error(path, line, "edge function name chosen at run time — pass a string literal so it can be checked")


CG_GEOMETRY = re.compile(r"\bCG(?:Size|Point|Rect|Vector|AffineTransform)\b")
CG_IMPORT = re.compile(r"^\s*(?:@_exported\s+)?import\s+(?:CoreGraphics|SwiftUI|UIKit)\b", re.M)


def check_coregraphics_import(path: Path, code: str, report: Report) -> None:
    """On Apple platforms `import Foundation` exposes the bare CGSize/CGPoint/CGRect
    structs but not the CoreGraphics overlay (`.zero`, `CGRect(x:y:width:height:)`),
    so such a file fails in Xcode while the Linux harness (whose Foundation defines
    them) passes. Require CoreGraphics (or SwiftUI/UIKit, which re-export it)."""
    match = CG_GEOMETRY.search(code)
    if match and not CG_IMPORT.search(code):
        line = code.count("\n", 0, match.start()) + 1
        report.error(path, line, f"{match.group(0)} used without `import CoreGraphics` (wrap it in "
                     "`#if canImport(CoreGraphics)` for DetailCore) — Foundation alone lacks .zero and "
                     "the CGRect(x:y:width:height:) initialisers on macOS/iOS")


def check_swift_file(path: Path, report: Report, is_app: bool, functions_dir: Path | None = None) -> None:
    report.swift_files += 1
    source = path.read_text(encoding="utf-8")
    if STUB_MARKER in source:
        report.stubs.append(str(path))
    try:
        code = code_only(source)
    except LexError as exc:
        report.error(path, exc.line, str(exc))
        return
    check_balance(path, code, report)
    code_lines = code.split("\n")
    source_lines = source.split("\n")
    check_structure(path, source_lines, code_lines, report, is_app)
    check_coregraphics_import(path, code, report)
    if is_app:
        check_forbidden(path, code_lines, source, report)
        check_sign_out(path, code_lines, report)
        check_edge_calls(path, code, source, report, functions_dir)
        if path.name == "Theme.swift" and THEME_ENUM.search(code):
            check_theme_contrast(path, source_lines, report)


# ---------------------------------------------------------------------------
# iOS toolchain (workflows + Fastfile)
# ---------------------------------------------------------------------------

OLD_XCODE_GLOB = re.compile(r"Xcode_1\d")
XCODE_SELECT = re.compile(r"\bxcode-select\s+(?:-s|--switch)\b")
USES_XCODE = re.compile(r"\b(?:xcodebuild|xcode-select|fastlane|select_xcode\.sh)\b")
MIN_XCODE = re.compile(r"^MIN_XCODE_MAJOR=\"\$\{MIN_XCODE_MAJOR:-(\d+)\}\"", re.M)
MIN_SDK = re.compile(r"^MIN_UPLOAD_SDK_MAJOR\s*=\s*(\d+)\s*$", re.M)


def check_toolchain(root: Path, report: Report) -> None:
    workflows = root / ".github" / "workflows"
    if workflows.is_dir():
        for path in sorted(workflows.glob("*.y*ml")):
            text = path.read_text(encoding="utf-8")
            if not USES_XCODE.search(text):
                continue
            for index, line in enumerate(text.split("\n")):
                if line.lstrip().startswith("#"):
                    continue
                if OLD_XCODE_GLOB.search(line):
                    report.error(path, index + 1, "selects an Xcode older than 26 — App Store Connect rejects "
                                                  "builds from older SDKs; use ios/ci/select_xcode.sh")
                elif XCODE_SELECT.search(line):
                    report.error(path, index + 1, "selects Xcode itself — use ios/ci/select_xcode.sh (the "
                                                  "minimum-SDK choice shared by the iOS workflows)")
            if "xcodebuild" in text or "fastlane" in text:
                if "select_xcode.sh" not in text:
                    report.error(path, None, "runs Xcode without ios/ci/select_xcode.sh (the runner's default "
                                             "Xcode may be older than App Store Connect's minimum SDK)")
    script = root / "ios" / "ci" / "select_xcode.sh"
    fastfile = root / "ios" / "fastlane" / "Fastfile"
    if script.is_file() and fastfile.is_file():
        xcode = MIN_XCODE.search(script.read_text(encoding="utf-8"))
        sdk = MIN_SDK.search(fastfile.read_text(encoding="utf-8"))
        if not xcode:
            report.error(script, None, "MIN_XCODE_MAJOR default not found")
        if not sdk:
            report.error(fastfile, None, "MIN_UPLOAD_SDK_MAJOR not found")
        if xcode and sdk and xcode.group(1) != sdk.group(1):
            report.error(fastfile, None, f"MIN_UPLOAD_SDK_MAJOR {sdk.group(1)} differs from MIN_XCODE_MAJOR "
                                         f"{xcode.group(1)} in ios/ci/select_xcode.sh — raise them together")


# ---------------------------------------------------------------------------
# Xcode project checks
# ---------------------------------------------------------------------------

def strip_pbx_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"^\s*//.*$", "", text, flags=re.M)


def brace_depths(text: str) -> list[int]:
    """Nesting depth of `{}`/`()` at each character, ignoring quoted strings.
    The opening brace itself reports the outer depth."""
    depths = [0] * (len(text) + 1)
    depth = 0
    in_string = False
    escaped = False
    for index, ch in enumerate(text):
        depths[index] = depth
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch in "({":
            depth += 1
        elif ch in ")}":
            depth -= 1
    depths[len(text)] = depth
    return depths


def check_pbxproj(path: Path, report: Report) -> None:
    report.projects += 1
    raw = path.read_text(encoding="utf-8")
    if not raw.startswith("// !$*UTF8*$!"):
        report.error(path, 1, "missing '// !$*UTF8*$!' header")
    text = strip_pbx_comments(raw)

    # Balance of {} and () outside quoted strings.
    stack: list[tuple[str, int]] = []
    line = 1
    in_string = False
    escaped = False
    for ch in text:
        if ch == "\n":
            line += 1
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch in "({":
            stack.append((ch, line))
        elif ch in ")}":
            if not stack or stack[-1][0] != {")": "(", "}": "{"}[ch]:
                report.error(path, line, f"unbalanced '{ch}'")
                return
            stack.pop()
    if stack:
        report.error(path, stack[-1][1], f"'{stack[-1][0]}' is never closed")
        return

    # Object definitions are the `ID = {` entries directly inside
    # `objects = { ... }` (the same pattern also appears as dictionary keys,
    # e.g. TargetAttributes, which are references, not definitions).
    depth_at = brace_depths(text)
    objects = re.search(r"\bobjects\s*=\s*\{", text)
    objects_depth = depth_at[objects.end() - 1] + 1 if objects else 1
    definitions: dict[str, int] = {}
    for m in re.finditer(r"^\s*([0-9A-F]{24})\s*=\s*\{", text, flags=re.M):
        if depth_at[m.start(1)] == objects_depth:
            definitions[m.group(1)] = definitions.get(m.group(1), 0) + 1
    if not objects:
        report.error(path, None, "missing 'objects' section")
    for object_id, count in definitions.items():
        if count > 1:
            report.error(path, None, f"object id {object_id} is defined {count} times")
    referenced = set(HEX_ID.findall(text))
    for object_id in sorted(referenced - set(definitions)):
        report.error(path, None, f"object id {object_id} is referenced but never defined")
    root = re.search(r"rootObject\s*=\s*([0-9A-F]{24})", text)
    if not root:
        report.error(path, None, "missing rootObject")
    elif root.group(1) not in definitions:
        report.error(path, None, "rootObject is not defined")

    if not re.search(r"objectVersion\s*=\s*\d+;", text):
        report.error(path, None, "missing objectVersion")

    project_dir = path.parent.parent
    for m in re.finditer(r"isa = PBXFileSystemSynchronizedRootGroup;.*?path = ([^;]+);", text, flags=re.S):
        folder = project_dir / m.group(1).strip().strip('"')
        if not folder.is_dir():
            report.error(path, None, f"synchronized group folder does not exist: {folder}")
    for m in re.finditer(r"isa = XCLocalSwiftPackageReference;\s*relativePath = ([^;]+);", text):
        package = project_dir / m.group(1).strip().strip('"')
        if not (package / "Package.swift").is_file():
            report.error(path, None, f"local Swift package not found: {package}")

    targets = set(re.findall(r"([0-9A-F]{24})\s*=\s*\{\s*isa = PBXNativeTarget;", text))
    schemes_dir = path.parent / "xcshareddata" / "xcschemes"
    if schemes_dir.is_dir():
        for scheme in sorted(schemes_dir.glob("*.xcscheme")):
            for blueprint in re.findall(r'BlueprintIdentifier = "([0-9A-F]{24})"',
                                        scheme.read_text(encoding="utf-8")):
                if blueprint not in targets:
                    report.error(scheme, None, f"scheme references unknown target {blueprint}")


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

def run(root: Path) -> Report:
    report = Report()
    ios = root / "ios"
    if not ios.is_dir():
        report.error(ios, None, "ios/ directory not found")
        return report
    functions_dir = root / "supabase" / "functions"
    for path in sorted(ios.rglob("*.swift")):
        parts = set(path.parts)
        if ".build" in parts or "DerivedData" in parts or "SourcePackages" in parts:
            continue
        is_app = "DetailCore" not in parts and "Package.swift" != path.name
        check_swift_file(path, report, is_app, functions_dir if functions_dir.is_dir() else None)
    for path in sorted(ios.rglob("project.pbxproj")):
        check_pbxproj(path, report)
    check_toolchain(root, report)
    return report


def print_report(report: Report, root: Path, strict: bool) -> int:
    def rel(text: str) -> str:
        return text.replace(str(root) + os.sep, "")

    for message in report.errors:
        print(f"error: {rel(message)}")
    print(f"FEATURE_STUB markers: {len(report.stubs)} file(s)")
    for stub in report.stubs:
        print(f"  stub: {rel(stub)}")
    failed = bool(report.errors) or (strict and report.stubs)
    if strict and report.stubs:
        print("error: --strict: FEATURE_STUB markers remain")
    status = "FAILED" if failed else "OK"
    print(f"swift_sanity: {status} — {report.swift_files} Swift file(s), {report.projects} project(s), "
          f"{len(report.errors)} error(s)")
    return 1 if failed else 0


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

GOOD_PBX = """// !$*UTF8*$!
{
	archiveVersion = 1;
	objectVersion = 77;
	objects = {
		AAAAAAAAAAAAAAAAAAAAAAA1 /* Project */ = {
			isa = PBXProject;
			attributes = {
				TargetAttributes = {
					AAAAAAAAAAAAAAAAAAAAAAA2 = {
						CreatedOnToolsVersion = 16.0;
					};
				};
			};
			targets = (
				AAAAAAAAAAAAAAAAAAAAAAA2 /* App */,
			);
		};
		AAAAAAAAAAAAAAAAAAAAAAA2 /* App */ = {
			isa = PBXNativeTarget;
			name = "App (x)";
		};
		AAAAAAAAAAAAAAAAAAAAAAA3 /* App */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = App;
		};
	};
	rootObject = AAAAAAAAAAAAAAAAAAAAAAA1 /* Project */;
}
"""


def self_test() -> int:
    failures: list[str] = []

    def expect(name: str, condition: bool) -> None:
        if not condition:
            failures.append(name)

    def run_swift(source: str, filename: str = "Sample.swift", app: bool = True) -> Report:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / filename
            path.write_text(source, encoding="utf-8")
            functions = Path(tmp) / "functions"
            (functions / "payments").mkdir(parents=True)
            (functions / "payments" / "index.ts").write_text("", encoding="utf-8")
            report = Report()
            check_swift_file(path, report, app, functions)
            return report

    # Balanced code with tricky strings/comments.
    ok = run_swift(
        'import Foundation\n'
        'let a = "brace { in string"\n'
        'let b = "interp \\(max(1, (2)))" // comment with ) and }\n'
        '/* block { /* nested ) */ still comment ] */\n'
        'let c = """\n'
        '  multi { line "quoted" \\(a.count) )\n'
        '  """\n'
        'let d = #"raw \\( not interp ) {"#\n'
        'let e = #"raw \\#(a) interp"#\n'
        'let f = "nested \\("inner \\("deep")") ok"\n'
        'if #available(iOS 17, *) { print(a) }\n'
    )
    expect("balanced tricky source passes", not ok.errors)

    expect("missing brace detected", bool(run_swift("struct A {\n  func f() {\n}\n").errors))
    expect("wrong closer detected", bool(run_swift("let x = [1, 2)\n").errors))
    expect("extra closer detected", bool(run_swift("let x = 1)\n").errors))
    expect("unterminated string detected", bool(run_swift('let x = "abc\nlet y = 1\n').errors))
    expect("unterminated comment detected", bool(run_swift("/* open\nlet y = 1\n").errors))

    annotated = run_swift(
        "// table: shops\n"
        "struct Shop: Codable {\n"
        "    var id: UUID\n"
        "    enum CodingKeys: String, CodingKey { case id }\n"
        "}\n"
        "// rpc: shop_team\n"
        "/// Docs are fine in between.\n"
        "struct TeamRow: Codable {\n"
        "    var id: UUID\n"
        "    enum CodingKeys: String, CodingKey { case id }\n"
        "}\n"
    )
    expect("annotated models pass", not annotated.errors)
    missing = run_swift(
        "struct Shop: Codable {\n"
        "    var id: UUID\n"
        "    enum CodingKeys: String, CodingKey { case id }\n"
        "}\n"
    )
    expect("missing model annotation detected", any("table" in e for e in missing.errors))
    expect("DetailCore exempt from annotations",
           not run_swift("struct S: Codable {\n enum CodingKeys: String, CodingKey { case a }\n var a = 1\n}\n",
                         app=False).errors)

    expect(".not( detected", bool(run_swift('let q = query.not("id", operator: .in, value: "(1)")\n').errors))
    expect("'.not(' inside a string ignored", not run_swift('let s = "x.not(y)"\n').errors)
    expect("try! detected", bool(run_swift("let x = try! f()\n").errors))
    expect("URL force unwrap detected", bool(run_swift('let u = URL(string: "https://a.b")!\n').errors))
    expect("URL force unwrap allowed in Supa.swift",
           not run_swift('let u = URL(string: "https://a.b")!\n', filename="Supa.swift").errors)
    expect("hard-coded color detected", bool(run_swift("let c = Color(red: 1, green: 0, blue: 0)\n").errors))
    expect("colors allowed in Theme.swift",
           not run_swift("let c = Color(red: 1, green: 0, blue: 0)\n", filename="Theme.swift").errors)
    expect("negative frame detected", bool(run_swift("let v = x.frame(width: -4)\n").errors))
    expect("AnyJSON without import detected", bool(run_swift("let v: AnyJSON = .null\n").errors))
    expect("AnyJSON with import passes", not run_swift("import Supabase\nlet v: AnyJSON = .null\n").errors)
    expect("safeAreaInset + preference loop detected", bool(run_swift(
        "let v = x.safeAreaInset(edge: .top) { y }.onPreferenceChange(K.self) { z = $0 }\n").errors))
    expect("type in generic function detected", bool(run_swift(
        "func make<T>(_ v: T) -> Int {\n    struct Box { var x = 1 }\n    return Box().x\n}\n").errors))
    expect("type in plain function allowed", not run_swift(
        "func make() -> Int {\n    struct Box { var x = 1 }\n    return Box().x\n}\n").errors)
    expect("known edge function passes", not run_swift(
        'let r: R = try await MoneyEdge.invoke("payments", body: b)\n').errors)
    expect("multi-line edge call passes", not run_swift(
        'let r: R = try await Supa.client.functions.invoke(\n    "payments",\n    options: o\n)\n').errors)
    expect("unknown edge function detected", any("does not exist" in e for e in run_swift(
        'let r: R = try await EdgeFunctions.invoke("nope", body: b)\n').errors))
    expect("run-time edge function name detected", any("run time" in e for e in run_swift(
        'let r: R = try await EdgeFunctions.invoke(name, body: b)\n').errors))
    expect("wrapper parameter allowed", not run_swift(
        'let r: R = try await EdgeFunctions.invoke(functionName, body: body)\n').errors)
    expect("edge call in a comment ignored", not run_swift(
        '// EdgeFunctions.invoke("nope", body: b)\nlet x = 1\n').errors)
    expect("fill color as text detected", any("moneyInk" in e for e in run_swift(
        "let v = Text(a).foregroundStyle(Theme.amber)\n").errors))
    expect("fill color in a ternary foreground detected", bool(run_swift(
        "let v = Text(a).foregroundStyle(late ? Theme.warning : Theme.textSecondary)\n").errors))
    expect("ink token as text passes", not run_swift(
        "let v = Text(a).foregroundStyle(Theme.moneyInk)\n").errors)
    expect("fill color as a fill passes", not run_swift(
        "let v = Circle().fill(Theme.danger)\n").errors)
    expect("fill colors allowed as text inside Theme.swift", not run_swift(
        "let v = Text(a).foregroundStyle(Theme.amber)\n", filename="Theme.swift").errors)
    expect("white text on the plain Glacier fill detected", any("glacierSolid" in e for e in run_swift(
        "let v = Text(a)\n    .foregroundStyle(isOn ? Theme.onAccent : Theme.textPrimary)\n"
        "    .background(RoundedRectangle(cornerRadius: 8).fill(isOn ? Theme.glacier : Theme.surfaceMuted))\n").errors))
    expect("white text on the plain danger fill detected", any("dangerSolid" in e for e in run_swift(
        "let v = Text(a)\n    .foregroundStyle(Theme.onAccent)\n    .frame(width: 20)\n"
        "    .background(Circle().fill(Theme.danger))\n").errors))
    expect("white text on a solid fill passes", not run_swift(
        "let v = Text(a)\n    .foregroundStyle(Theme.onAccent)\n"
        "    .background(Capsule().fill(Theme.glacierSolid))\n").errors)
    expect("Glacier text on a Glacier tint detected", any("glacierInk" in e for e in run_swift(
        "let v = Label(t, systemImage: i)\n    .foregroundStyle(Theme.glacier)\n    .background(\n"
        "        RoundedRectangle(cornerRadius: 4)\n            .fill(Theme.fill(for: .info))\n    )\n").errors))
    expect("Glacier text on an opacity tint detected", any("glacierInk" in e for e in run_swift(
        "let v = Image(systemName: i)\n    .foregroundStyle(Theme.glacier)\n"
        "    .background(Circle().fill(Theme.glacier.opacity(0.12)))\n").errors))
    expect("Glacier ink on a Glacier tint passes", not run_swift(
        "let v = Text(t)\n    .foregroundStyle(Theme.glacierInk)\n    .background(Capsule().fill(Theme.fill(for: .info)))\n").errors)
    expect("Glacier text on a white chip detected", any("glacierSolid" in e for e in run_swift(
        "let v = Text(n)\n    .foregroundStyle(sel ? Theme.glacier : Theme.onAccent)\n"
        "    .background(Capsule().fill(sel ? Theme.onAccent : Theme.dangerSolid))\n").errors))
    expect("far-apart colors are not paired", not run_swift(
        "let v = Text(a).foregroundStyle(Theme.onAccent)\n" + "let x = 1\n" * 12 + "let w = Circle().fill(Theme.glacier)\n").errors)
    expect("contrast pairs allowed inside Theme.swift", not run_swift(
        "let v = Text(a)\n    .foregroundStyle(Theme.onAccent)\n    .background(Capsule().fill(Theme.glacier))\n",
        filename="Theme.swift").errors)
    # Theme contrast computed from the token values.
    expect("WCAG ratio of black on white", abs(contrast_ratio(0x000000, 0xFFFFFF) - 21.0) < 1e-9)
    expect("white on the light danger fill is under AA", 4.43 < contrast_ratio(0xFFFFFF, 0xD93F3F) < 4.45)
    theme_ok = "enum Theme {\n" + "\n".join(
        [f"    static let {name} = Color(light: 0xFFFFFF, dark: 0x0B1220)" for name in TEXT_SURFACES]
        + [f"    static let {name} = Color(light: 0x1F2937, dark: 0xE5E7EB)" for name in TEXT_TOKENS]
        + [f"    static let {name} = Color(light: 0x1F2937, dark: 0x1F2937)" for name in SOLID_FILLS]
        + ["    static let onAccent = Color.white"]) + "\n}\n"
    expect("readable Theme tokens pass", not run_swift(theme_ok, filename="Theme.swift").errors)
    faint = theme_ok.replace("static let textTertiary = Color(light: 0x1F2937, dark: 0xE5E7EB)",
                             "static let textTertiary = Color(light: 0x8491A7, dark: 0x6B7892)")
    faint_errors = run_swift(faint, filename="Theme.swift").errors
    expect("faint tertiary text detected in light mode",
           any("Theme.textTertiary on Theme.surfaceMuted" in e and "light mode" in e for e in faint_errors))
    expect("faint tertiary text detected in dark mode",
           any("Theme.textTertiary on Theme.surface is" in e and "dark mode" in e for e in faint_errors))
    weak_fill = theme_ok.replace("static let dangerSolid = Color(light: 0x1F2937, dark: 0x1F2937)",
                                 "static let dangerSolid = Color(light: 0xD93F3F, dark: 0xF06464)")
    expect("white on a light solid fill detected", any("Theme.onAccent on Theme.dangerSolid" in e for e in run_swift(
        weak_fill, filename="Theme.swift").errors))
    expect("missing Theme token reported", any("not a" in e for e in run_swift(
        theme_ok.replace("    static let onAccent = Color.white\n", ""), filename="Theme.swift").errors))
    expect("contrast values only checked in Theme.swift",
           all("Theme.textTertiary on" not in e for e in run_swift(faint, filename="Other.swift").errors))
    expect("a Theme.swift fragment without the Theme enum is not contrast-checked",
           not run_swift("let v = Text(a)\n", filename="Theme.swift").errors)
    expect("fixed small icon menu label detected", any("iconTapTarget" in e for e in run_swift(
        "let v = Menu {\n    Button(\"Remove\", role: .destructive) { f() }\n} label: {\n"
        "    Image(systemName: \"ellipsis\")\n        .foregroundStyle(Theme.textTertiary)\n"
        "        .frame(width: 32, height: 32)\n        .contentShape(Rectangle())\n}\n").errors))
    expect("fixed small icon button detected", any("iconTapTarget" in e for e in run_swift(
        "let v = Button(action: f) {\n    Image(systemName: \"xmark\")\n        .frame(width: 28, height: 28)\n}\n").errors))
    expect("scaled icon target passes", not run_swift(
        "let v = Menu {\n    Button(\"A\") { f() }\n} label: {\n    Image(systemName: \"ellipsis\")\n"
        "        .iconTapTarget()\n}\n").errors)
    expect("44-pt icon frame passes", not run_swift(
        "let v = Button(action: f) {\n    Image(systemName: \"xmark\")\n        .frame(width: 44, height: 44)\n}\n").errors)
    expect("small decorative icon outside a control passes", not run_swift(
        "let v = HStack {\n    Image(systemName: \"star\")\n        .frame(width: 20, height: 20)\n}\n").errors)
    expect("theme buttons in a bare HStack detected", any("AdaptiveButtonRow" in e for e in run_swift(
        "let v = HStack(spacing: 8) {\n  Button(\"A\") {}\n    .buttonStyle(.themePrimaryCompact)\n"
        "  Button(\"B\") { f() }\n    .buttonStyle(.themeSecondaryCompact)\n}\n").errors))
    expect("theme buttons in AdaptiveButtonRow pass", not run_swift(
        "let v = AdaptiveButtonRow(spacing: 8) {\n  Button(\"A\") {}\n    .buttonStyle(.themePrimaryCompact)\n"
        "  Button(\"B\") {}\n    .buttonStyle(.themeSecondaryCompact)\n}\n").errors)
    expect("one theme button beside plain content passes", not run_swift(
        "let v = HStack {\n  Text(\"x\")\n  Button(\"B\") {}\n    .buttonStyle(.themeSecondaryCompact)\n}\n").errors)
    expect("buttons in sibling HStacks pass", not run_swift(
        "let v = VStack {\n  HStack { Button(\"A\") {}.buttonStyle(.themePrimary) }\n"
        "  HStack { Button(\"B\") {}.buttonStyle(.themeSecondary) }\n}\n").errors)
    expect("PKCE client detected", any("implicit" in e for e in run_swift(
        "let c = SupabaseClient(supabaseURL: u, supabaseKey: k)\n", filename="Supa.swift").errors))
    expect("implicit client passes", not run_swift(
        "let c = SupabaseClient(supabaseURL: u, supabaseKey: k, options: SupabaseClientOptions(\n"
        "    auth: SupabaseClientOptions.AuthOptions(flowType: .implicit)))\n", filename="Supa.swift").errors)
    expect("implicit flow in a comment does not count", bool(run_swift(
        "// flowType: .implicit\nlet c = SupabaseClient(supabaseURL: u, supabaseKey: k)\n",
        filename="Supa.swift").errors))
    expect("limit above the row cap detected", any("row cap" in e for e in run_swift(
        'let q = Supa.client.from("service_prices").select("*").limit(10000)\n').errors))
    expect("limit with separators above the cap detected", any("row cap" in e for e in run_swift(
        "let q = query.limit(2_000)\n").errors))
    expect("limit at the cap passes", not run_swift("let q = query.limit(1000)\n").errors)
    expect("limit from a variable passes", not run_swift("let q = query.limit(pageSize)\n").errors)
    expect("limit in a string ignored", not run_swift('let s = ".limit(10000)"\n').errors)
    expect("sign-up without redirectTo detected", any("redirectTo" in e for e in run_swift(
        "let r = try await Supa.client.auth.signUp(\n    email: e,\n    password: p,\n"
        "    data: [\"full_name\": .string(n)]\n)\n").errors))
    expect("sign-up with redirectTo passes", not run_swift(
        "let r = try await Supa.client.auth.signUp(\n    email: e,\n    password: p,\n"
        "    redirectTo: AuthLinks.signUpConfirmation(webAppBase: AppConfig.webAppURL)\n)\n").errors)
    expect("password reset without redirectTo detected", any("redirectTo" in e for e in run_swift(
        "try await Supa.client.auth.resetPasswordForEmail(normalized(email))\n").errors))
    expect("password reset with redirectTo passes", not run_swift(
        "try await Supa.client.auth.resetPasswordForEmail(\n    e,\n    redirectTo: AuthLinks.passwordReset(webAppBase: b)\n)\n").errors)
    expect("redirectTo of a later call does not count", bool(run_swift(
        "try await Supa.client.auth.signUp(email: e, password: p)\nf(redirectTo: x)\n").errors))
    expect("direct sign-out detected", any("signOut(appState)" in e for e in run_swift(
        "let b = Button(\"Sign out\") { Task { await appState.signOut() } }\n").errors))
    expect("sign-out in SignOutConfirmation.swift allowed", not run_swift(
        "func f() async { await appState.signOut() }\n", filename="SignOutConfirmation.swift").errors)
    expect("sign-out after account deletion allowed", not run_swift(
        "func f() async { await appState.signOut() }\n", filename="AccountDeletionView.swift").errors)
    expect("confirmed sign-out passes", not run_swift("let b = Button(\"x\") { confirmation = .signOut(appState) }\n").errors)
    expect("CGSize without CoreGraphics detected", any("CoreGraphics" in e for e in run_swift(
        "import Foundation\nfunc f() -> CGSize { .zero }\n", app=False).errors))
    expect("CGRect with canImport(CoreGraphics) passes", not run_swift(
        "import Foundation\n#if canImport(CoreGraphics)\nimport CoreGraphics\n#endif\nlet r = CGRect(x: 0, y: 0, width: 1, height: 1)\n", app=False).errors)
    expect("CGPoint under SwiftUI passes", not run_swift("import SwiftUI\nlet p = CGPoint.zero\n").errors)
    expect("CGFloat alone needs no CoreGraphics", not run_swift("import Foundation\nlet w: CGFloat = 2\n", app=False).errors)
    expect("AsyncImage detected", any("AsyncImage" in e for e in run_swift(
        "var body: some View { AsyncImage(url: item.url) { image in image } placeholder: { ProgressView() } }\n").errors))
    expect("AsyncImage in a comment ignored", not run_swift("// AsyncImage(url:) never fails for nil\nlet x = 1\n").errors)
    expect("JobStorageImage passes", not run_swift(
        "var body: some View { JobStorageImage(bucket: b, path: p, initialURL: u, noun: \"photo\") { phase, retry in Text(\"x\") } }\n").errors)

    def run_toolchain(workflow: str, script_min: str = "26", fastfile_min: str = "26") -> Report:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".github" / "workflows").mkdir(parents=True)
            (root / ".github" / "workflows" / "ios.yml").write_text(workflow, encoding="utf-8")
            (root / "ios" / "ci").mkdir(parents=True)
            (root / "ios" / "ci" / "select_xcode.sh").write_text(
                f'MIN_XCODE_MAJOR="${{MIN_XCODE_MAJOR:-{script_min}}}"\n', encoding="utf-8")
            (root / "ios" / "fastlane").mkdir(parents=True)
            (root / "ios" / "fastlane" / "Fastfile").write_text(
                f"MIN_UPLOAD_SDK_MAJOR = {fastfile_min}\n", encoding="utf-8")
            report = Report()
            check_toolchain(root, report)
            return report

    good_wf = "jobs:\n  b:\n    steps:\n      - run: bash ios/ci/select_xcode.sh\n      - run: xcodebuild build\n"
    expect("shared Xcode selection passes", not run_toolchain(good_wf).errors)
    expect("Xcode 16 glob detected", any("older than 26" in e for e in run_toolchain(
        good_wf + "      - run: XCODE=$(ls -d /Applications/Xcode_16*.app | tail -1)\n").errors))
    expect("own xcode-select detected", any("select_xcode.sh" in e for e in run_toolchain(
        good_wf + "      - run: sudo xcode-select -s /Applications/Xcode.app\n").errors))
    expect("xcodebuild without the selection detected", any("without" in e for e in run_toolchain(
        "jobs:\n  b:\n    steps:\n      - run: xcodebuild build\n").errors))
    expect("workflow without Xcode ignored", not run_toolchain("jobs:\n  b:\n    steps:\n      - run: npm test\n").errors)
    expect("commented Xcode 16 ignored", not run_toolchain(good_wf + "      # was Xcode_16*.app\n").errors)
    expect("minimum mismatch detected", any("raise them together" in e for e in run_toolchain(good_wf, "27", "26").errors))

    stub = run_swift("// FEATURE_STUB: later\nstruct V {}\n")
    expect("stub counted", len(stub.stubs) == 1 and not stub.errors)

    with tempfile.TemporaryDirectory() as tmp:
        proj = Path(tmp) / "App.xcodeproj"
        proj.mkdir()
        (Path(tmp) / "App").mkdir()
        pbx = proj / "project.pbxproj"
        pbx.write_text(GOOD_PBX, encoding="utf-8")
        report = Report()
        check_pbxproj(pbx, report)
        expect("valid pbxproj passes", not report.errors)

        pbx.write_text(GOOD_PBX.replace("AAAAAAAAAAAAAAAAAAAAAAA2 /* App */,",
                                        "AAAAAAAAAAAAAAAAAAAAAAA9 /* Missing */,"), encoding="utf-8")
        report = Report()
        check_pbxproj(pbx, report)
        expect("undefined pbxproj id detected", any("never defined" in e for e in report.errors))

        pbx.write_text(GOOD_PBX.replace("\t\tAAAAAAAAAAAAAAAAAAAAAAA3 /* App */ = {",
                                        "\t\tAAAAAAAAAAAAAAAAAAAAAAA2 /* Dup */ = {"), encoding="utf-8")
        report = Report()
        check_pbxproj(pbx, report)
        expect("duplicate pbxproj id detected", any("defined 2 times" in e for e in report.errors))

        pbx.write_text(GOOD_PBX.replace("rootObject", "};\nrootObject"), encoding="utf-8")
        report = Report()
        check_pbxproj(pbx, report)
        expect("unbalanced pbxproj detected", bool(report.errors))

        pbx.write_text(GOOD_PBX.replace("path = App;", "path = Nope;"), encoding="utf-8")
        report = Report()
        check_pbxproj(pbx, report)
        expect("missing synchronized folder detected", any("does not exist" in e for e in report.errors))

    if failures:
        for name in failures:
            print(f"self-test FAILED: {name}")
        return 1
    print("swift_sanity self-test: all checks passed")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent,
                        help="repository root (default: parent of scripts/)")
    parser.add_argument("--strict", action="store_true", help="fail when FEATURE_STUB markers remain")
    parser.add_argument("--self-test", action="store_true", help="run the script's own tests")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    root = args.root.resolve()
    return print_report(run(root), root, args.strict)


if __name__ == "__main__":
    sys.exit(main())
