#!/usr/bin/env python3
"""Contract checker for Detail CRM (SPEC section 8.2).

Verifies that every database name the clients use exists in the live schema
with a matching name — and, for the app surfaces, that the PostgREST role can
actually use it:

  * freshness: web/src/lib/database.types.ts and docs/SCHEMA.md equal what
    scripts/gen_types.py generates from the same schema (so web's typed
    client, which tsc checks, sees the real schema);
  * web (web/src, typed) and edge functions (supabase/functions, untyped):
    `.from('<table>')` chains — the table/view, every column named in
    `.select(...)` (including embedded resources, which must be joinable by
    exactly one foreign key unless a `!hint` picks one), filters (`.eq`,
    `.in`, `.or(...)`, `.order`, ...), `.insert/.update/.upsert` object
    keys and `onConflict` columns; `.rpc('<fn>', { args })` — the function,
    its argument names and a matching overload; `.storage.from('<bucket>')`;
    `functions.invoke('<name>')` targets an existing edge function;
  * iOS (ios/DetailCRM): the same chains in Swift (`.eq("col", value:)`,
    `.select(Model.selectColumns)`, `params: Params(p_x: ...)` or
    `["p_x": ...]`, encodable payload structs), every `// table: <name>`
    model's CodingKeys and `selectColumns`, non-optional properties that
    `selectColumns` would leave undecodable, every `// rpc: <name>` model's
    function, and Swift `String` enums whose snake_case name is a Postgres
    enum (raw values must be labels of that enum);
  * privileges (web + iOS run as `authenticated`/`anon`): selected, filtered,
    inserted and updated columns need the matching table- or column-level
    grant for `authenticated`; deleted tables need DELETE; RPCs need EXECUTE
    for `anon` or `authenticated` (edge functions: any API role).

Client directories that do not exist yet (or are empty) are simply not
scanned. Swift models annotated `// table:` / `// rpc:` without CodingKeys
are checked by their stored property names (synthesized Codable keys).

Names built at run time (a table or RPC name held in a variable, a select
list with interpolated parts) cannot be verified statically; they are counted
and listed with --verbose, never silently treated as verified.

Usage:
  python3 scripts/check_contracts.py              # live schema (throwaway cluster)
  python3 scripts/check_contracts.py --meta F     # schema from gen_types.py --dump-meta F
  python3 scripts/check_contracts.py --pg-env     # an already migrated DB from PGHOST/PGPORT/...
  python3 scripts/check_contracts.py --no-freshness
  python3 scripts/check_contracts.py --verbose
  python3 scripts/check_contracts.py --self-test
Exit status: 0 clean, 1 contract errors, 2 setup failure.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True  # keep scripts/ free of __pycache__
sys.path.insert(0, str(HERE))
import gen_types  # noqa: E402  (same directory)

DEFAULT_REPO = HERE.parent
APP_ROLE = "authenticated"
API_ROLES = ("anon", "authenticated", "service_role")


# ==========================================================================
# Schema model
# ==========================================================================
class Schema:
    def __init__(self, meta: dict):
        rel_kind = {r["name"]: r["kind"] for r in meta["relations"] if r["schema"] == "public"}
        self.relations: dict[str, dict[str, dict]] = {name: {} for name in rel_kind}
        self.rel_kind = rel_kind
        for c in meta["columns"]:
            if c["table"] in self.relations:
                self.relations[c["table"]][c["name"]] = c
        self.enums = {t["name"]: list(t["enums"]) for t in meta["types"] if t["schema"] == "public" and t["enums"]}
        self.composites = {t["name"]: [a["name"] for a in t["attributes"]]
                           for t in meta["types"] if t["schema"] == "public" and t["attributes"]}
        types_by_id = {t["id"]: t for t in meta["types"]}
        rel_by_id = {r["id"]: r["name"] for r in meta["relations"]}
        self.functions: dict[str, list[dict]] = {}
        for f in meta["functions"]:
            if f.get("is_extension_member") or f["return_type"] in ("trigger", "event_trigger"):
                continue
            args = f.get("args_declared") or f.get("args") or []
            in_args = [a for a in args if a["mode"] in ("in", "inout", "variadic")]
            table_cols = [a["name"] for a in args if a["mode"] == "table"]
            out_cols = [a["name"] for a in args if a["mode"] in ("out", "inout")]
            ret_cols = None
            if table_cols:
                ret_cols = table_cols
            elif f.get("return_type_relation_id") and f["return_type_relation_id"] in rel_by_id:
                ret_cols = list(self.relations.get(rel_by_id[f["return_type_relation_id"]], {}))
            elif len(out_cols) > 1:
                ret_cols = out_cols
            else:
                rt = types_by_id.get(f["return_type_id"])
                if rt and rt["schema"] == "public" and rt["attributes"]:
                    ret_cols = [a["name"] for a in rt["attributes"]]
            self.functions.setdefault(f["name"], []).append({
                "args": [(a["name"], bool(a["has_default"])) for a in in_args],
                "returns": f["return_type"],
                "ret_cols": ret_cols,
                "exec": {r for r in API_ROLES if f.get(f"exec_{r}")},
            })
        self.buckets = {b.get("id") for b in meta.get("buckets", [])}
        # foreign keys between public relations (PostgREST embedding)
        self.fks = [r for r in meta["relationships"]
                    if r["schema"] == "public" and r["referenced_schema"] == "public"]
        self.table_priv = {(p["table"], p["role"]): p for p in meta["table_privs"]}
        self.col_priv = {(p["table"], p["role"], p["column"]): p for p in meta["column_privs"]}

    def has_relation(self, name: str) -> bool:
        return name in self.relations

    def columns(self, name: str) -> dict:
        return self.relations.get(name, {})

    def can(self, table: str, role: str, priv: str, column: str | None = None) -> bool:
        """priv in s/i/u/d; column-level grants count for s/i/u."""
        tp = self.table_priv.get((table, role))
        if tp and tp[priv]:
            return True
        if column is None or priv == "d":
            return False
        cp = self.col_priv.get((table, role, column))
        return bool(cp and cp[priv])

    def any_column_priv(self, table: str, role: str, priv: str) -> bool:
        if self.can(table, role, priv):
            return True
        return any(self.can(table, role, priv, c) for c in self.columns(table))


# ==========================================================================
# Findings
# ==========================================================================
@dataclass
class Report:
    errors: list[str] = field(default_factory=list)
    dynamic: list[str] = field(default_factory=list)
    counts: dict = field(default_factory=dict)
    checked_enums: list = field(default_factory=list)

    def error(self, where: str, msg: str) -> None:
        self.errors.append(f"{where}: {msg}")

    def skip(self, where: str, msg: str) -> None:
        self.dynamic.append(f"{where}: {msg}")

    def count(self, key: str, n: int = 1) -> None:
        self.counts[key] = self.counts.get(key, 0) + n


# ==========================================================================
# Tokenizer (TypeScript and Swift)
# ==========================================================================
@dataclass
class Tok:
    kind: str          # id | num | str | p
    val: str           # identifier / punct / number text; for str: literal text (see parts)
    line: int
    parts: list | None = None   # str only: [("s", text) | ("e", expr_text)]


MULTI_PUNCT = ("...", "===", "!==", "?.", "=>", "==", "!=", "<=", ">=", "&&", "||", "??", "::", "->")
REGEX_PREV_PUNCT = set("(,=:[!&|?{};+-*%<>~^") | {"=>", "==", "===", "!=", "!==", "&&", "||", "??", "<=", ">="}
REGEX_PREV_WORDS = {"return", "typeof", "case", "do", "else", "in", "of", "new", "delete", "void", "throw",
                    "yield", "await"}


def tokenize(src: str, lang: str) -> list[Tok]:
    toks: list[Tok] = []
    i, n, line = 0, len(src), 1

    def prev_sig():
        return toks[-1] if toks else None

    while i < n:
        ch = src[i]
        if ch == "\n":
            line += 1
            i += 1
            continue
        if ch in " \t\r\f\v":
            i += 1
            continue
        # comments
        if src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        if src.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if src.startswith("/*", j) and lang == "swift":
                    depth += 1
                    j += 2
                elif src.startswith("*/", j):
                    depth -= 1
                    j += 2
                else:
                    if src[j] == "\n":
                        line += 1
                    j += 1
            i = j
            continue
        # identifiers / numbers
        if ch.isalpha() or ch in "_$" or (lang == "swift" and ch == "@"):
            j = i + 1
            while j < n and (src[j].isalnum() or src[j] in "_$"):
                j += 1
            toks.append(Tok("id", src[i:j], line))
            i = j
            continue
        if ch.isdigit():
            j = i + 1
            while j < n and (src[j].isalnum() or src[j] in "._"):
                j += 1
            toks.append(Tok("num", src[i:j], line))
            i = j
            continue
        # strings
        if lang == "swift" and (ch == '"' or (ch == "#" and re.match(r'#+"', src[i:]))):
            tok, i, line = _swift_string(src, i, line)
            if tok is None:
                i += 1
                continue
            toks.append(tok)
            continue
        if lang == "ts" and ch in "'\"":
            j = i + 1
            buf = []
            ok = False
            while j < n:
                c = src[j]
                if c == "\\" and j + 1 < n:
                    buf.append(_unescape(src[j + 1]))
                    j += 2
                    continue
                if c == "\n":
                    break          # not a JS string (e.g. an apostrophe in JSX text)
                if c == ch:
                    ok = True
                    break
                buf.append(c)
                j += 1
            if ok:
                text = "".join(buf)
                toks.append(Tok("str", text, line, [("s", text)]))
                i = j + 1
            else:
                toks.append(Tok("p", ch, line))
                i += 1
            continue
        if lang == "ts" and ch == "`":
            tok, i, line = _template(src, i, line)
            toks.append(tok)
            continue
        if lang == "ts" and ch == "/":
            p = prev_sig()
            if p is None or (p.kind == "p" and p.val in REGEX_PREV_PUNCT) or (p.kind == "id" and p.val in REGEX_PREV_WORDS):
                j = _regex_end(src, i)
                if j is not None:
                    toks.append(Tok("p", "/regex/", line))
                    i = j
                    continue
        for mp in MULTI_PUNCT:
            if src.startswith(mp, i):
                toks.append(Tok("p", "." if mp == "?." else mp, line))
                i += len(mp)
                break
        else:
            toks.append(Tok("p", ch, line))
            i += 1
    return toks


def _unescape(c: str) -> str:
    return {"n": "\n", "t": "\t", "r": "\r", "0": "\0"}.get(c, c)


def _regex_end(src: str, i: int) -> int | None:
    j, n, in_class = i + 1, len(src), False
    while j < n:
        c = src[j]
        if c == "\n":
            return None
        if c == "\\":
            j += 2
            continue
        if in_class:
            if c == "]":
                in_class = False
        elif c == "[":
            in_class = True
        elif c == "/":
            j += 1
            while j < n and src[j].isalpha():
                j += 1
            return j
        j += 1
    return None


def _template(src: str, i: int, line: int):
    """TS template literal starting at src[i] == '`'."""
    start_line = line
    j, n = i + 1, len(src)
    parts, buf = [], []
    while j < n:
        c = src[j]
        if c == "\\" and j + 1 < n:
            buf.append(_unescape(src[j + 1]))
            j += 2
            continue
        if c == "`":
            j += 1
            break
        if c == "$" and src.startswith("${", j):
            if buf:
                parts.append(("s", "".join(buf)))
                buf = []
            depth, k = 1, j + 2
            while k < n and depth:
                if src[k] == "{":
                    depth += 1
                elif src[k] == "}":
                    depth -= 1
                elif src[k] == "\n":
                    line += 1
                k += 1
            parts.append(("e", src[j + 2:k - 1].strip()))
            j = k
            continue
        if c == "\n":
            line += 1
        buf.append(c)
        j += 1
    if buf:
        parts.append(("s", "".join(buf)))
    text = "".join(p[1] for p in parts if p[0] == "s")
    return Tok("str", text, start_line, parts or [("s", "")]), j, line


def _swift_string(src: str, i: int, line: int):
    m = re.match(r'(#*)("""|")', src[i:])
    if not m:
        return None, i, line
    hashes, quote = m.group(1), m.group(2)
    close = quote + hashes
    interp = "\\" + hashes + "("
    esc = "\\" + hashes
    start_line = line
    j, n = i + len(m.group(0)), len(src)
    parts, buf = [], []
    while j < n:
        if src.startswith(close, j):
            j += len(close)
            break
        if src.startswith(interp, j):
            if buf:
                parts.append(("s", "".join(buf)))
                buf = []
            depth, k = 1, j + len(interp)
            while k < n and depth:
                if src[k] == "(":
                    depth += 1
                elif src[k] == ")":
                    depth -= 1
                elif src[k] == "\n":
                    line += 1
                k += 1
            parts.append(("e", src[j + len(interp):k - 1].strip()))
            j = k
            continue
        if src.startswith(esc, j) and j + len(esc) < n:
            buf.append(_unescape(src[j + len(esc)]))
            j += len(esc) + 1
            continue
        if src[j] == "\n":
            if quote == '"':
                break
            line += 1
        buf.append(src[j])
        j += 1
    if buf:
        parts.append(("s", "".join(buf)))
    if quote == '"""':
        # multi-line literal: drop the newline after the opening delimiter
        if parts and parts[0][0] == "s" and parts[0][1].startswith("\n"):
            parts[0] = ("s", parts[0][1][1:])
    text = "".join(p[1] for p in parts if p[0] == "s")
    return Tok("str", text, start_line, parts or [("s", "")]), j, line


def match_close(toks: list[Tok], i: int) -> int:
    """Index of the bracket closing toks[i] (one of ( [ {), or len(toks)."""
    pairs = {"(": ")", "[": "]", "{": "}"}
    stack = []
    for j in range(i, len(toks)):
        t = toks[j]
        if t.kind != "p":
            continue
        if t.val in pairs:
            stack.append(pairs[t.val])
        elif t.val in (")", "]", "}"):
            if stack and stack[-1] == t.val:
                stack.pop()
                if not stack:
                    return j
            else:
                return j
    return len(toks)


def split_args(toks: list[Tok], open_i: int, close_i: int) -> list[list[Tok]]:
    args, cur, depth = [], [], 0
    for t in toks[open_i + 1:close_i]:
        if t.kind == "p" and t.val in "([{":
            depth += 1
        elif t.kind == "p" and t.val in ")]}":
            depth -= 1
        if t.kind == "p" and t.val == "," and depth == 0:
            args.append(cur)
            cur = []
            continue
        cur.append(t)
    if cur:
        args.append(cur)
    return args


def arg_label(arg: list[Tok]) -> tuple[str | None, list[Tok]]:
    """Swift `label: expr` → (label, expr); otherwise (None, arg)."""
    if len(arg) >= 2 and arg[0].kind == "id" and arg[1].kind == "p" and arg[1].val == ":":
        return arg[0].val, arg[2:]
    return None, arg


# ==========================================================================
# Source files and constant evaluation
# ==========================================================================
UNKNOWN = "\x00"


class SourceFile:
    def __init__(self, path: Path, rel: str, lang: str, surface: str):
        self.path, self.rel, self.lang, self.surface = path, rel, lang, surface
        self.text = path.read_text(encoding="utf-8", errors="replace")
        self.lines = self.text.splitlines()
        self.toks = tokenize(self.text, lang)
        self.consts: dict[str, tuple[int, int]] = {}   # TS const NAME -> token span of the initializer
        self.imports: dict[str, tuple[str, str]] = {}  # local name -> (module spec, exported name)
        if lang == "ts":
            self._scan_ts_decls()

    def where(self, line: int) -> str:
        return f"{self.rel}:{line}"

    def _scan_ts_decls(self) -> None:
        toks = self.toks
        for i, t in enumerate(toks):
            if t.kind == "id" and t.val in ("const", "let") and i + 2 < len(toks) \
                    and toks[i + 1].kind == "id" and toks[i + 2].kind == "p" and toks[i + 2].val == "=":
                start = i + 3
                end = start
                depth = 0
                while end < len(toks):
                    x = toks[end]
                    if x.kind == "p" and x.val in "([{":
                        depth += 1
                    elif x.kind == "p" and x.val in ")]}":
                        depth -= 1
                        if depth < 0:
                            break
                    elif depth == 0 and x.kind == "p" and x.val == ";":
                        break
                    elif depth == 0 and x.kind == "id" and x.val in ("const", "let", "export", "function") and end > start:
                        break
                    end += 1
                self.consts.setdefault(toks[i + 1].val, (start, end))
            if t.kind == "id" and t.val == "import":
                j = i + 1
                if j < len(toks) and toks[j].kind == "id" and toks[j].val == "type":
                    j += 1
                if j < len(toks) and toks[j].kind == "p" and toks[j].val == "{":
                    close = match_close(toks, j)
                    if close + 2 < len(toks) and toks[close + 1].val == "from" and toks[close + 2].kind == "str":
                        spec = toks[close + 2].val
                        names = split_args(toks, j, close)
                        for nm in names:
                            nm = [x for x in nm if not (x.kind == "id" and x.val == "type")]
                            if len(nm) == 1 and nm[0].kind == "id":
                                self.imports[nm[0].val] = (spec, nm[0].val)
                            elif len(nm) == 3 and nm[1].val == "as":
                                self.imports[nm[2].val] = (spec, nm[0].val)


class Corpus:
    def __init__(self, repo: Path, files: list[SourceFile]):
        self.repo = repo
        self.files = files
        self.by_path = {f.path.resolve(): f for f in files}
        self.swift_types: dict[str, list[tuple[SourceFile, "SwiftType"]]] = {}

    # ---- TS constant evaluation -------------------------------------------
    def resolve_module(self, sf: SourceFile, spec: str) -> SourceFile | None:
        if spec.startswith("@/"):
            base = self.repo / "web/src" / spec[2:]
        elif spec.startswith("."):
            base = (sf.path.parent / spec)
        else:
            return None
        cands = [base] if base.suffix in (".ts", ".tsx") else []
        cands += [base.with_name(base.name + ext) for ext in (".ts", ".tsx")]
        cands += [base / "index.ts", base / "index.tsx"]
        for c in cands:
            hit = self.by_path.get(c.resolve())
            if hit:
                return hit
        return None

    def ts_const(self, sf: SourceFile, name: str, seen=None) -> tuple[str, bool] | None:
        seen = seen or set()
        key = (sf.rel, name)
        if key in seen:
            return None
        seen = seen | {key}
        if name in sf.consts:
            s, e = sf.consts[name]
            return self.ts_eval(sf, sf.toks[s:e], seen)
        if name in sf.imports:
            spec, exported = sf.imports[name]
            target = self.resolve_module(sf, spec)
            if target:
                return self.ts_const(target, exported, seen)
        return None

    def ts_eval(self, sf: SourceFile, toks: list[Tok], seen=None) -> tuple[str, bool] | None:
        """Evaluate a string expression: literals, templates, `+`, constants,
        `[...].join(sep)`, trailing `as const`. Returns (text, exact); unknown
        interpolations become UNKNOWN when exact is False."""
        toks = list(toks)
        while toks and toks[-1].kind == "id" and toks[-1].val == "const" and len(toks) >= 2 and toks[-2].val == "as":
            toks = toks[:-2]
        if not toks:
            return None
        # [ ... ].join('sep')
        if toks[0].kind == "p" and toks[0].val == "[":
            close = match_close(toks, 0)
            rest = toks[close + 1:]
            if len(rest) >= 4 and rest[0].val == "." and rest[1].val == "join" and rest[2].val == "(":
                sep = rest[3].val if rest[3].kind == "str" else ","
                items = []
                exact = True
                for part in split_args(toks, 0, close):
                    v = self.ts_eval(sf, part, seen)
                    if v is None:
                        return None
                    items.append(v[0])
                    exact = exact and v[1]
                return sep.join(items), exact
            return None
        out, exact = [], True
        expect_operand = True
        k = 0
        while k < len(toks):
            t = toks[k]
            if expect_operand:
                if t.kind == "str":
                    for kind, val in t.parts:
                        if kind == "s":
                            out.append(val)
                        else:
                            v = self.ts_ident_expr(sf, val, seen)
                            if v is None:
                                out.append(UNKNOWN)
                                exact = False
                            else:
                                out.append(v[0])
                                exact = exact and v[1]
                    k += 1
                elif t.kind == "id":
                    # NAME or NAME.NAME (namespace access is not resolved)
                    if k + 1 < len(toks) and toks[k + 1].val == ".":
                        return None
                    v = self.ts_const(sf, t.val, seen)
                    if v is None:
                        return None
                    out.append(v[0])
                    exact = exact and v[1]
                    k += 1
                elif t.kind == "p" and t.val == "(":
                    close = match_close(toks, k)
                    v = self.ts_eval(sf, toks[k + 1:close], seen)
                    if v is None:
                        return None
                    out.append(v[0])
                    exact = exact and v[1]
                    k = close + 1
                else:
                    return None
                expect_operand = False
            else:
                if t.kind == "p" and t.val == "+":
                    expect_operand = True
                    k += 1
                else:
                    return None
        if expect_operand:
            return None
        return "".join(out), exact

    def ts_ident_expr(self, sf: SourceFile, expr: str, seen) -> tuple[str, bool] | None:
        if re.fullmatch(r"[A-Za-z_$][\w$]*", expr):
            return self.ts_const(sf, expr, seen)
        return None

    # ---- Swift constant evaluation ------------------------------------------
    def swift_eval(self, sf: SourceFile, toks: list[Tok], owner: str | None = None) -> tuple[str, bool] | None:
        toks = list(toks)
        if not toks:
            return None
        if toks[0].kind == "p" and toks[0].val == "[":
            close = match_close(toks, 0)
            rest = toks[close + 1:]
            if len(rest) >= 3 and rest[0].val == "." and rest[1].val == "joined" and rest[2].val == "(":
                rclose = match_close(rest, 2)
                sep = ""
                for a in split_args(rest, 2, rclose):
                    lab, expr = arg_label(a)
                    if lab == "separator" and expr and expr[0].kind == "str":
                        sep = expr[0].val
                items, exact = [], True
                for part in split_args(toks, 0, close):
                    v = self.swift_eval(sf, part, owner)
                    if v is None:
                        return None
                    items.append(v[0])
                    exact = exact and v[1]
                return sep.join(items), exact
            return None
        out, exact, expect = [], True, True
        k = 0
        while k < len(toks):
            t = toks[k]
            if expect:
                if t.kind == "str":
                    for kind, val in t.parts:
                        if kind == "s":
                            out.append(val)
                        else:
                            v = self.swift_member(sf, val, owner)
                            if v is None:
                                out.append(UNKNOWN)
                                exact = False
                            else:
                                out.append(v[0])
                                exact = exact and v[1]
                    k += 1
                elif t.kind == "id":
                    j = k + 1
                    path = [t.val]
                    while j + 1 < len(toks) and toks[j].val == "." and toks[j + 1].kind == "id":
                        path.append(toks[j + 1].val)
                        j += 2
                    v = self.swift_member(sf, ".".join(path), owner)
                    if v is None:
                        return None
                    out.append(v[0])
                    exact = exact and v[1]
                    k = j
                else:
                    return None
                expect = False
            else:
                if t.kind == "p" and t.val == "+":
                    expect = True
                    k += 1
                else:
                    return None
        if expect:
            return None
        return "".join(out), exact

    def swift_member(self, sf: SourceFile, path: str, owner: str | None = None) -> tuple[str, bool] | None:
        """`Type.member` or a bare `member` of the current type → its static string value."""
        parts = path.split(".")
        if len(parts) == 1:
            if owner is None:
                return None
            type_name, member = owner, parts[0]
        elif len(parts) == 2:
            type_name, member = parts
        else:
            return None
        found = self.find_swift_type(sf, type_name)
        if not found or member not in found[1].statics:
            return None
        owner_sf, stype = found
        s, e = stype.statics[member]
        return self.swift_eval(owner_sf, owner_sf.toks[s:e], stype.name)

    def find_swift_type(self, sf: SourceFile, name: str, before_line: int | None = None):
        cands = self.swift_types.get(name, [])
        if not cands:
            return None
        same = [c for c in cands if c[0] is sf]
        if same:
            if before_line is not None:
                prior = [c for c in same if c[1].line <= before_line]
                if prior:
                    return max(prior, key=lambda c: c[1].line)
            return same[0]
        return cands[0] if len(cands) == 1 else None


# ==========================================================================
# Swift type parsing
# ==========================================================================
@dataclass
class SwiftType:
    name: str
    kind: str                  # struct | class | enum
    line: int
    annotation: tuple[str, str] | None
    body: tuple[int, int]      # token span inside the braces
    inherits: list[str] = field(default_factory=list)
    props: dict = field(default_factory=dict)          # name -> optional?
    coding_keys: dict | None = None                     # case -> raw
    key_enums: dict = field(default_factory=dict)       # enum name -> {case: raw}
    statics: dict = field(default_factory=dict)         # static let name -> token span
    cases: dict = field(default_factory=dict)           # enum: case -> raw value
    custom_decode: bool = False
    encode_keys_enum: str | None = None


SWIFT_ANNOT = re.compile(r"^\s*//\s*(table|rpc):\s*([a-z_][a-z0-9_]*)\s*$")


def swift_annotation(lines: list[str], decl_line: int) -> tuple[str, str] | None:
    i = decl_line - 2
    while i >= 0:
        text = lines[i].strip()
        m = SWIFT_ANNOT.match(lines[i])
        if m:
            return m.group(1), m.group(2)
        if text.startswith("///") or text.startswith("@") or (text.startswith("//") and not text.startswith("// MARK")):
            i -= 1
            continue
        return None
    return None


def parse_swift_types(sf: SourceFile) -> list[SwiftType]:
    toks = sf.toks
    out = []
    for i, t in enumerate(toks):
        if t.kind != "id" or t.val not in ("struct", "class", "enum") or i + 1 >= len(toks) or toks[i + 1].kind != "id":
            continue
        if i > 0 and toks[i - 1].val == ".":
            continue
        name = toks[i + 1].val
        j = i + 2
        inherits = []
        while j < len(toks) and not (toks[j].kind == "p" and toks[j].val == "{"):
            if toks[j].kind == "id":
                inherits.append(toks[j].val)
            if toks[j].kind == "p" and toks[j].val in (";", "}"):
                break
            j += 1
        if j >= len(toks) or toks[j].val != "{":
            continue
        close = match_close(toks, j)
        st = SwiftType(name, t.val, t.line, swift_annotation(sf.lines, t.line), (j + 1, close), inherits)
        _parse_swift_body(sf, st)
        out.append(st)
    return out


def _parse_swift_body(sf: SourceFile, st: SwiftType) -> None:
    toks = sf.toks
    s, e = st.body
    k = s
    pending_static = False
    while k < e:
        t = toks[k]
        if t.kind == "p" and t.val in "{([":
            k = match_close(toks, k) + 1
            continue
        if t.kind == "id" and t.val == "static":
            pending_static = True
            k += 1
            continue
        if t.kind == "id" and t.val in ("func", "init", "subscript"):
            # skip the whole declaration including its body
            if t.val == "init" and k + 1 < e and toks[k + 1].val == "(":
                close = match_close(toks, k + 1)
                if any(x.kind == "id" and x.val == "decoder" for x in toks[k + 1:close]):
                    st.custom_decode = True
            if t.val == "func" and k + 1 < e and toks[k + 1].val == "encode":
                j = k
                while j < e and toks[j].val != "{":
                    j += 1
                body_end = match_close(toks, j)
                for q in range(j, body_end):
                    if toks[q].val == "keyedBy" and q + 2 < body_end and toks[q + 2].kind == "id":
                        st.encode_keys_enum = toks[q + 2].val
                        break
            j = k
            while j < e and toks[j].val != "{":
                if toks[j].val == "(":
                    j = match_close(toks, j)
                j += 1
            k = match_close(toks, j) + 1 if j < e else e
            pending_static = False
            continue
        if t.kind == "id" and t.val in ("struct", "class", "enum", "extension", "protocol", "actor"):
            if t.val == "enum" and k + 1 < e and toks[k + 1].kind == "id":
                ename = toks[k + 1].val
                j = k + 2
                is_key = False
                while j < e and toks[j].val != "{":
                    if toks[j].val == "CodingKey":
                        is_key = True
                    j += 1
                close = match_close(toks, j)
                if is_key:
                    st.key_enums[ename] = _enum_cases(toks, j + 1, close)
                    if ename == "CodingKeys":
                        st.coding_keys = st.key_enums[ename]
                k = close + 1
                continue
            j = k
            while j < e and toks[j].val != "{":
                j += 1
            k = match_close(toks, j) + 1
            continue
        if st.kind == "enum" and t.kind == "id" and t.val == "case":
            j = k + 1
            end = j
            while end < e and not (toks[end].kind == "id" and toks[end].val in
                                   ("case", "var", "let", "func", "static", "init", "enum", "struct")) \
                    and not (toks[end].kind == "p" and toks[end].val in ("{", "}")):
                end += 1
            for part in split_args(toks, j - 1, end):
                if part and part[0].kind == "id":
                    raw = part[0].val
                    if len(part) >= 3 and part[1].val == "=" and part[2].kind == "str":
                        raw = part[2].val
                    if len(part) >= 2 and part[1].val == "(":
                        raw = None  # associated values: not a raw-value enum case
                    st.cases[part[0].val] = raw
            k = end
            continue
        if t.kind == "id" and t.val in ("var", "let") and k + 1 < e and toks[k + 1].kind == "id":
            pname = toks[k + 1].val
            j = k + 2
            typ = []
            if j < e and toks[j].val == ":":
                j += 1
                depth = 0
                while j < e:
                    x = toks[j]
                    if x.kind == "p" and x.val in "([<":
                        depth += 1
                    elif x.kind == "p" and x.val in ")]>":
                        depth -= 1
                    elif depth == 0 and x.kind == "p" and x.val in ("=", "{"):
                        break
                    elif depth == 0 and x.kind == "id" and x.line != toks[j - 1].line:
                        break
                    typ.append(x)
                    j += 1
            computed = j < e and toks[j].kind == "p" and toks[j].val == "{"
            if pending_static:
                if j < e and toks[j].val == "=":
                    start = j + 1
                    end = start
                    depth = 0
                    last_line = toks[start].line if start < e else 0
                    while end < e:
                        x = toks[end]
                        if depth == 0 and x.line != last_line and end > start and not (
                                x.kind == "p" and x.val in (".", "+", ")", "]")):
                            break
                        if x.kind == "p" and x.val in "([{":
                            depth += 1
                        elif x.kind == "p" and x.val in ")]}":
                            depth -= 1
                        last_line = x.line
                        end += 1
                    st.statics[pname] = (start, end)
            elif not computed:
                optional = bool(typ) and typ[-1].kind == "p" and typ[-1].val in ("?", "!")
                has_default = j < e and toks[j].val == "="
                st.props[pname] = {"optional": optional, "default": has_default, "let": t.val == "let"}
            pending_static = False
            k = j
            if computed:
                k = match_close(toks, j) + 1
            continue
        if t.kind == "id" and t.val not in ("private", "fileprivate", "public", "internal", "final", "nonisolated",
                                            "lazy", "weak", "mutating", "override", "@MainActor"):
            pending_static = False
        k += 1


def _enum_cases(toks: list[Tok], s: int, e: int) -> dict:
    cases = {}
    k = s
    while k < e:
        if toks[k].kind == "id" and toks[k].val == "case":
            j = k + 1
            end = j
            while end < e and not (toks[end].kind == "id" and toks[end].val == "case"):
                end += 1
            for part in split_args(toks, j - 1, end):
                if part and part[0].kind == "id":
                    raw = part[0].val
                    if len(part) >= 3 and part[1].val == "=" and part[2].kind == "str":
                        raw = part[2].val
                    cases[part[0].val] = raw
            k = end
        else:
            k += 1
    return cases


def snake(name: str) -> str:
    return re.sub(r"(?<=[a-z0-9])([A-Z])", r"_\1", name).lower()


# ==========================================================================
# PostgREST select / filter grammar
# ==========================================================================
def split_top(text: str, sep: str = ",") -> list[str]:
    out, depth, cur = [], 0, []
    quoted = False
    for ch in text:
        if ch == '"':
            quoted = not quoted
        if not quoted:
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
            elif ch == sep and depth == 0:
                out.append("".join(cur))
                cur = []
                continue
        cur.append(ch)
    out.append("".join(cur))
    return [x.strip() for x in out if x.strip()]


SELECT_ITEM = re.compile(
    r"^(?P<spread>\.\.\.)?(?:(?P<alias>[A-Za-z_][\w]*)\s*:\s*)?(?P<name>[A-Za-z_][\w]*|\*)"
    r"(?P<hints>(?:\s*!\s*[A-Za-z_][\w]*)*)\s*(?:\((?P<sub>.*)\))?(?P<rest>.*)$", re.S)


def column_root(expr: str) -> str:
    """`col->a->>b::text` / `col.sum()` → `col`."""
    expr = expr.strip()
    expr = re.split(r"->>?|::", expr)[0]
    return expr.split(".")[0].strip().strip('"')


class Checker:
    def __init__(self, schema: Schema, corpus: Corpus, report: Report):
        self.s = schema
        self.c = corpus
        self.r = report

    # ---- relations -------------------------------------------------------
    def need_relation(self, where: str, name: str) -> bool:
        self.r.count("tables")
        if not self.s.has_relation(name):
            self.r.error(where, f"table/view '{name}' does not exist")
            return False
        return True

    def need_column(self, where: str, table: str, col: str, what: str = "column", priv: str | None = None,
                    role: str | None = None) -> bool:
        self.r.count("columns")
        if col not in self.s.columns(table):
            self.r.error(where, f"{what} '{table}.{col}' does not exist")
            return False
        if priv and role and not self.s.can(table, role, priv, col):
            verb = {"s": "SELECT", "i": "INSERT", "u": "UPDATE"}[priv]
            self.r.error(where, f"role {role} has no {verb} privilege on '{table}.{col}'")
            return False
        return True

    def embed_target(self, where: str, parent: str, name: str, hints: list[str]) -> str | None:
        """Resolve an embedded resource the way PostgREST does (FK in either
        direction, or a junction table); returns the embedded relation."""
        fks = self.s.fks
        hint = next((h for h in hints if h not in ("inner", "left")), None)
        target = name if self.s.has_relation(name) else None
        if target is None:
            # embed by FK constraint name or by FK column of the parent
            for fk in fks:
                if fk["foreign_key_name"] == name and parent in (fk["relation"], fk["referenced_relation"]):
                    return fk["referenced_relation"] if fk["relation"] == parent else fk["relation"]
            col_fks = [fk for fk in fks if fk["relation"] == parent and name in fk["columns"] and name != "shop_id"]
            if len(col_fks) == 1:
                return col_fks[0]["referenced_relation"]
            self.r.error(where, f"embedded resource '{name}' is neither a table nor a foreign key of '{parent}'")
            return None
        direct = [fk for fk in fks if (fk["relation"] == parent and fk["referenced_relation"] == target)
                  or (fk["relation"] == target and fk["referenced_relation"] == parent)]
        if hint:
            chosen = [fk for fk in direct if fk["foreign_key_name"] == hint
                      or (hint in fk["columns"] and hint != "shop_id")
                      or (hint in fk["referenced_columns"] and hint != "shop_id")]
            if not chosen:
                self.r.error(where, f"embed hint '!{hint}' matches no foreign key between '{parent}' and '{target}'")
                return None
            if len(chosen) > 1:
                self.r.error(where, f"embed hint '!{hint}' is ambiguous between '{parent}' and '{target}'")
            return target
        if len(direct) == 1:
            return target
        if len(direct) > 1:
            names = ", ".join(sorted(fk["foreign_key_name"] for fk in direct))
            self.r.error(where, f"embedding '{target}' from '{parent}' is ambiguous (PGRST201): add a "
                                f"!hint naming one of {names}")
            return None
        # many-to-many through a junction table
        for j in self.s.relations:
            a = [fk for fk in fks if fk["relation"] == j and fk["referenced_relation"] == parent]
            b = [fk for fk in fks if fk["relation"] == j and fk["referenced_relation"] == target]
            if a and b:
                return target
        self.r.error(where, f"no foreign key relates '{parent}' and '{target}', so '{target}' cannot be embedded")
        return None

    def check_select(self, where: str, table: str, text: str, role: str | None) -> dict:
        """Validate a select list; returns {alias_or_name: embedded table}."""
        embeds = {}
        for item in split_top(text):
            m = SELECT_ITEM.match(item)
            if not m:
                self.r.error(where, f"cannot parse select item '{item}' for '{table}'")
                continue
            name, sub = m.group("name"), m.group("sub")
            if sub is not None and m.group("name") not in ("count",) and not m.group("rest").strip().startswith("."):
                hints = [h.strip() for h in m.group("hints").split("!") if h.strip()]
                target = self.embed_target(where, table, name, hints)
                self.r.count("embeds")
                if target:
                    embeds[m.group("alias") or name] = target
                    embeds.setdefault(name, target)
                    if role and not self.s.any_column_priv(target, role, "s"):
                        self.r.error(where, f"role {role} cannot SELECT embedded '{target}'")
                    inner = self.check_select(where, target, sub, role) if sub.strip() else {}
                    embeds.update({f"{m.group('alias') or name}.{k}": v for k, v in inner.items()})
                continue
            if name == "*":
                if role and not self.s.can(table, role, "s"):
                    self.r.error(where, f"select('*') on '{table}' needs table-level SELECT for {role} "
                                        "(it only has column grants): list the columns")
                continue
            if name == "count" and (sub is not None or not m.group("rest").strip()) and name not in self.s.columns(table):
                continue  # aggregate count()
            col = column_root(name + m.group("rest"))
            self.need_column(where, table, col, priv="s" if role else None, role=role)
        return embeds

    def check_filter_col(self, where: str, table: str, embeds: dict, col_expr: str, role: str | None,
                         referenced: str | None = None, embeds_known: bool = True) -> None:
        if UNKNOWN in col_expr:
            self.r.skip(where, f"filter column built at run time on '{table}'")
            return
        base = re.split(r"->>?|::", col_expr.strip())[0]
        target = table
        if referenced:
            target = embeds.get(referenced) or (referenced if self.s.has_relation(referenced) else None)
            if not target:
                self.r.error(where, f"referenced table '{referenced}' is not embedded in the select")
                return
        elif "." in base:
            alias, base = base.rsplit(".", 1)
            target = embeds.get(alias)
            if not target and not embeds_known:
                self.r.skip(where, f"filter on '{alias}.{base}' of a select built at run time")
                return
            if not target:
                self.r.error(where, f"filter on '{alias}.{base}': '{alias}' is not an embedded resource of '{table}'")
                return
        self.need_column(where, target, base.strip('"'), priv="s" if role else None, role=role)

    def check_logic_filter(self, where: str, table: str, embeds: dict, text: str, role: str | None,
                           referenced: str | None = None) -> None:
        for part in split_top(text):
            part = part.strip()
            m = re.match(r"^(?:not\.)?(and|or)\((.*)\)$", part, re.S)
            if m:
                self.check_logic_filter(where, table, embeds, m.group(2), role, referenced)
                continue
            pieces = part.split(".")
            if len(pieces) < 2:
                self.r.error(where, f"cannot parse filter '{part}'")
                continue
            ops = {"eq", "neq", "gt", "gte", "lt", "lte", "like", "ilike", "match", "imatch", "is", "isdistinct",
                   "in", "cs", "cd", "ov", "sl", "sr", "nxl", "nxr", "adj", "fts", "plfts", "phfts", "wfts", "not",
                   "like(any)", "like(all)", "ilike(any)", "ilike(all)"}
            # column may itself be alias.column: the operator is the first known op segment
            idx = next((i for i, p in enumerate(pieces) if i > 0 and p.split("(")[0] in ops | {"like", "ilike"}), None)
            if idx is None:
                self.r.error(where, f"cannot find the operator in filter '{part}'")
                continue
            self.check_filter_col(where, table, embeds, ".".join(pieces[:idx]), role, referenced)

    # ---- RPC ---------------------------------------------------------------
    def check_rpc(self, where: str, name: str, keys: list[str] | None, open_keys: bool, surface: str) -> None:
        self.r.count("rpcs")
        overloads = self.s.functions.get(name)
        if not overloads:
            self.r.error(where, f"RPC '{name}' does not exist")
            return
        allowed = ("anon", "authenticated") if surface in ("web", "ios") else API_ROLES
        if not any(set(allowed) & o["exec"] for o in overloads):
            self.r.error(where, f"RPC '{name}' is not executable by {' or '.join(allowed)}")
        if keys is None:
            return
        all_names = {a for o in overloads for a, _d in o["args"]}
        for k in keys:
            if k not in all_names:
                self.r.error(where, f"RPC '{name}' has no argument '{k}' (arguments: "
                                    f"{', '.join(sorted(all_names)) or 'none'})")
                return
        if open_keys:
            return
        ks = set(keys)
        for o in overloads:
            names = {a for a, _d in o["args"]}
            required = {a for a, d in o["args"] if not d}
            if ks <= names and required <= ks:
                return
        need = " | ".join("(" + ", ".join(a + ("?" if d else "") for a, d in o["args"]) + ")" for o in overloads)
        self.r.error(where, f"RPC '{name}' called with ({', '.join(sorted(ks))}) matches no overload {need}")

    def fn_rows(self, name: str) -> list[str] | None:
        cols = None
        for o in self.s.functions.get(name, []):
            if o["ret_cols"] is not None:
                cols = (cols or []) + o["ret_cols"]
        return cols


# ==========================================================================
# Chain walking (shared by TS and Swift)
# ==========================================================================
COLUMN_METHODS = {"eq", "neq", "gt", "gte", "lt", "lte", "like", "ilike", "is", "in", "contains", "containedBy",
                  "overlaps", "textSearch", "likeAllOf", "likeAnyOf", "ilikeAllOf", "ilikeAnyOf", "rangeGt",
                  "rangeGte", "rangeLt", "rangeLte", "rangeAdjacent", "not", "filter", "isDistinct", "order",
                  "notIn", "fts", "plfts", "phfts", "wfts"}
CHAIN_METHODS = COLUMN_METHODS | {"select", "insert", "update", "upsert", "delete", "or", "match", "limit", "range",
                                  "single", "maybeSingle", "csv", "returns", "throwOnError", "abortSignal",
                                  "execute", "head", "count", "explain", "geojson", "rollback", "overrideTypes"}


@dataclass
class ChainCtx:
    table: str
    embeds: dict = field(default_factory=dict)
    embeds_known: bool = True


class SourceScanner:
    def __init__(self, checker: Checker, sf: SourceFile):
        self.k = checker
        self.sf = sf
        self.toks = sf.toks
        self.role = APP_ROLE if sf.surface in ("web", "ios") else None

    # ---- expression helpers ------------------------------------------------
    def eval_str(self, arg: list[Tok], owner: str | None = None) -> tuple[str, bool] | None:
        if self.sf.lang == "ts":
            return self.k.c.ts_eval(self.sf, arg)
        return self.k.c.swift_eval(self.sf, arg, owner)

    def select_variants(self, arg: list[Tok], owner: str | None) -> list[str]:
        """Exact texts a select argument can take: a string expression, or a
        TS constant / inline `cond ? A : B` whose branches are string
        expressions. Empty when any part is only known at run time."""
        if self.sf.lang == "ts" and len(arg) == 1 and arg[0].kind == "id" and arg[0].val in self.sf.consts:
            s0, e0 = self.sf.consts[arg[0].val]
            arg = self.sf.toks[s0:e0]
        q = next((i for i, t in enumerate(arg) if t.kind == "p" and t.val == "?" and
                  self._depth_at(arg, i) == 0), None) if self.sf.lang == "ts" else None
        if q is not None:
            colon = next((i for i in range(q + 1, len(arg)) if arg[i].kind == "p" and arg[i].val == ":"
                          and self._depth_at(arg, i) == 0), None)
            if colon is None:
                return []
            a, b = self.select_variants(arg[q + 1:colon], owner), self.select_variants(arg[colon + 1:], owner)
            return a + b if a and b else []
        val = self.eval_str(arg, owner)
        return [val[0]] if val and val[1] else []

    @staticmethod
    def _depth_at(toks: list[Tok], idx: int) -> int:
        depth = 0
        for t in toks[:idx]:
            if t.kind == "p" and t.val in "([{":
                depth += 1
            elif t.kind == "p" and t.val in ")]}":
                depth -= 1
        return depth

    def object_keys(self, arg: list[Tok], depth: int = 0) -> tuple[list[str] | None, bool]:
        """Keys of a TS object literal / Swift dictionary literal / Swift
        payload struct. Returns (keys, open) — open when spreads or computed
        keys make the set incomplete; keys None when not statically known."""
        if not arg:
            return None, True
        if self.sf.lang == "ts":
            if arg[0].val == "[" and arg[0].kind == "p":
                close = match_close(arg, 0)
                keys, open_ = [], False
                for el in split_args(arg, 0, close):
                    ks, o = self.object_keys(el)
                    if ks is None:
                        return None, True
                    keys += [x for x in ks if x not in keys]
                    open_ = open_ or o
                return keys, open_
            if arg[0].kind == "p" and arg[0].val == "{":
                close = match_close(arg, 0)
                keys, open_ = [], False
                for prop in split_args(arg, 0, close):
                    if not prop:
                        continue
                    if prop[0].val == "...":
                        open_ = True
                        continue
                    if prop[0].kind in ("id", "str") and (len(prop) == 1 or prop[1].val in (":", "(")):
                        keys.append(prop[0].val)
                    else:
                        open_ = True
                return keys, open_
            return None, True
        # Swift
        if arg[0].kind == "p" and arg[0].val == "[":
            close = match_close(arg, 0)
            keys = []
            for el in split_args(arg, 0, close):
                if len(el) >= 2 and el[0].kind == "str" and el[1].val == ":":
                    if len(el[0].parts or []) != 1:
                        return None, True
                    keys.append(el[0].val)
                elif el and el[0].kind == "p" and el[0].val == "[":
                    ks, _o = self.object_keys(el)
                    if ks is None:
                        return None, True
                    keys += [x for x in ks if x not in keys]
                else:
                    return None, True
            return keys, False
        if arg[0].kind == "id" and len(arg) >= 2 and arg[1].val == "(" and arg[0].val[:1].isupper():
            close = match_close(arg, 1)
            if close != len(arg) - 1:
                return None, True
            return self.swift_payload_keys(arg[0].val, arg[0].line, [arg_label(a)[0] for a in split_args(arg, 1, close)])
        if len(arg) == 1 and arg[0].kind == "id":
            return self.swift_var_keys(arg[0].val, self.tok_index(arg[0]), depth)
        return None, True

    def tok_index(self, tok: Tok) -> int:
        for i, t in enumerate(self.toks):
            if t is tok:
                return i
        return -1

    def statement_expr(self, j: int) -> list[Tok]:
        """Tokens of the expression starting at toks[j], up to the end of the
        statement (a new line at bracket depth 0 that does not continue it)."""
        toks = self.toks
        end, depth = j, 0
        while end < len(toks):
            x = toks[end]
            if depth == 0 and end > j and x.line != toks[end - 1].line and not (
                    x.kind == "p" and x.val in (".", "+", "?", ":", ")", "]", "}", "??")):
                break
            if x.kind == "p" and x.val in "([{":
                depth += 1
            elif x.kind == "p" and x.val in ")]}":
                depth -= 1
                if depth < 0:
                    break
            end += 1
        return toks[j:end]

    def swift_var_keys(self, name: str, use_idx: int, depth: int = 0) -> tuple[list[str] | None, bool]:
        """Encoded keys of the value bound to `name` at the nearest preceding
        declaration in this file: a parameter / annotated binding of a payload
        struct type (`draft: CustomerDraft`, `rows: [Row]`), or a binding whose
        initializer is itself resolvable (`Type(...)`, a dictionary literal,
        `xs.map { Type(...) }`, another variable)."""
        toks = self.toks
        if depth > 4:
            return None, True
        for i in range(use_idx - 1, 0, -1):
            t = toks[i]
            if not (t.kind == "id" and t.val == name and i + 2 < len(toks)):
                continue
            nxt, prev = toks[i + 1], toks[i - 1]
            if nxt.val == ":" and prev.val in ("let", "var", "(", ","):
                j = i + 2
                typ = None
                if toks[j].val == "[" and j + 1 < len(toks) and toks[j + 1].kind == "id":
                    typ = toks[j + 1].val
                elif toks[j].kind == "id":
                    typ = toks[j].val
                if not typ or not typ[:1].isupper():
                    continue  # a call label (`params: params`), not a declaration
                if prev.val in ("let", "var"):
                    # annotated binding: prefer the initializer when there is one
                    k = j
                    while k < len(toks) and toks[k].val != "=" and toks[k].line == toks[j].line:
                        k += 1
                    if k < len(toks) and toks[k].val == "=":
                        return self.expr_keys(self.statement_expr(k + 1), depth + 1)
                return self.swift_payload_keys(typ, t.line, None)
            if nxt.val == "=" and prev.val in ("let", "var"):
                return self.expr_keys(self.statement_expr(i + 2), depth + 1)
        return None, True

    def expr_keys(self, init: list[Tok], depth: int) -> tuple[list[str] | None, bool]:
        if not init:
            return None, True
        if init[0].kind == "p" and init[0].val == "[":
            return self.object_keys(init, depth)
        if len(init) >= 2 and init[0].kind == "id" and init[0].val[:1].isupper() and init[1].val == "(":
            if match_close(init, 1) == len(init) - 1:
                return self.object_keys(init, depth)
        if len(init) == 1 and init[0].kind == "id":
            return self.swift_var_keys(init[0].val, self.tok_index(init[0]), depth + 1)
        for q in range(len(init) - 3):
            if init[q].val == "map" and init[q + 1].val == "{" and init[q + 2].kind == "id" \
                    and init[q + 2].val[:1].isupper() and init[q + 3].val == "(":
                return self.swift_payload_keys(init[q + 2].val, init[q + 2].line, None)
        return None, True

    def swift_payload_keys(self, type_name: str, line: int, labels: list | None) -> tuple[list[str] | None, bool]:
        st = self.k.c.find_swift_type(self.sf, type_name, before_line=line)
        if not st:
            return None, True
        _sf, t = st
        if t.kind != "struct":
            return None, True
        keymap = None
        if t.encode_keys_enum and t.encode_keys_enum in t.key_enums:
            keymap = t.key_enums[t.encode_keys_enum]
            return list(keymap.values()), False
        if t.coding_keys is not None:
            return list(t.coding_keys.values()), False
        if labels is not None and all(labels) and set(labels) <= set(t.props):
            return list(t.props), False
        return list(t.props), False

    # ---- main scan ---------------------------------------------------------
    def scan(self) -> None:
        toks = self.toks
        bindings: dict[str, ChainCtx | None] = {}
        i = 0
        n = len(toks)
        while i < n:
            t = toks[i]
            # variable (re)binding: let/var/const NAME = ...
            if t.kind == "id" and t.val in ("let", "var", "const") and i + 2 < n and toks[i + 1].kind == "id" \
                    and toks[i + 2].val == "=":
                bindings[toks[i + 1].val] = None
            if t.kind == "p" and t.val == "." and i + 2 < n and toks[i + 1].kind == "id" and toks[i + 2].val == "(":
                meth = toks[i + 1].val
                if meth == "from":
                    end, ctx = self.handle_from(i)
                    if ctx is not None:
                        name = self.bound_name(i)
                        if name:
                            bindings[name] = ctx
                    i = end
                    continue
                if meth == "rpc":
                    self.handle_rpc(i)
                if meth == "invoke" and i >= 1 and toks[i - 1].kind == "id" and toks[i - 1].val == "functions":
                    self.handle_invoke(i)
            # continuation of a bound query builder: NAME.method(
            if t.kind == "id" and t.val in bindings and bindings[t.val] is not None and i + 3 < n \
                    and toks[i + 1].val == "." and toks[i + 2].kind == "id" and toks[i + 2].val in CHAIN_METHODS \
                    and toks[i + 3].val == "(" and not (i > 0 and toks[i - 1].val == "."):
                i = self.walk_chain(i + 1, bindings[t.val])
                continue
            i += 1

    def bound_name(self, dot_i: int) -> str | None:
        """For `let q = a.b.from(...)` (a builder kept for more filters) return 'q'."""
        toks = self.toks
        j = dot_i - 1
        while j >= 1 and toks[j].kind == "id" and toks[j - 1].val == ".":
            j -= 2
        if j < 0 or toks[j].kind != "id":
            return None
        j -= 1
        if j >= 0 and toks[j].kind == "id" and toks[j].val in ("await", "try"):
            return None  # an awaited result is data, not a query builder
        if j >= 1 and toks[j].val == "=" and toks[j - 1].kind == "id":
            return toks[j - 1].val
        return None

    def call_args(self, open_i: int) -> tuple[list[list[Tok]], int]:
        close = match_close(self.toks, open_i)
        return split_args(self.toks, open_i, close), close

    def handle_from(self, dot_i: int) -> tuple[int, ChainCtx | None]:
        toks = self.toks
        args, close = self.call_args(dot_i + 2)
        where = self.sf.where(toks[dot_i + 1].line)
        is_storage = dot_i >= 1 and toks[dot_i - 1].kind == "id" and toks[dot_i - 1].val == "storage"
        if len(args) != 1:
            return close + 1, None
        val = self.eval_str(args[0])
        if is_storage:
            if val is None or not val[1]:
                self.k.r.skip(where, "storage bucket name built at run time")
            else:
                self.k.r.count("buckets")
                if val[0] not in self.k.s.buckets:
                    self.k.r.error(where, f"storage bucket '{val[0]}' does not exist")
            return close + 1, None
        if val is None or not val[1]:
            # `Array.from(x)` and friends: only a query builder chain makes this a table reference
            nxt = close + 1
            if nxt + 1 < len(toks) and toks[nxt].val == "." and toks[nxt + 1].val in (
                    "select", "insert", "update", "upsert", "delete"):
                self.k.r.skip(where, "table name built at run time")
            return close + 1, None
        table = val[0]
        if not self.k.need_relation(where, table):
            return close + 1, None
        ctx = ChainCtx(table)
        return self.walk_chain(close + 1, ctx), ctx

    def walk_chain(self, i: int, ctx: ChainCtx) -> int:
        toks = self.toks
        n = len(toks)
        while i + 2 < n and toks[i].val == "." and toks[i + 1].kind == "id":
            meth = toks[i + 1].val
            j = i + 2
            if toks[j].val == "<" and self.sf.lang == "ts":  # .returns<T>()
                depth = 0
                while j < n:
                    if toks[j].val == "<":
                        depth += 1
                    elif toks[j].val == ">":
                        depth -= 1
                        if depth == 0:
                            j += 1
                            break
                    j += 1
            if j >= n or toks[j].val != "(":
                break
            args, close = self.call_args(j)
            self.handle_method(meth, args, ctx, self.sf.where(toks[i + 1].line))
            i = close + 1
        return i

    def handle_method(self, meth: str, args: list[list[Tok]], ctx: ChainCtx, where: str) -> None:
        k, role, table = self.k, self.role, ctx.table
        swift = self.sf.lang == "swift"
        labeled = [arg_label(a) for a in args] if swift else [(None, a) for a in args]
        pos = [a for lab, a in labeled if lab is None]

        def opt(name: str) -> tuple[str, bool] | None:
            # TS: options object {name: '...'}; Swift: labeled argument
            if swift:
                for lab, a in labeled:
                    if lab == name:
                        return self.eval_str(a)
                return None
            for a in args[1:]:
                if a and a[0].val == "{":
                    close = match_close(a, 0)
                    for prop in split_args(a, 0, close):
                        if len(prop) >= 3 and prop[0].val == name and prop[1].val == ":":
                            return self.eval_str(prop[2:])
            return None

        if meth == "select":
            if not pos:
                if role and not k.s.can(table, role, "s"):
                    k.r.error(where, f"select() of all columns of '{table}' needs table-level SELECT for {role}")
                return
            owner = None
            if swift and len(pos[0]) >= 3 and pos[0][0].kind == "id" and pos[0][1].val == ".":
                owner = pos[0][0].val
            variants = self.select_variants(pos[0], owner)
            if not variants:
                k.r.skip(where, f"select list on '{table}' built at run time")
                ctx.embeds_known = False
                return
            for text in variants:
                ctx.embeds.update(k.check_select(where, table, text, role))
            return
        if meth in ("insert", "update", "upsert"):
            priv = {"insert": "i", "update": "u", "upsert": "i"}[meth]
            if pos:
                keys, _open = self.object_keys(pos[0])
                if keys is None:
                    k.r.skip(where, f"{meth} payload for '{table}' not statically known")
                else:
                    for key in keys:
                        exists = k.need_column(where, table, key, what=f"{meth} column",
                                               priv=priv if role else None, role=role)
                        if exists and meth == "upsert" and role and not k.s.can(table, role, "u", key):
                            k.r.error(where, f"role {role} has no UPDATE privilege on '{table}.{key}' (upsert)")
            conflict = opt("onConflict")
            if conflict is not None:
                if conflict[1]:
                    for c in split_top(conflict[0]):
                        k.need_column(where, table, c, what="onConflict column")
                else:
                    k.r.skip(where, "onConflict built at run time")
            elif role and meth in ("insert", "update") and not k.s.any_column_priv(table, role, priv):
                k.r.error(where, f"role {role} cannot {meth.upper()} '{table}'")
            return
        if meth == "delete":
            if role and not k.s.can(table, role, "d"):
                k.r.error(where, f"role {role} has no DELETE privilege on '{table}'")
            return
        if meth == "or":
            if not pos:
                return
            val = self.eval_str(pos[0])
            ref = opt("referencedTable") or opt("foreignTable")
            if val is None:
                k.r.skip(where, f"or() filter on '{table}' built at run time")
                return
            k.check_logic_filter(where, table, ctx.embeds, val[0], role, ref[0] if ref else None)
            return
        if meth == "match":
            if pos:
                keys, _o = self.object_keys(pos[0])
                if keys is None:
                    k.r.skip(where, f"match() on '{table}' not statically known")
                for key in keys or []:
                    k.check_filter_col(where, table, ctx.embeds, key, role)
            return
        if meth in COLUMN_METHODS:
            if not pos:
                return
            val = self.eval_str(pos[0])
            if val is None:
                k.r.skip(where, f".{meth}() column on '{table}' built at run time")
                return
            ref = opt("referencedTable") or opt("foreignTable")
            k.check_filter_col(where, table, ctx.embeds, val[0], role, ref[0] if ref else None, ctx.embeds_known)

    def handle_rpc(self, dot_i: int) -> None:
        toks = self.toks
        args, _close = self.call_args(dot_i + 2)
        where = self.sf.where(toks[dot_i + 1].line)
        if not args:
            return
        val = self.eval_str(args[0])
        if val is None or not val[1]:
            self.k.r.skip(where, "RPC name chosen at run time")
            return
        params = None
        for a in args[1:]:
            lab, expr = arg_label(a) if self.sf.lang == "swift" else (None, a)
            if self.sf.lang == "swift" and lab != "params":
                continue
            params = expr
            break
        if params is None:
            self.k.check_rpc(where, val[0], [], False, self.sf.surface)
            return
        keys, open_ = self.object_keys(params)
        if keys is None:
            self.k.r.skip(where, f"arguments of RPC '{val[0]}' not statically known")
            self.k.check_rpc(where, val[0], None, True, self.sf.surface)
            return
        self.k.check_rpc(where, val[0], keys, open_, self.sf.surface)

    def handle_invoke(self, dot_i: int) -> None:
        args, _c = self.call_args(dot_i + 2)
        where = self.sf.where(self.toks[dot_i + 1].line)
        if not args:
            return
        val = self.eval_str(args[0])
        if val is None or not val[1]:
            self.k.r.skip(where, "edge function name chosen at run time")
            return
        self.k.r.count("edge_functions")
        name = val[0].split("/")[0].split("?")[0]
        if not (self.k.c.repo / "supabase/functions" / name / "index.ts").exists():
            self.k.r.error(where, f"edge function '{name}' does not exist (supabase/functions/{name}/index.ts)")


# ==========================================================================
# Swift model checks
# ==========================================================================
def mirrored_enum(st: SwiftType, schema: Schema) -> str | None:
    """The Postgres enum a Swift `String` enum mirrors: its snake_case name
    (`JobStatus` → job_status), or the longest Postgres enum name it ends with
    after a feature prefix (`JobDamageKind` → damage_kind)."""
    name = snake(st.name)
    if name in schema.enums:
        return name
    hits = [e for e in schema.enums if name.endswith("_" + e)]
    return max(hits, key=len) if hits else None


def check_swift_models(checker: Checker, corpus: Corpus) -> None:
    s, r = checker.s, checker.r
    for name, entries in sorted(corpus.swift_types.items()):
        for sf, st in entries:
            where = sf.where(st.line)
            # String enums mirroring a Postgres enum
            pg_enum = mirrored_enum(st, s) if st.kind == "enum" and "String" in st.inherits and st.cases else None
            if pg_enum:
                labels = s.enums[pg_enum]
                r.count("enums")
                r.checked_enums.append(f"{st.name}->{pg_enum}")
                raws = [v for v in st.cases.values() if v is not None]
                bad = [v for v in raws if v not in labels]
                if bad:
                    r.error(where, f"enum {st.name} raw values {bad} are not labels of Postgres enum "
                                   f"'{pg_enum}' ({', '.join(labels)})")
                missing = [lab for lab in labels if lab not in raws]
                decodable = any(x in st.inherits for x in ("Codable", "Decodable"))
                if missing and decodable and not st.custom_decode:
                    r.error(where, f"enum {st.name} cannot decode Postgres labels {missing} of "
                                   f"'{pg_enum}' (add the cases or a tolerant init(from:))")
            if not st.annotation:
                continue
            kind, target = st.annotation
            keymap = st.coding_keys
            what = "CodingKeys"
            if keymap is None and st.kind == "struct" and not st.custom_decode \
                    and any(x in st.inherits for x in ("Codable", "Decodable", "Encodable")):
                # synthesized coding without CodingKeys: the stored property names are
                # the keys (a `let` with an initial value is not decoded)
                keymap = {n: n for n, pr in st.props.items() if not (pr["let"] and pr["default"])}
                what = "property (no CodingKeys, so its name is the key)"
            keys = list(keymap.values()) if keymap is not None else None
            if kind == "table":
                if not checker.need_relation(where, target):
                    continue
                cols = s.columns(target)
                for key in keys or []:
                    r.count("columns")
                    if key not in cols:
                        r.error(where, f"{st.name}.{what} '{key}' is not a column of '{target}'")
                if "selectColumns" in st.statics:
                    sp, ep = st.statics["selectColumns"]
                    val = corpus.swift_eval(sf, sf.toks[sp:ep], st.name)
                    if val is None or not val[1]:
                        r.skip(where, f"{st.name}.selectColumns built at run time")
                    else:
                        selected = checker.check_select(where, target, val[0], None)
                        sel_cols = {column_root(x.split(":")[-1]) for x in split_top(val[0])}
                        names = set(sel_cols) | set(selected)
                        if keys is not None and not st.custom_decode and "*" not in sel_cols:
                            for case, key in keymap.items():
                                prop = st.props.get(case)
                                if prop and not prop["optional"] and not prop["default"] and key not in names:
                                    r.error(where, f"{st.name}.{case} ('{key}') is non-optional but not in "
                                                   f"selectColumns, so decoding the rows fails")
            elif kind == "rpc":
                r.count("rpcs")
                if target not in s.functions:
                    r.error(where, f"{st.name} is annotated '// rpc: {target}' but RPC '{target}' does not exist")
                    continue
                if not any({"anon", "authenticated"} & o["exec"] for o in s.functions[target]):
                    r.error(where, f"RPC '{target}' ({st.name}) is not executable by anon or authenticated")
                arg_names = {a for o in s.functions[target] for a, _d in o["args"]}
                rows = checker.fn_rows(target)
                if keys and not set(keys) <= arg_names and rows is not None:
                    # a result-row model (a params struct only names arguments)
                    for key in keys:
                        r.count("columns")
                        if key not in rows:
                            r.error(where, f"{st.name}.{what} '{key}' is not a column returned by RPC "
                                           f"'{target}' ({', '.join(rows)})")


# ==========================================================================
# Driver
# ==========================================================================
def collect_sources(repo: Path) -> list[SourceFile]:
    files = []

    def add(root: Path, pattern: str, lang: str, surface: str, skip) -> None:
        if not root.exists():
            return
        for p in sorted(root.rglob(pattern)):
            rel = p.relative_to(repo).as_posix()
            if "node_modules" in p.parts or skip(rel, p):
                continue
            files.append(SourceFile(p, rel, lang, surface))

    def web_skip(rel: str, p: Path) -> bool:
        return (p.name.endswith((".test.ts", ".test.tsx", ".d.ts")) or "/src/test/" in f"/{rel}"
                or rel.endswith("lib/database.types.ts"))

    def fn_skip(rel: str, p: Path) -> bool:
        return p.name.endswith("_test.ts") or "/_shared/testing/" in f"/{rel}" or p.name == "test_fixtures.ts"

    add(repo / "web/src", "*.ts", "ts", "web", web_skip)
    add(repo / "web/src", "*.tsx", "ts", "web", web_skip)
    add(repo / "supabase/functions", "*.ts", "ts", "functions", fn_skip)
    add(repo / "ios/DetailCRM", "*.swift", "swift", "ios", lambda rel, p: False)
    # DetailCore holds the shared value types (status enums etc.) the app decodes
    add(repo / "ios/DetailCore/Sources", "*.swift", "swift", "ios", lambda rel, p: False)
    return files


def run_checks(schema: Schema, repo: Path, files: list[SourceFile] | None = None) -> Report:
    report = Report()
    files = files if files is not None else collect_sources(repo)
    corpus = Corpus(repo, files)
    for sf in files:
        if sf.lang == "swift":
            for st in parse_swift_types(sf):
                corpus.swift_types.setdefault(st.name, []).append((sf, st))
    checker = Checker(schema, corpus, report)
    for sf in files:
        SourceScanner(checker, sf).scan()
    check_swift_models(checker, corpus)
    report.counts["files"] = len(files)
    return report


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=str(DEFAULT_REPO))
    ap.add_argument("--meta", default=None, help="schema from a gen_types.py --dump-meta JSON (no cluster)")
    ap.add_argument("--pg-env", action="store_true",
                    help="introspect the already migrated database named by the PG* environment "
                         "(see gen_types.py --pg-env) instead of starting a throwaway cluster")
    ap.add_argument("--no-freshness", action="store_true",
                    help="skip comparing database.types.ts / SCHEMA.md with a fresh generation")
    ap.add_argument("--verbose", "-v", action="store_true", help="list references that cannot be verified statically")
    ap.add_argument("--self-test", action="store_true", help="run the script's own tests")
    args = ap.parse_args()
    if args.self_test:
        return self_test()

    repo = Path(args.repo).resolve()
    try:
        if args.meta:
            meta, applied = gen_types.load_meta_file(Path(args.meta))
        else:
            meta, applied = gen_types.load_live_meta(repo, log=lambda m: None, pg_env=args.pg_env)
    except (gen_types.GenError, RuntimeError, OSError, ValueError) as exc:
        print(f"check_contracts: cannot load the schema: {exc}", file=sys.stderr)
        return 2

    failed = False
    if not args.no_freshness:
        try:
            out = gen_types.render(meta, applied, repo)
        except (gen_types.GenError, RuntimeError) as exc:
            print(f"check_contracts: {exc}", file=sys.stderr)
            return 2
        stale = gen_types.stale_files(repo, out["files"])
        if stale:
            failed = True
            print("ERROR generated contract files are stale (run `python3 scripts/gen_types.py`): "
                  + ", ".join(stale))

    report = run_checks(Schema(meta), repo)
    for e in report.errors:
        print(f"ERROR {e}")
    if args.verbose:
        for d in report.dynamic:
            print(f"skip  {d}")
    c = report.counts
    print(f"check_contracts: {c.get('files', 0)} files; verified {c.get('tables', 0)} table refs, "
          f"{c.get('columns', 0)} column refs, {c.get('embeds', 0)} embeds, {c.get('rpcs', 0)} RPC refs, "
          f"{c.get('buckets', 0)} bucket refs, {c.get('edge_functions', 0)} edge-function refs, "
          f"{c.get('enums', 0)} Swift enums; {len(report.dynamic)} run-time names not statically checkable"
          + ("" if args.verbose else " (--verbose lists them)"))
    if report.errors or failed:
        why = [f"{len(report.errors)} contract error(s)"] if report.errors else []
        why += ["stale generated files"] if failed else []
        print(f"check_contracts: FAILED ({', '.join(why)})")
        return 1
    print("check_contracts: OK")
    return 0


# ==========================================================================
# Self-test
# ==========================================================================
def _fixture_meta() -> dict:
    """A tiny schema in gen_types introspection shape."""
    def col(table, name, nullable=False, default=None, tid=1):
        return {"table_id": tid, "table": table, "name": name, "is_nullable": nullable, "default_value": default}

    relations = [{"id": 1, "schema": "public", "name": "shops", "kind": "r"},
                 {"id": 2, "schema": "public", "name": "customers", "kind": "r"},
                 {"id": 3, "schema": "public", "name": "jobs", "kind": "r"},
                 {"id": 4, "schema": "public", "name": "shop_members", "kind": "r"}]
    columns = [col("shops", c) for c in ("id", "name")] + \
        [col("customers", c, tid=2) for c in ("id", "shop_id", "first_name", "last_name", "tags")] + \
        [col("jobs", c, tid=3) for c in ("id", "shop_id", "customer_id", "status", "notes", "created_by",
                                           "assigned_to", "secret_cost")] + \
        [col("shop_members", c, tid=4) for c in ("id", "shop_id", "display_name")]

    def fk(name, rel, cols, ref, refcols):
        return {"foreign_key_name": name, "schema": "public", "relation": rel, "columns": cols,
                "referenced_schema": "public", "referenced_relation": ref, "referenced_columns": refcols,
                "is_one_to_one": False}

    relationships = [fk("customers_shop_fk", "customers", ["shop_id"], "shops", ["id"]),
                     fk("jobs_customer_fk", "jobs", ["shop_id", "customer_id"], "customers", ["shop_id", "id"]),
                     fk("jobs_created_by_fk", "jobs", ["shop_id", "created_by"], "shop_members", ["shop_id", "id"]),
                     fk("jobs_assigned_to_fk", "jobs", ["shop_id", "assigned_to"], "shop_members",
                        ["shop_id", "id"])]

    def fn(name, args, ret="jsonb", execs=("authenticated",), rel_id=None):
        return {"name": name, "schema": "public", "return_type": ret, "return_type_id": 3802,
                "return_type_relation_id": rel_id, "is_extension_member": False,
                "args_declared": [{"mode": "in", "name": a.rstrip("?"), "has_default": a.endswith("?"),
                                   "type_id": 25} for a in args],
                **{f"exec_{r}": r in execs for r in API_ROLES}}

    team = fn("shop_team", ["p_shop_id"], ret="TABLE(member_id uuid, display_name text)")
    team["args_declared"] += [{"mode": "table", "name": "member_id", "has_default": False, "type_id": 2950},
                              {"mode": "table", "name": "display_name", "has_default": False, "type_id": 25}]
    functions = [team, fn("create_job", ["p_shop_id", "p_customer_id", "p_notes?"]),
                 fn("purge_all", ["p_limit?"], execs=("service_role",)),
                 fn("public_quote", ["p_token"], execs=("anon", "authenticated"))]
    types = [{"id": 10, "schema": "public", "name": "job_status", "enums": ["draft", "scheduled", "done"],
              "attributes": []}]
    privs = []
    for t in ("shops", "customers", "shop_members"):
        privs.append({"table": t, "role": "authenticated", "s": True, "i": True, "u": True, "d": True})
    privs.append({"table": "jobs", "role": "authenticated", "s": False, "i": True, "u": True, "d": False})
    col_privs = [{"table": "jobs", "role": "authenticated", "column": c, "attnum": 0,
                  "s": c != "secret_cost", "i": False, "u": False}
                 for c in ("id", "shop_id", "customer_id", "status", "notes", "created_by", "assigned_to",
                           "secret_cost")]
    return {"relations": relations, "columns": columns, "relationships": relationships, "functions": functions,
            "types": types, "table_privs": privs, "column_privs": col_privs,
            "buckets": [{"id": "job-photos"}]}


def self_test() -> int:
    failures = []

    def expect(name: str, cond: bool, detail: str = "") -> None:
        if not cond:
            failures.append(f"{name}{': ' + detail if detail else ''}")

    schema = Schema(_fixture_meta())

    def run(files: dict[str, str]) -> Report:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            (repo / "supabase/functions/payments").mkdir(parents=True)
            (repo / "supabase/functions/payments/index.ts").write_text("export {};\n")
            for rel, text in files.items():
                p = repo / rel
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text(text)
            return run_checks(schema, repo)

    def has(rep: Report, needle: str) -> bool:
        return any(needle in e for e in rep.errors)

    # --- clean TypeScript (web) ------------------------------------------------
    ok = run({
        "web/src/features/jobs/columns.ts":
            "export const JOB_COLUMNS =\n  'id, status, notes, ' +\n  'customer_id';\n",
        "web/src/features/jobs/api.ts":
            "import { JOB_COLUMNS } from './columns';\n"
            "const WITH_CUSTOMER = `${JOB_COLUMNS}, customer:customers(first_name, last_name)`;\n"
            "export async function list(shopId: string, q: string) {\n"
            "  const rows = await supabase.from('jobs').select(WITH_CUSTOMER)\n"
            "    .eq('shop_id', shopId).in('status', ['draft']).order('created_by')\n"
            "    .or(`notes.ilike.%${q}%,status.eq.done`)\n"
            "    .order('first_name', { referencedTable: 'customer' });\n"
            "  const who = await supabase.from('jobs').select('id, creator:shop_members!jobs_created_by_fk(display_name)');\n"
            "  await supabase.from('customers').update({ first_name: 'A', ...rest }).eq('id', 'x');\n"
            "  await supabase.from('customers').insert([{ shop_id: shopId, first_name: 'B' }]).select('*');\n"
            "  await supabase.from('customers').delete().eq('id', 'x');\n"
            "  await supabase.rpc('create_job', { p_shop_id: shopId, p_customer_id: 'c' });\n"
            "  await supabase.rpc('public_quote', { p_token: 't' });\n"
            "  await supabase.storage.from('job-photos').upload('a', b);\n"
            "  await supabase.functions.invoke('payments', { body: {} });\n"
            "  const parts = Array.from(new Set(rows));\n"
            "  const msg = <p>Don't {x}</p>;\n"
            "  return /['\"]/.test(q) ? parts : who;\n"
            "}\n",
    })
    expect("clean web file passes", not ok.errors, "; ".join(ok.errors))
    expect("web refs counted", ok.counts.get("tables", 0) >= 5 and ok.counts.get("rpcs", 0) == 2
           and ok.counts.get("embeds", 0) == 2, str(ok.counts))

    # --- TypeScript drift ---------------------------------------------------------
    bad = run({"supabase/functions/x/index.ts":
               "const COLS = \"id, nickname\";\n"
               "await admin.from('customerz').select('id');\n"
               "await admin.from('customers').select(COLS).eq('last_nam', 'x');\n"
               "await admin.from('jobs').select('id, shop_members(display_name)');\n"
               "await admin.from('jobs').select('id, shops(name)');\n"
               "await admin.from('jobs').update({ statuz: 'done' }).eq('id', id);\n"
               "await admin.from('customers').upsert({ id: 'x' }, { onConflict: 'shop_id,nope' });\n"
               "await admin.rpc('create_jobb', {});\n"
               "await admin.rpc('create_job', { p_shop_id: 's', p_customer: 'c' });\n"
               "await admin.rpc('create_job', { p_shop_id: 's' });\n"
               "await admin.rpc('create_job');\n"
               "await admin.from('customers').select('id').or('first_name.eq.a,nick.eq.b');\n"
               "await admin.storage.from('avatars').remove(['a']);\n"
               "await admin.functions.invoke('no-such-fn');\n"})
    for needle in ("table/view 'customerz' does not exist", "'customers.nickname' does not exist",
                   "'customers.last_nam' does not exist", "ambiguous (PGRST201)",
                   "no foreign key relates 'jobs' and 'shops'", "update column 'jobs.statuz' does not exist",
                   "onConflict column 'customers.nope' does not exist", "RPC 'create_jobb' does not exist",
                   "has no argument 'p_customer'", "matches no overload", "'customers.nick' does not exist",
                   "storage bucket 'avatars' does not exist", "edge function 'no-such-fn' does not exist"):
        expect(f"detects: {needle}", has(bad, needle), "; ".join(bad.errors))
    expect("zero-arg call to a function with required args is rejected",
           sum("create_job' called with ()" in e for e in bad.errors) == 1, "; ".join(bad.errors))
    expect("edge functions may call service_role-only RPCs",
           not has(run({"supabase/functions/y/index.ts": "await admin.rpc('purge_all', { p_limit: 5 });\n"}),
                   "not executable"))

    # --- privileges on app surfaces ----------------------------------------------
    priv = run({"web/src/features/j.ts":
                "await supabase.from('jobs').select('*');\n"
                "await supabase.from('jobs').select('id, secret_cost');\n"
                "await supabase.from('jobs').delete().eq('id', 'x');\n"
                "await supabase.from('jobs').update({ notes: 'n' }).eq('id', 'x');\n"
                "await supabase.rpc('purge_all');\n"})
    for needle in ("select('*') on 'jobs' needs table-level SELECT", "no SELECT privilege on 'jobs.secret_cost'",
                   "no DELETE privilege on 'jobs'", "RPC 'purge_all' is not executable by anon or authenticated"):
        expect(f"privilege: {needle}", has(priv, needle), "; ".join(priv.errors))
    expect("table-level UPDATE grant accepted", not has(priv, "jobs.notes"), "; ".join(priv.errors))

    # --- run-time names are reported, never verified -------------------------------
    dyn = run({"supabase/functions/z/index.ts":
               "await admin.from(table).select('id');\nawait admin.rpc(fn, args);\n"})
    expect("dynamic names skipped not failed", not dyn.errors and len(dyn.dynamic) == 2,
           f"{dyn.errors} {dyn.dynamic}")

    # --- Swift ---------------------------------------------------------------------
    swift_ok = run({"ios/DetailCRM/DetailCRM/Models/Job.swift": '''
// table: jobs
struct Job: Codable {
    var id: UUID
    var status: JobStatus
    var customerID: UUID
    var notes: String?

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case customerID = "customer_id"
        case notes
    }

    static let selectColumns = [
        "id", "status",
        "customer_id", "notes",
    ].joined(separator: ",")
}

enum JobStatus: String, Codable {
    case draft, scheduled
    case done
}

// rpc: create_job
struct CreatedJob: Codable {
    var id: UUID
    enum CodingKeys: String, CodingKey { case id }
}

// rpc: shop_team
struct TeamRow: Codable {
    var memberID: UUID
    var displayName: String
    enum CodingKeys: String, CodingKey {
        case memberID = "member_id"
        case displayName = "display_name"
    }
}

// rpc: shop_team
struct TeamParams: Encodable {
    var shopID: UUID
    enum CodingKeys: String, CodingKey { case shopID = "p_shop_id" }
}

enum JobService {
    static func list(shopID: UUID) async throws -> [Job] {
        var query = Supa.client
            .from("jobs")
            .select(Job.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
        if true {
            query = query.eq("status", value: "draft")
        }
        struct Params: Encodable {
            let p_shop_id: UUID
            let p_customer_id: UUID
        }
        _ = try await Supa.client.rpc("create_job", params: Params(p_shop_id: shopID, p_customer_id: shopID))
        _ = try await Supa.client.rpc("public_quote", params: ["p_token": "t"])
        struct NotesPatch: Encodable {
            let notes: String
        }
        try await Supa.client.from("jobs").update(NotesPatch(notes: "x")).eq("id", value: "1").execute()
        let row = NoteRow(firstName: "A")
        try await Supa.client.from("customers").insert(row).execute()
        _ = try await Supa.client.from("customers").select("id").or("first_name.ilike.\\(term),last_name.ilike.\\(term)")
        return try await query.order("created_by", ascending: true).execute().value
    }
}

// table: customers
struct NoteRow: Encodable {
    var firstName: String
    enum CodingKeys: String, CodingKey { case firstName = "first_name" }
}
'''})
    expect("clean Swift passes", not swift_ok.errors, "; ".join(swift_ok.errors))
    expect("Swift enum checked", swift_ok.counts.get("enums") == 1, str(swift_ok.counts))

    swift_bad = run({"ios/DetailCRM/DetailCRM/Models/Bad.swift": '''
// table: jobs
struct Job: Codable {
    var id: UUID
    var totalCents: Int
    var status: String
    enum CodingKeys: String, CodingKey {
        case id
        case totalCents = "total_cents"
        case status
    }
    static let selectColumns = "id,total_cents"
}

// table: customers
struct Customer: Decodable {
    var id: UUID
    var firstName: String
    enum CodingKeys: String, CodingKey {
        case id
        case firstName = "first_name"
    }
    static let selectColumns = "id"
}

// table: vehicles
struct Vehicle: Codable {
    var id: UUID
    enum CodingKeys: String, CodingKey { case id }
}

// rpc: shop_team
struct TeamRow: Codable {
    var memberID: UUID
    var nickname: String
    enum CodingKeys: String, CodingKey {
        case memberID = "member_id"
        case nickname
    }
}

// rpc: missing_rpc
struct Missing: Codable {
    var id: UUID
    enum CodingKeys: String, CodingKey { case id }
}

enum JobStatus: String, Codable {
    case draft
    case finished
}

enum Svc {
    static func go() async throws {
        struct Params: Encodable { let p_shop: UUID }
        _ = try await Supa.client.rpc("create_job", params: Params(p_shop: UUID()))
        try await Supa.client.from("jobs").select("id").eq("statuz", value: "x").execute()
        try await Supa.client.from("jobs").update(["colour": "red"]).eq("id", value: "1").execute()
    }
}
'''})
    for needle in ("CodingKeys 'total_cents' is not a column of 'jobs'", "'jobs.total_cents' does not exist",
                   "Customer.firstName ('first_name') is non-optional but not in selectColumns",
                   "table/view 'vehicles' does not exist", "RPC 'missing_rpc' does not exist",
                   "raw values ['finished'] are not labels", "cannot decode Postgres labels ['scheduled', 'done']",
                   "has no argument 'p_shop'", "'jobs.statuz' does not exist", "update column 'jobs.colour'",
                   "TeamRow.CodingKeys 'nickname' is not a column returned by RPC 'shop_team'"):
        expect(f"Swift detects: {needle}", has(swift_bad, needle), "; ".join(swift_bad.errors))

    # --- Swift models without CodingKeys: property names are the keys -----------------
    implicit = run({"ios/DetailCRM/DetailCRM/Models/Implicit.swift": '''
// table: customers
struct CustomerRef: Codable, Hashable {
    var id: UUID
    var first_name: String
    let kind = "ref"
    var label: String { first_name }
}

// table: customers
struct CustomerCamel: Decodable {
    var id: UUID
    var firstName: String
}

// rpc: shop_team
struct TeamPlain: Codable {
    var member_id: UUID
    var nickname: String?
}

// rpc: shop_team
struct TeamDisplay: Hashable {
    var memberID: UUID
}
'''})
    expect("implicit keys: snake_case properties accepted",
           not has(implicit, "CustomerRef"), "; ".join(implicit.errors))
    expect("implicit keys: camelCase property is not a column",
           has(implicit, "CustomerCamel.property (no CodingKeys, so its name is the key) 'firstName' is not a "
                         "column of 'customers'"), "; ".join(implicit.errors))
    expect("implicit keys: RPC result property checked",
           has(implicit, "TeamPlain.property (no CodingKeys, so its name is the key) 'nickname' is not a column "
                         "returned by RPC 'shop_team'"), "; ".join(implicit.errors))
    expect("non-Codable annotated struct is not key-checked", not has(implicit, "TeamDisplay"),
           "; ".join(implicit.errors))

    # --- client directories that do not exist yet, or are empty -------------------------
    # (run() always writes the stub supabase/functions/payments/index.ts: 1 file)
    missing = run({})
    expect("missing web/ and ios/ directories are tolerated",
           not missing.errors and missing.counts.get("files") == 1, f"{missing.errors} {missing.counts}")
    empty = run({"web/src/.keep": "", "ios/DetailCRM/.keep": "", "ios/DetailCore/Sources/.keep": ""})
    expect("empty client directories are tolerated", not empty.errors and empty.counts.get("files") == 1,
           f"{empty.errors} {empty.counts}")
    with tempfile.TemporaryDirectory() as tmp:
        bare = run_checks(schema, Path(tmp))
    expect("a repo without any client directory checks nothing and passes",
           not bare.errors and bare.counts.get("files") == 0, f"{bare.errors} {bare.counts}")

    # --- tokenizer edge cases ---------------------------------------------------------
    toks = tokenize('let s = #"raw "quoted""#\nlet t = """\nmulti\n"""\n/* a /* nested */ b */ x', "swift")
    expect("swift raw + multi-line strings", [t.val for t in toks if t.kind == "str"] == ['raw "quoted"', "multi\n"],
           str([t.val for t in toks if t.kind == "str"]))
    expect("swift nested comments", toks[-1].val == "x")
    toks = tokenize("const a = x / 2; const r = /a'b/g; const s = 'ok'", "ts")
    expect("ts regex vs division", [t.val for t in toks if t.kind == "str"] == ["ok"],
           str([t.val for t in toks if t.kind == "str"]))

    # --- freshness: a stale generated file is detected -----------------------------------
    with tempfile.TemporaryDirectory() as tmp:
        repo = Path(tmp)
        (repo / "docs").mkdir()
        (repo / "docs/SCHEMA.md").write_text("old\n")
        files = {gen_types.MD_PATH: "new\n", gen_types.TS_PATH: "x\n"}
        stale = gen_types.stale_files(repo, files)
        expect("stale + missing generated files detected",
               stale == ["docs/SCHEMA.md", "web/src/lib/database.types.ts (missing)"], str(stale))
        (repo / "docs/SCHEMA.md").write_text("new\n")
        (repo / "web/src/lib").mkdir(parents=True)
        (repo / "web/src/lib/database.types.ts").write_text("x\n")
        expect("current generated files pass", gen_types.stale_files(repo, files) == [])

    if failures:
        for f in failures:
            print(f"self-test FAILED: {f}")
        return 1
    print("check_contracts self-test: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
