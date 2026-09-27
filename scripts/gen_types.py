#!/usr/bin/env python3
"""Contract generator for Detail CRM (SPEC section 8.2).

Builds the live schema exactly the way the test suite does — a throwaway
Postgres cluster from `scripts/test_db.sh --tests none --keep` (local Supabase
shim + every migration from zero) — introspects schema `public` through psql
and the pg catalogs, and writes:

  1. web/src/lib/database.types.ts — the exact shape `supabase gen types
     typescript` emits (a Python port of @supabase/postgrest-typegen 0.3.0, the
     code behind the CLI): Json, Database{public{Tables,Views,Functions,Enums,
     CompositeTypes}}, Tables<>/TablesInsert<>/TablesUpdate<>/Enums<>/
     CompositeTypes<> helpers and Constants, formatted with the web project's
     prettier (semi: false, like the CLI).
  2. docs/SCHEMA.md — the column-level contract: every table (columns, types,
     nullability, defaults, keys, FKs, checks, grants, RLS policies, triggers,
     realtime), enums, composite types, every public function (signature,
     return type, SECURITY DEFINER, EXECUTE roles, description, migration
     file), storage buckets with their object path conventions and
     storage.objects policies, grouped by the migration ranges of SPEC
     section 9.

The cluster is always stopped and removed at the end, even on error. Output
depends only on the shim + migrations (no timestamps), so `--check` can prove
the committed files are current; `scripts/check_contracts.py` runs the same
comparison and then checks every web / iOS / edge-function reference.

Usage:
  python3 scripts/gen_types.py                # regenerate both files
  python3 scripts/gen_types.py --check        # exit 1 if either file is stale
  python3 scripts/gen_types.py --dump-meta F  # also write the raw introspection JSON
  python3 scripts/gen_types.py --meta F       # render from a saved introspection JSON
  python3 scripts/gen_types.py --pg-env       # reuse an already migrated database named by
                                              # PGHOST/PGPORT/PGUSER/PGDATABASE (e.g. the cluster
                                              # `scripts/test_db.sh --keep` leaves running)
  python3 scripts/gen_types.py --self-test    # fixture schema → expected output (needs Postgres)
Options: --repo PATH, --ts-out PATH, --md-out PATH, --postgrest-version V.
Requires web/node_modules (prettier): run `npm ci` in web/ first.
"""
from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

DEFAULT_REPO = Path(__file__).resolve().parent.parent
TS_PATH = Path("web/src/lib/database.types.ts")
MD_PATH = Path("docs/SCHEMA.md")
SCHEMA = "public"
API_ROLES = ("anon", "authenticated", "service_role")


# --------------------------------------------------------------------------
# Collation: @supabase/postgrest-typegen orders everything with
# Intl.Collator("en"). This reproduces ICU root order for ASCII (whitespace,
# punctuation, symbols, digits, letters; case-insensitive primary level,
# lowercase first on ties).
# --------------------------------------------------------------------------
_ICU_ASCII = " _-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$0123456789abcdefghijklmnopqrstuvwxyz"
_RANK = {ch: i for i, ch in enumerate(_ICU_ASCII)}


def ckey(s: str):
    prim, tert = [], []
    for ch in s:
        lo = ch.lower()
        prim.append(_RANK.get(lo, 1000 + ord(lo)))
        tert.append(0 if ch == lo else 1)
    return (prim, tert)


def js(v) -> str:
    """JSON.stringify equivalent (no spaces, no ASCII escaping)."""
    return json.dumps(v, ensure_ascii=False, separators=(",", ":"))


IDENT_RE = re.compile(r"^[A-Za-z_$][A-Za-z0-9_$]*$")


# --------------------------------------------------------------------------
# Database access: a throwaway cluster via scripts/test_db.sh, or an already
# migrated database reached through the standard libpq environment.
# --------------------------------------------------------------------------
def _psql_json(psql: str, conn_args: list[str], sql: str, env: dict | None = None):
    """Run one SELECT through psql and return its rows as a list of dicts."""
    body = sql.strip().rstrip(";")
    wrapped = f"select coalesce(json_agg(t), '[]'::json) from (\n{body}\n) t"
    proc = subprocess.run(
        [psql, "-X", "-At", *conn_args, "-v", "ON_ERROR_STOP=1", "-c", wrapped],
        capture_output=True, text=True, env=env,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"query failed: {proc.stderr}\n--- sql ---\n{sql}")
    return json.loads(proc.stdout)


class Cluster:
    def __init__(self, repo: Path):
        self.repo = repo
        self.parent = None
        self.psql = None
        self.host = None
        self.port = None
        self.pg_bin = None

    def start(self):
        # Private short parent dir: the runner makes $WORK inside it, so on any
        # failure (even one where --keep left a server running) we can find
        # and stop every cluster it created. Must be traversable by the
        # postgres OS user when we run as root.
        self.parent = tempfile.mkdtemp(prefix="gt-", dir=os.environ.get("DB_TMPDIR") or "/tmp")
        os.chmod(self.parent, 0o755)
        env = dict(os.environ, DB_TMPDIR=self.parent)
        proc = subprocess.run(
            [str(self.repo / "scripts/test_db.sh"), "--tests", "none", "--keep"],
            cwd=self.repo, env=env, capture_output=True, text=True,
        )
        out = proc.stdout + proc.stderr
        if proc.returncode != 0:
            raise RuntimeError(f"scripts/test_db.sh failed (exit {proc.returncode}):\n{out}")
        m = re.search(r"^\s*(\S*psql) -h (\S+) -p (\d+) -U postgres -d postgres\s*$", out, re.M)
        if not m:
            raise RuntimeError(f"could not parse connection info from runner output:\n{out}")
        self.psql, self.host, self.port = m.group(1), m.group(2), m.group(3)
        self.pg_bin = os.path.dirname(self.psql)
        applied = re.search(r"applied shim \+ (\d+) migration", out)
        return int(applied.group(1)) if applied else None

    def stop(self):
        if not self.parent:
            return
        pg_bin = self.pg_bin or _guess_pg_bin()
        as_pg = ["runuser", "-u", "postgres", "--"] if os.geteuid() == 0 else []
        for work in glob.glob(os.path.join(self.parent, "dcrm-db.*")):
            data = os.path.join(work, "data")
            if pg_bin and os.path.exists(os.path.join(data, "postmaster.pid")):
                subprocess.run(as_pg + [os.path.join(pg_bin, "pg_ctl"), "-D", data, "-m", "immediate", "-w", "stop"],
                               capture_output=True)
        shutil.rmtree(self.parent, ignore_errors=True)
        self.parent = None

    def query(self, sql: str):
        return _psql_json(self.psql, ["-h", self.host, "-p", self.port, "-U", "postgres", "-d", "postgres"], sql)


PG_ENV_VARS = ("PGHOST", "PGPORT", "PGUSER", "PGDATABASE", "PGSERVICE", "DATABASE_URL")


class EnvDatabase:
    """An already migrated database (shim + every migration) reached through
    the libpq environment: PGHOST/PGPORT/PGUSER/PGDATABASE/PGPASSWORD or
    PGSERVICE, or DATABASE_URL (a postgres:// URI). Nothing is created or
    stopped; the connecting role must be able to read the catalogs and call
    has_*_privilege for anon/authenticated/service_role (a superuser, as in
    the throwaway cluster)."""

    def __init__(self, env: dict | None = None):
        self.env = dict(os.environ if env is None else env)
        if not any(self.env.get(v) for v in PG_ENV_VARS):
            raise GenError("--pg-env needs a connection in the environment: set PGHOST (and PGPORT/PGUSER/"
                           "PGDATABASE/PGPASSWORD as needed), PGSERVICE, or DATABASE_URL")
        pg_bin = self.env.get("PG_BIN") or _guess_pg_bin()
        cand = os.path.join(pg_bin, "psql") if pg_bin else None
        self.psql = cand if cand and os.access(cand, os.X_OK) else shutil.which("psql", path=self.env.get("PATH"))
        if not self.psql:
            raise GenError("psql not found (set PG_BIN or put psql on PATH)")
        url = self.env.get("DATABASE_URL")
        self.conn_args = ["-d", url] if url and not self.env.get("PGHOST") and not self.env.get("PGSERVICE") else []

    def query(self, sql: str):
        return _psql_json(self.psql, self.conn_args, sql, env=self.env)


def _guess_pg_bin():
    cands = sorted(glob.glob("/usr/lib/postgresql/*/bin"), key=lambda p: [int(x) if x.isdigit() else x for x in re.split(r"(\d+)", p)])
    return os.environ.get("PG_BIN") or (cands[-1] if cands else None)


# --------------------------------------------------------------------------
# Introspection queries (schema public; types from every schema, like
# postgres-meta, so enum/composite/relation names resolve).
# --------------------------------------------------------------------------
Q_TYPES = """
select t.oid::int8 as id, t.typname as name, n.nspname as schema, format_type(t.oid, null) as format,
  coalesce((select json_agg(e.enumlabel order by e.enumsortorder) from pg_enum e where e.enumtypid = t.oid), '[]'::json) as enums,
  coalesce((select json_agg(json_build_object('name', a.attname, 'type_id', a.atttypid::int8,
                                              'full_type', format_type(a.atttypid, a.atttypmod)) order by a.attnum)
            from pg_class c join pg_attribute a on a.attrelid = c.oid
            where c.oid = t.typrelid and c.relkind = 'c' and not a.attisdropped), '[]'::json) as attributes,
  nullif(t.typrelid::int8, 0) as type_relation_id,
  obj_description(t.oid, 'pg_type') as comment
from pg_type t join pg_namespace n on n.oid = t.typnamespace
where t.typrelid = 0
   or (select c.relkind in ('c', 'r', 'v', 'm', 'p', 'f') from pg_class c where c.oid = t.typrelid)
"""

Q_RELATIONS = """
select c.oid::int8 as id, n.nspname as schema, c.relname as name, c.relkind as kind,
  c.relrowsecurity as rls_enabled, c.relforcerowsecurity as rls_forced,
  coalesce(c.reloptions::text[] && array['security_invoker=true', 'security_invoker=on', 'security_invoker=1'], false)
    as security_invoker,
  obj_description(c.oid, 'pg_class') as comment,
  case when c.relkind = 'v' then (pg_relation_is_updatable(c.oid, false) & 20) = 20 end as is_updatable,
  case when c.relkind = 'v' then (pg_relation_is_updatable(c.oid, true) & 8) = 8 end as is_insert_enabled,
  case when c.relkind = 'v' then (pg_relation_is_updatable(c.oid, true) & 4) = 4 end as is_update_enabled
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm', 'f')
"""

Q_COLUMNS = """
select c.oid::int8 as table_id, c.relname as table, a.attnum as ordinal_position, a.attname as name,
  case when a.atthasdef then pg_get_expr(ad.adbin, ad.adrelid) end as default_value,
  coalesce(bt.typname, t.typname) as format,
  coalesce(nbt.nspname, nt.nspname) as type_schema,
  format_type(a.atttypid, a.atttypmod) as full_type,
  a.attidentity in ('a', 'd') as is_identity,
  case a.attidentity when 'a' then 'ALWAYS' when 'd' then 'BY DEFAULT' end as identity_generation,
  a.attgenerated in ('s', 'v') as is_generated,
  not (a.attnotnull or (t.typtype = 'd' and t.typnotnull)) as is_nullable,
  (c.relkind in ('r', 'p')
   or c.relkind in ('v', 'f') and (
        pg_column_is_updatable(c.oid, a.attnum, false)
     or exists (select 1 from pg_trigger tg where tg.tgrelid = c.oid and tg.tgtype & 64 <> 0
                  and tg.tgtype & 20 <> 0 and not tg.tgisinternal)
     or exists (select 1 from pg_rewrite rw where rw.ev_class = c.oid and rw.is_instead
                  and rw.ev_type in ('2', '3') and rw.ev_qual::text = '<>'))) as is_updatable,
  col_description(c.oid, a.attnum) as comment
from pg_attribute a
  left join pg_attrdef ad on a.attrelid = ad.adrelid and a.attnum = ad.adnum
  join pg_class c on a.attrelid = c.oid
  join pg_namespace nc on c.relnamespace = nc.oid
  join pg_type t on a.atttypid = t.oid
  join pg_namespace nt on t.typnamespace = nt.oid
  left join (pg_type bt join pg_namespace nbt on bt.typnamespace = nbt.oid)
    on t.typtype = 'd' and t.typbasetype = bt.oid
where nc.nspname = 'public' and a.attnum > 0 and not a.attisdropped
  and c.relkind in ('r', 'v', 'm', 'f', 'p')
"""

# Port of postgres-meta TABLE_RELATIONSHIPS_SQL (PostgREST SchemaCache m2o/o2o).
Q_RELATIONSHIPS = """
with pks_uniques_cols as (
  select connamespace, conrelid, jsonb_agg(column_info.cols) as cols
  from pg_constraint
  join lateral (
    select array_agg(cols.attname order by cols.attnum) as cols
    from (select unnest(conkey) as col) _
    join pg_attribute cols on cols.attrelid = conrelid and cols.attnum = col
  ) column_info on true
  where contype in ('p', 'u') and connamespace::regnamespace::text <> 'pg_catalog'
    and connamespace::regnamespace::text in ('public')
  group by connamespace, conrelid
)
select traint.conname as foreign_key_name, ns1.nspname as schema, tab.relname as relation,
  column_info.cols as columns, ns2.nspname as referenced_schema, other.relname as referenced_relation,
  column_info.refs as referenced_columns,
  (column_info.cols in (select * from jsonb_array_elements(pks_uqs.cols))) as is_one_to_one
from pg_constraint traint
join lateral (
  select jsonb_agg(cols.attname order by ord) as cols, jsonb_agg(refs.attname order by ord) as refs
  from unnest(traint.conkey, traint.confkey) with ordinality as _(col, ref, ord)
  join pg_attribute cols on cols.attrelid = traint.conrelid and cols.attnum = col
  join pg_attribute refs on refs.attrelid = traint.confrelid and refs.attnum = ref
  where traint.connamespace::regnamespace::text in ('public')
) as column_info on true
join pg_namespace ns1 on ns1.oid = traint.connamespace
join pg_class tab on tab.oid = traint.conrelid
join pg_class other on other.oid = traint.confrelid
join pg_namespace ns2 on ns2.oid = other.relnamespace
left join pks_uniques_cols pks_uqs on pks_uqs.connamespace = traint.connamespace and pks_uqs.conrelid = traint.conrelid
where traint.contype = 'f' and traint.conparentid = 0 and ns1.nspname in ('public')
"""

Q_FUNCTIONS = """
select p.oid::int8 as id, n.nspname as schema, p.proname as name, p.prokind as kind,
  l.lanname as language,
  pg_get_function_arguments(p.oid) as argument_types,
  pg_get_function_identity_arguments(p.oid) as identity_argument_types,
  p.prorettype::int8 as return_type_id,
  pg_get_function_result(p.oid) as return_type,
  nullif(rt.typrelid::int8, 0) as return_type_relation_id,
  p.proretset as is_set_returning_function,
  case when p.proretset then nullif(p.prorows, 0) end as prorows,
  p.provolatile as volatility, p.prosecdef as security_definer, p.proconfig as config,
  p.pronargdefaults as nargdefaults,
  p.proargmodes::text[] as argmodes, p.proargnames as argnames,
  coalesce(p.proallargtypes::int8[], p.proargtypes::oid[]::int8[]) as argtypes,
  obj_description(p.oid, 'pg_proc') as comment,
  has_function_privilege('anon', p.oid, 'EXECUTE') as exec_anon,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') as exec_authenticated,
  has_function_privilege('service_role', p.oid, 'EXECUTE') as exec_service_role,
  exists (select 1 from pg_depend d where d.classid = 'pg_proc'::regclass and d.objid = p.oid
            and d.deptype = 'e') as is_extension_member
from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  left join pg_language l on l.oid = p.prolang
  left join pg_type rt on rt.oid = p.prorettype
where n.nspname = 'public' and p.prokind in ('f', 'p')
"""

Q_CONSTRAINTS = """
select c.relname as table, k.conname as name, k.contype as type,
  pg_get_constraintdef(k.oid, true) as def,
  (select array_agg(a.attname order by x.ord) from unnest(k.conkey) with ordinality x(attnum, ord)
     join pg_attribute a on a.attrelid = k.conrelid and a.attnum = x.attnum) as columns
from pg_constraint k join pg_class c on c.oid = k.conrelid
where c.relnamespace = 'public'::regnamespace and k.conrelid <> 0
"""

Q_UNIQUE_INDEXES = """
select c.relname as table, i.relname as name, pg_get_indexdef(x.indexrelid) as def
from pg_index x join pg_class i on i.oid = x.indexrelid join pg_class c on c.oid = x.indrelid
where c.relnamespace = 'public'::regnamespace and x.indisunique
  and not exists (select 1 from pg_constraint k where k.conindid = x.indexrelid and k.conrelid = x.indrelid)
"""

Q_POLICIES = """
select schemaname as schema, tablename as table, policyname as name, permissive, roles, cmd, qual, with_check
from pg_policies where schemaname in ('public', 'storage')
"""

Q_TRIGGERS = """
select cn.nspname as table_schema, c.relname as table, t.tgname as name, pg_get_triggerdef(t.oid) as def,
  p.proname as function, pn.nspname as function_schema, not t.tgenabled = 'D' as enabled
from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace cn on cn.oid = c.relnamespace
  join pg_proc p on p.oid = t.tgfoid join pg_namespace pn on pn.oid = p.pronamespace
where (cn.nspname = 'public' or pn.nspname = 'public') and not t.tgisinternal
"""

Q_TABLE_PRIVS = """
select c.relname as table, r.rolname as role,
  has_table_privilege(r.oid, c.oid, 'SELECT') as s, has_table_privilege(r.oid, c.oid, 'INSERT') as i,
  has_table_privilege(r.oid, c.oid, 'UPDATE') as u, has_table_privilege(r.oid, c.oid, 'DELETE') as d
from pg_class c cross join pg_roles r
where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p', 'v', 'm', 'f')
  and r.rolname in ('anon', 'authenticated', 'service_role')
"""

Q_COLUMN_PRIVS = """
select c.relname as table, r.rolname as role, a.attname as column, a.attnum,
  has_column_privilege(r.oid, c.oid, a.attnum, 'SELECT') as s,
  has_column_privilege(r.oid, c.oid, a.attnum, 'INSERT') as i,
  has_column_privilege(r.oid, c.oid, a.attnum, 'UPDATE') as u
from pg_class c join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
  cross join pg_roles r
where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p', 'v', 'm', 'f')
  and r.rolname in ('anon', 'authenticated')
"""

Q_PUBLICATION = """
select pubname, schemaname as schema, tablename as table, attnames, rowfilter
from pg_publication_tables where pubname = 'supabase_realtime'
"""

Q_BUCKETS = """
select to_jsonb(b) as b from storage.buckets b
"""

Q_STORAGE_EXISTS = """
select exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                where n.nspname = 'storage' and c.relname = 'buckets') as ok
"""


def introspect(db: Cluster) -> dict:
    meta = {
        "types": db.query(Q_TYPES),
        "relations": db.query(Q_RELATIONS),
        "columns": db.query(Q_COLUMNS),
        "relationships": db.query(Q_RELATIONSHIPS),
        "functions": db.query(Q_FUNCTIONS),
        "constraints": db.query(Q_CONSTRAINTS),
        "unique_indexes": db.query(Q_UNIQUE_INDEXES),
        "policies": db.query(Q_POLICIES),
        "triggers": db.query(Q_TRIGGERS),
        "table_privs": db.query(Q_TABLE_PRIVS),
        "column_privs": db.query(Q_COLUMN_PRIVS),
        "publication": db.query(Q_PUBLICATION),
        "buckets": [],
    }
    if db.query(Q_STORAGE_EXISTS)[0]["ok"]:
        meta["buckets"] = [r["b"] for r in db.query(Q_BUCKETS)]
    # Normalise function args exactly like postgres-meta's FUNCTIONS_SQL
    # (modes in/out/inout/variadic/table; unnamed = ""), with has_default on
    # the trailing pronargdefaults *input* args.
    mode_map = {"i": "in", "o": "out", "b": "inout", "v": "variadic", "t": "table"}
    for f in meta["functions"]:
        types = f["argtypes"] or []
        n = len(types)
        modes = f["argmodes"] or ["i"] * n
        names = f["argnames"] or [""] * n
        inputs = [i for i, m in enumerate(modes) if m in ("i", "b", "v")]
        nd = f["nargdefaults"] or 0
        with_default = set(inputs[len(inputs) - nd:]) if nd else set()
        f["args_declared"] = [
            {"mode": mode_map[modes[i]], "name": names[i] if i < len(names) else "", "type_id": types[i],
             "has_default": i in with_default}
            for i in range(n)
        ]
        # typegen addresses RPC args by name → sorted by name (sortGeneratorMetadata)
        f["args"] = sorted(f["args_declared"], key=lambda a: ckey(a["name"]))
    return meta


# --------------------------------------------------------------------------
# TypeScript generation — port of @supabase/postgrest-typegen 0.3.0
# generateTypescript(meta, {detectOneToOneRelationships: true, postgrestVersion})
# --------------------------------------------------------------------------
HELPER_TYPES = '''type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    keyof DefaultSchema["Tables"] | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    keyof DefaultSchema["Tables"] | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    keyof DefaultSchema["Enums"] | { schema: keyof DatabaseWithoutInternals },
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never) = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never) = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never
'''

VALID_UNNAMED_FUNCTION_ARG_TYPES = {114, 3802, 25}  # json, jsonb, text
VALID_FUNCTION_ARGS_MODE = {"in", "inout", "variadic"}
STRING_TYPES = {"bytea", "bpchar", "varchar", "date", "text", "citext", "time", "timetz", "timestamp",
                "timestamptz", "uuid", "vector", "interval"}


def indent_tail(text: str, pad: str) -> str:
    """Indent every line after the first (for embedding multi-line blocks)."""
    return text.replace("\n", "\n" + pad)


class TsGen:
    def __init__(self, meta: dict, postgrest_version: str | None, quote_keys: bool):
        self.quote_keys = quote_keys
        self.postgrest_version = postgrest_version
        self.schemas = [SCHEMA]
        types = sorted(meta["types"], key=lambda t: (ckey(t["schema"]), ckey(t["name"]), t["id"]))
        self.types = types
        self.types_by_id = {t["id"]: t for t in types}
        self.types_by_name = defaultdict(list)
        for t in types:
            self.types_by_name[t["name"]].append(t)
        self.relation_type_by_id = {t["id"]: t for t in types if t["type_relation_id"]}
        rels = meta["relations"]
        rel_sort = lambda r: (ckey(r["schema"]), ckey(r["name"]), r["id"])  # noqa: E731
        self.tables = sorted([r for r in rels if r["kind"] in ("r", "p")], key=rel_sort)
        self.foreign_tables = sorted([r for r in rels if r["kind"] == "f"], key=rel_sort)
        self.views = sorted([r for r in rels if r["kind"] == "v"], key=rel_sort)
        self.mat_views = sorted([r for r in rels if r["kind"] == "m"], key=rel_sort)
        for mv in self.mat_views:
            mv.update(is_updatable=False, is_insert_enabled=False, is_update_enabled=False)
        self.table_names_by_id = {r["id"]: r["name"] for r in self.tables + self.foreign_tables + self.views + self.mat_views}
        self.columns_by_table = defaultdict(list)
        for c in sorted(meta["columns"], key=lambda c: (ckey(c["table"]), ckey(c["name"]))):
            self.columns_by_table[c["table_id"]].append(c)
        def rel_key(r):
            return (ckey(r["foreign_key_name"]), ckey(r["referenced_relation"]), ckey(js(r["referenced_columns"])),
                    ckey(r["referenced_schema"]), ckey(r["schema"]), ckey(r["relation"]), ckey(js(r["columns"])))
        self.relationships = sorted(meta["relationships"], key=rel_key)
        fns = [f for f in meta["functions"] if f["kind"] == "f" and f["return_type"] not in ("trigger", "event_trigger")]
        fns.sort(key=lambda f: (ckey(f["schema"]), ckey(f["name"]), ckey(f["identity_argument_types"]), f["id"]))
        self.all_functions = fns
        self.warnings = []
        if self.views or self.mat_views:
            self.warnings.append("views present: view-derived relationships (FKs through views) are not expanded")

    # ---- helpers ---------------------------------------------------------
    def key(self, name: str) -> str:
        return js(name) if (self.quote_keys or not IDENT_RE.match(name)) else name

    def pg_to_ts(self, pg: str, type_schema: str | None = None) -> str:
        if pg == "bool":
            return "boolean"
        if pg in ("int2", "int4", "int8", "float4", "float8", "numeric"):
            return "number"
        if pg in STRING_TYPES:
            return "string"
        if pg in ("json", "jsonb"):
            return "Json"
        if pg == "void":
            return "undefined"
        if pg == "record":
            return "Record<string, unknown>"
        if pg.startswith("_"):
            inner = self.pg_to_ts(pg[1:], type_schema)
            return f"({inner})[]" if "|" in inner else f"{inner}[]"
        preferred = type_schema or SCHEMA
        cands = self.types_by_name.get(pg, [])
        enums = [t for t in cands if t["enums"]]
        if enums:
            e = next((t for t in enums if t["schema"] == preferred), enums[0])
            if e["schema"] in self.schemas:
                return f'Database[{js(e["schema"])}]["Enums"][{js(e["name"])}]'
            return " | ".join(js(v) for v in e["enums"])
        comps = [t for t in cands if t["attributes"]]
        if comps:
            c = next((t for t in comps if t["schema"] == preferred), comps[0])
            if c["schema"] in self.schemas:
                return f'Database[{js(c["schema"])}]["CompositeTypes"][{js(c["name"])}]'
            return "unknown"
        kinds = [("Tables", self.tables), ("Tables", self.foreign_tables), ("Views", self.views), ("Views", self.mat_views)]
        for pred in (lambda r: r["name"] == pg and r["schema"] == preferred, lambda r: r["name"] == pg):
            for kind, rels in kinds:
                r = next((x for x in rels if pred(x)), None)
                if r:
                    if r["schema"] in self.schemas:
                        return f'Database[{js(r["schema"])}]["{kind}"][{js(r["name"])}]["Row"]'
                    return "unknown"
        return "unknown"

    def type_ts(self, type_id) -> str:
        t = self.types_by_id.get(type_id)
        return self.pg_to_ts(t["name"], t["schema"]) if t else "unknown"

    @staticmethod
    def nullable_union(ts: str, is_nullable: bool) -> str:
        if ts == "Json" and not is_nullable:
            return "NonNullable<Json>"
        if ts in ("unknown", "any") or not is_nullable:
            return ts
        return f"{ts} | null"

    def column_def(self, col, is_nullable: bool, is_optional: bool) -> str:
        ts = self.nullable_union(self.pg_to_ts(col["format"], col["type_schema"]), is_nullable)
        return f'{self.key(col["name"])}{"?" if is_optional else ""}: {ts}'

    def cols(self, rel_id):
        if rel_id not in self.table_names_by_id:
            raise RuntimeError(f"Relation {rel_id} is missing from the generator metadata")
        return self.columns_by_table.get(rel_id, [])

    def relationships_for(self, rel):
        return [r for r in self.relationships
                if r["schema"] == rel["schema"] and r["relation"] == rel["name"] and r["referenced_schema"] == rel["schema"]]

    def rel_def(self, r) -> str:
        return ("{\n"
                f"  foreignKeyName: {js(r['foreign_key_name'])}\n"
                f"  columns: {self.arr(r['columns'])}\n"
                f"  isOneToOne: {'true' if r['is_one_to_one'] else 'false'}\n"
                f"  referencedRelation: {js(r['referenced_relation'])}\n"
                f"  referencedColumns: {self.arr(r['referenced_columns'])}\n"
                "}")

    @staticmethod
    def arr(values) -> str:
        return "[" + ", ".join(js(v) for v in values) + "]"

    def table_name_from_relation_id(self, relation_id, return_type_id):
        if not relation_id:
            return None
        name = self.table_names_by_id.get(relation_id)
        if name:
            return name
        rt = self.relation_type_by_id.get(return_type_id) if return_type_id else None
        return rt["name"] if rt else None

    # ---- functions -------------------------------------------------------
    def schema_functions(self):
        out = []
        for fn in self.all_functions:
            in_args = [a for a in fn["args"] if a["mode"] in VALID_FUNCTION_ARGS_MODE]
            sole = in_args[0] if len(in_args) == 1 else None
            ok = (
                len(in_args) == 0
                or not any(a["name"] == "" for a in in_args)
                or all((a["has_default"] and a["type_id"] in VALID_UNNAMED_FUNCTION_ARG_TYPES) if a["name"] == "" else True
                       for a in in_args)
                or (sole is not None and sole["name"] == ""
                    and (sole["type_id"] in VALID_UNNAMED_FUNCTION_ARG_TYPES or sole["type_id"] in self.relation_type_by_id))
            )
            if ok:
                out.append((fn, in_args))
        out.sort(key=lambda p: ckey(p[0]["name"]))  # stable, like Array#sort
        return out

    def fn_return_type(self, fn) -> str:
        table_args = [a for a in fn["args"] if a["mode"] == "table"]
        if table_args:
            members = "\n".join(f'  {self.key(a["name"])}: {self.type_ts(a["type_id"])}' for a in table_args)
            return "{\n" + members + "\n}"
        rel = next((t for t in self.tables + self.foreign_tables if t["id"] == fn["return_type_relation_id"]), None) or \
            next((v for v in self.views + self.mat_views if v["id"] == fn["return_type_relation_id"]), None)
        if rel:
            members = "\n".join("  " + self.column_def(c, c["is_nullable"], False) for c in self.cols(rel["id"]))
            return "{\n" + members + "\n}"
        return self.type_ts(fn["return_type_id"])

    def fn_ts_return_type(self, fn, return_type: str) -> str:
        setof = ""
        ret_table = self.table_name_from_relation_id(fn["return_type_relation_id"], fn["return_type_id"])
        returns_setof_table = fn["is_set_returning_function"] and fn["return_type_relation_id"] is not None
        multi = fn["prorows"] is not None and fn["prorows"] > 1

        def so(frm, to, one, setret):
            return ("SetofOptions: {\n"
                    f"  from: {js(frm)}\n  to: {js(to)}\n"
                    f"  isOneToOne: {'true' if one else 'false'}\n  isSetofReturn: {'true' if setret else 'false'}\n"
                    "}")
        if ret_table:
            setof = so("*", ret_table, not multi, fn["is_set_returning_function"])
        sole = fn["args"][0] if len(fn["args"]) == 1 else None
        if sole:
            rtype = self.relation_type_by_id.get(sole["type_id"])
            if rtype:
                src = rtype["format"]
                if returns_setof_table and ret_table:
                    setof = so(src, ret_table, not multi, True)
                elif ret_table and not returns_setof_table:
                    setof = so(src, ret_table, True, False)
        collapsible = (not multi) and ret_table is not None
        suffix = "[]" if fn["is_set_returning_function"] and not collapsible else ""
        return f"{return_type}{suffix}" + (f"\n{setof}" if setof else "")

    def has_table_row_error(self, fn, in_args) -> bool:
        sole = in_args[0] if len(in_args) == 1 else None
        return bool(sole and sole["name"] == "" and sole["type_id"] in self.relation_type_by_id
                    and not self.table_name_from_relation_id(fn["return_type_relation_id"], fn["return_type_id"]))

    def conflict_error(self, fns, fn, in_args):
        if len(fns) <= 1:
            return None
        sole = in_args[0] if len(in_args) == 1 else None
        if len(in_args) == 0:
            for other, other_in in fns:
                if other is fn:
                    continue
                osole = other_in[0] if len(other_in) == 1 else None
                if osole and osole["name"] == "" and osole["has_default"]:
                    rt = self.types_by_id.get(other["return_type_id"], {}).get("name", "unknown")
                    return (f"Could not choose the best candidate function between: {SCHEMA}.{fn['name']}(), "
                            f"{SCHEMA}.{fn['name']}( => {rt}). Try renaming the parameters or the function itself "
                            "in the database so function overloading can be resolved")
        if sole and sole["name"] != "":
            conflicting = []
            for other, other_in in fns:
                if other is fn:
                    continue
                osole = other_in[0] if len(other_in) == 1 else None
                if osole and osole["name"] == sole["name"] and osole["type_id"] != sole["type_id"]:
                    conflicting.append((other, other_in))
            if conflicting:
                allc = sorted([(fn, in_args)] + conflicting, key=lambda p: (p[1][0]["type_id"] if p[1] else 0))
                lst = ", ".join(
                    f"{SCHEMA}.{fn['name']}(" + ", ".join(
                        f"{a['name'] or ''} => {self.types_by_id.get(a['type_id'], {}).get('name', 'unknown')}" for a in args
                    ) + ")" for _f, args in allc)
                return (f"Could not choose the best candidate function between: {lst}. Try renaming the parameters "
                        "or the function itself in the database so function overloading can be resolved")
        return None

    def args_type(self, in_args) -> str:
        parts = [f'{self.key(a["name"])}{"?" if a["has_default"] else ""}: {self.type_ts(a["type_id"])}' for a in in_args]
        return "{ " + "; ".join(parts) + " }"

    def fn_signatures(self, fns) -> str:
        sigs = []
        for fn, in_args in fns:
            args_type = "Record<PropertyKey, never>"
            ret = self.fn_return_type(fn)
            conflict = self.conflict_error(fns, fn, in_args)
            if conflict:
                if in_args:
                    args_type = self.args_type(in_args)
                ret = "{ error: true } & " + js(conflict)
            elif self.has_table_row_error(fn, in_args):
                if in_args:
                    args_type = self.args_type(in_args)
                ret = "{ error: true } & " + js(
                    f"the function {SCHEMA}.{fn['name']} with parameter or with a single unnamed json/jsonb "
                    "parameter, but no matches were found in the schema cache")
            elif in_args:
                args_type = self.args_type(in_args)
            body = self.fn_ts_return_type(fn, ret)
            sigs.append("{ Args: " + args_type + "; Returns: " + indent_tail(body, "  ") + " }")
        return "\n| ".join(sigs)

    def computed_fields(self, sfns, rel):
        out = []
        for fn, in_args in sfns:
            sole = in_args[0] if len(in_args) == 1 else None
            hit = False
            if sole:
                at = self.relation_type_by_id.get(sole["type_id"])
                if at:
                    hit = at["type_relation_id"] == rel["id"]
                else:
                    hit = fn["argument_types"] == rel["name"]
            else:
                hit = fn["argument_types"] == rel["name"]
            if hit:
                out.append(f'{self.key(fn["name"])}: {self.nullable_union(self.fn_return_type(fn), True)}')
        return out

    # ---- document ----------------------------------------------------------
    def generate(self) -> str:
        sfns = self.schema_functions()
        P = "  "

        def block(members, pad):
            if not members:
                return "{\n" + pad + P + "[_ in never]: never\n" + pad + "}"
            return "{\n" + "\n".join(pad + P + indent_tail(m, pad + P) for m in members) + "\n" + pad + "}"

        # Tables
        table_members = []
        for t in sorted(self.tables + self.foreign_tables, key=lambda r: ckey(r["name"])):
            cols = self.cols(t["id"])
            row = [self.column_def(c, c["is_nullable"], False) for c in cols] + self.computed_fields(sfns, t)
            ins, upd = [], []
            for c in cols:
                if c["identity_generation"] == "ALWAYS" or c["is_generated"]:
                    ins.append(f'{self.key(c["name"])}?: never')
                    upd.append(f'{self.key(c["name"])}?: never')
                    continue
                ins.append(self.column_def(c, c["is_nullable"],
                                           c["is_nullable"] or c["is_identity"] or c["default_value"] is not None))
                upd.append(self.column_def(c, c["is_nullable"], True))
            rels = self.relationships_for(t)
            members = [
                "Row: " + block(row, ""),
                "Insert: " + block(ins, ""),
                "Update: " + block(upd, ""),
                "Relationships: [" + ("\n" + ",\n".join(P + indent_tail(self.rel_def(r), P) for r in rels) + "\n]" if rels else "]"),
            ]
            table_members.append(f'{self.key(t["name"])}: ' + block(members, ""))

        # Views
        view_members = []
        for v in sorted(self.views + self.mat_views, key=lambda r: ckey(r["name"])):
            cols = self.cols(v["id"])
            row = [self.column_def(c, c["is_nullable"], False) for c in cols] + self.computed_fields(sfns, v)
            members = ["Row: " + block(row, "")]
            ins_enabled = v.get("is_insert_enabled") if v.get("is_insert_enabled") is not None else v.get("is_updatable")
            upd_enabled = v.get("is_update_enabled") if v.get("is_update_enabled") is not None else v.get("is_updatable")
            def vcols():
                return [f'{self.key(c["name"])}?: never' if not c["is_updatable"] else self.column_def(c, True, True) for c in cols]
            if ins_enabled:
                members.append("Insert: " + block(vcols(), ""))
            if upd_enabled:
                members.append("Update: " + block(vcols(), ""))
            rels = self.relationships_for(v)
            members.append("Relationships: [" + ("\n" + ",\n".join(P + indent_tail(self.rel_def(r), P) for r in rels) + "\n]" if rels else "]"))
            view_members.append(f'{self.key(v["name"])}: ' + block(members, ""))

        # Functions (grouped by name; variants by argument_types then return_type)
        grouped: dict[str, list] = {}
        for fn, in_args in sfns:
            grouped.setdefault(fn["name"], []).append((fn, in_args))
        fn_members = []
        for name, fns in grouped.items():
            fns.sort(key=lambda p: (ckey(p[0]["argument_types"]), ckey(p[0]["return_type"])))
            sig = self.fn_signatures(fns)
            if len(fns) > 1:
                sig = "\n| " + sig
            fn_members.append(f"{self.key(name)}: " + sig)

        enums = sorted([t for t in self.types if t["schema"] == SCHEMA and t["enums"]], key=lambda t: ckey(t["name"]))
        comps = sorted([t for t in self.types if t["schema"] == SCHEMA and t["attributes"]], key=lambda t: ckey(t["name"]))
        enum_members = [f'{self.key(e["name"])}: ' + " | ".join(js(v) for v in e["enums"]) for e in enums]
        comp_members = []
        for c in comps:
            attrs = []
            for a in c["attributes"]:
                t = self.types_by_id.get(a["type_id"])
                ts = self.nullable_union(self.pg_to_ts(t["name"], t["schema"]), True) if t else "unknown"
                attrs.append(f'{self.key(a["name"])}: {ts}')
            comp_members.append(f'{self.key(c["name"])}: ' + block(attrs, ""))

        schema_block = block([
            "Tables: " + block(table_members, ""),
            "Views: " + block(view_members, ""),
            "Functions: " + block(fn_members, ""),
            "Enums: " + block(enum_members, ""),
            "CompositeTypes: " + block(comp_members, ""),
        ], "")

        internal = ""
        if self.postgrest_version:
            internal = ("  // Allows to automatically instantiate createClient with right options\n"
                        "  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)\n"
                        "  __InternalSupabase: {\n"
                        f"    PostgrestVersion: {js(self.postgrest_version)}\n"
                        "  }\n")
        constants_enums = [f'{self.key(e["name"])}: [' + ", ".join(js(v) for v in e["enums"]) + "]," for e in enums]
        out = []
        out.append("// Generated by scripts/gen_types.py from the live schema (supabase/shim +\n"
                   "// supabase/migrations applied from zero). Same shape as `supabase gen types\n"
                   "// typescript` (@supabase/postgrest-typegen). Do not edit by hand: change a\n"
                   "// migration, then run `python3 scripts/gen_types.py`.\n\n")
        out.append("export type Json =\n  | string\n  | number\n  | boolean\n  | null\n"
                   "  | { [key: string]: Json | undefined }\n  | Json[]\n\n")
        out.append("export type Database = {\n" + internal + f"  {self.key(SCHEMA)}: " + indent_tail(schema_block, "  ") + "\n}\n\n")
        out.append(HELPER_TYPES + "\n")
        out.append("export const Constants = {\n"
                   f"  {self.key(SCHEMA)}: {{\n"
                   "    Enums: {\n" + "".join(f"      {m}\n" for m in constants_enums) + "    },\n"
                   "  },\n"
                   "} as const\n")
        return "".join(out)


def prettier_format(code: str, repo: Path) -> str | None:
    exe = repo / "web/node_modules/.bin/prettier"
    if not exe.exists():
        return None
    proc = subprocess.run([str(exe), "--no-config", "--no-editorconfig", "--no-semi", "--parser", "typescript"],
                          input=code, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"prettier failed:\n{proc.stderr}")
    return proc.stdout


# --------------------------------------------------------------------------
# Migration-file scan (for SCHEMA.md grouping + leading comment blocks)
# --------------------------------------------------------------------------
RE_TABLE = re.compile(r"^\s*create\s+(?:table\s+(?:if\s+not\s+exists\s+)?|(?:or\s+replace\s+)?(?:materialized\s+)?view\s+"
                      r"(?:if\s+not\s+exists\s+)?)(?:public\.)?\"?(\w+)\"?\s*[(\s]", re.I | re.M)
RE_FUNC = re.compile(r"^\s*create\s+(?:or\s+replace\s+)?function\s+(?:public\.)?\"?(\w+)\"?\s*\(", re.I | re.M)
RE_TYPE = re.compile(r"^\s*create\s+type\s+(?:public\.)?\"?(\w+)\"?\s+as\b", re.I | re.M)
RE_TOUCH = re.compile(r"\b(?:alter\s+table\s+(?:only\s+)?(?:if\s+exists\s+)?|create\s+policy\s+(?:\"[^\"]+\"|\S+)\s+on\s+|"
                      r"create\s+(?:constraint\s+)?trigger\s+\w+\s+(?:[\w\s,]+?)\s+on\s+)(?:public\.)?(\w+)", re.I)
RULE_RE = re.compile(r"^[\s\-=_*#~─━═]*$")


def comment_above(lines, idx):
    out = []
    j = idx - 1
    while j >= 0 and lines[j].lstrip().startswith("--"):
        out.append(lines[j].strip()[2:].strip())
        j -= 1
    out.reverse()
    out = [x for x in out if not RULE_RE.match(x)]
    return re.sub(r"\s+", " ", " ".join(out)).strip()


def listed_in_comments(lines, name):
    """A comment line that *starts* with the function name (e.g. a file-header
    list item like `--   portal_overview()   everything linked ...`) plus its
    more-indented continuation lines."""
    pat = re.compile(r"^--(\s*)" + re.escape(name) + r"\b")
    for i, line in enumerate(lines):
        m = pat.match(line.strip())
        if not m:
            continue
        base = len(m.group(1))
        out = [line.strip()[2:].strip()]
        for nxt in lines[i + 1:]:
            s = nxt.strip()
            if not s.startswith("--"):
                break
            body = s[2:]
            ind = len(body) - len(body.lstrip())
            if not body.strip() or ind <= base or RULE_RE.match(body):
                break
            out.append(body.strip())
        return re.sub(r"\s+", " ", " ".join(out)).strip()
    return ""


def scan_migrations(mig_dir: Path):
    files = sorted(p for p in mig_dir.glob("*.sql"))
    tables, types = {}, {}
    funcs = defaultdict(list)          # name -> [(file, comment)] in apply order
    touches = defaultdict(list)        # table -> files (non-creating) that alter it / add policies / triggers
    file_lines = {}
    h = hashlib.sha256()
    for p in files:
        text = p.read_text()
        file_lines[p.name] = text.splitlines()
        h.update(p.name.encode() + b"\0" + text.encode())
        lines = text.splitlines()
        def line_of(m):
            return text.count("\n", 0, m.start() + len(m.group(0)) - len(m.group(0).lstrip()))
        for m in RE_TABLE.finditer(text):
            tables.setdefault(m.group(1), (p.name, comment_above(lines, line_of(m))))
        for m in RE_TYPE.finditer(text):
            cm = comment_above(lines, line_of(m))
            if re.match(r"^enums\b", cm, re.I):
                cm = ""  # section header for a group of enums, not about this one
            types.setdefault(m.group(1), (p.name, cm))
        for m in RE_FUNC.finditer(text):
            funcs[m.group(1)].append((p.name, comment_above(lines, line_of(m))))
        for m in RE_TOUCH.finditer(text):
            t = m.group(1)
            if p.name not in touches[t]:
                touches[t].append(p.name)
    return {"files": [p.name for p in files], "tables": tables, "types": types, "funcs": funcs,
            "touches": touches, "sha": h.hexdigest()[:16], "file_lines": file_lines}


# --------------------------------------------------------------------------
# docs/SCHEMA.md
# --------------------------------------------------------------------------
DOMAINS = [
    (1, 9, "Foundation (0001–0009): tenancy, shop setup, CRM, catalog, jobs, scheduling"),
    (10, 19, "Money (0010–0019): quotes, invoices, payments, cards, memberships, Stripe"),
    (20, 29, "Field operations (0020–0029): checklists, inspections, photos, forms, time clock, storage"),
    (30, 39, "Communication (0030–0039): templates, messages, automations, campaigns, notifications"),
    (40, 49, "Integration & reports (0040–0049): pricing, events, online booking, portal, realtime, reports, search"),
    (50, 59, "Scheduling v2 (0050–0059): recurring series, calendar events, capacity, booking links, iCal feeds"),
    (60, 69, "Money v2 (0060–0069): terminal, multi-job invoices, tips & commissions, gift cards, fees, proposals"),
    (70, 79, "Field ops v2 (0070–0079): job reports, remote sign-off, required checklists, documents, merge"),
    (80, 89, "Comms & integrations v2 (0080–0089): push, reminders, import/export, custom fields, lead forms"),
    (90, 99, "Cross-cutting hardening (0090–0099)"),
]


def domain_of(fname):
    if not fname:
        return "Other (not found in a migration file)"
    n = int(fname[:4])
    for lo, hi, label in DOMAINS:
        if lo <= n <= hi:
            return label
    return f"Other ({fname[:4]})"


def strip_public(s: str) -> str:
    return re.sub(r"\bpublic\.", "", s or "")


def abbrev(expr, limit=320):
    if expr is None:
        return None
    s = re.sub(r"\s+", " ", expr).strip()
    s = strip_public(s)
    s = re.sub(r"\(\s*SELECT auth\.uid\(\) AS uid\s*\)", "auth.uid()", s)
    s = re.sub(r"('(?:[^']|'')*')::(?:text|character varying)\b(?!\[)", r"\1", s)
    if len(s) > limit:
        s = s[: limit - 1].rstrip() + "…"
    return s


def md_cell(s):
    return (s or "").replace("|", "\\|").replace("\n", " ")


def trig_summary(defn: str, table: str) -> str:
    s = re.sub(r"^CREATE (CONSTRAINT )?TRIGGER \S+ ", "", defn)
    s = re.sub(r" ON (public\.)?" + re.escape(table) + r"\b", "", s)
    s = s.replace("FOR EACH ROW", "ROW").replace("FOR EACH STATEMENT", "STATEMENT")
    s = s.replace("EXECUTE FUNCTION ", "→ ").replace("EXECUTE PROCEDURE ", "→ ")
    return abbrev(s, 260)


def build_snapshot(meta, scan, repo: Path, applied: int | None) -> tuple[str, dict]:
    types = meta["types"]
    rels = {r["name"]: r for r in meta["relations"]}
    tables = sorted([r for r in meta["relations"]], key=lambda r: r["name"])
    cols_by = defaultdict(list)
    for c in sorted(meta["columns"], key=lambda c: (c["table"], c["ordinal_position"])):
        cols_by[c["table"]].append(c)
    cons_by = defaultdict(list)
    for k in sorted(meta["constraints"], key=lambda k: (k["table"], k["type"], k["name"])):
        cons_by[k["table"]].append(k)
    uidx_by = defaultdict(list)
    for u in sorted(meta["unique_indexes"], key=lambda u: (u["table"], u["name"])):
        uidx_by[u["table"]].append(u)
    pol_by = defaultdict(list)
    for p in sorted(meta["policies"], key=lambda p: (p["schema"], p["table"], p["cmd"], p["name"])):
        pol_by[(p["schema"], p["table"])].append(p)
    trig_by = defaultdict(list)
    fn_used_by = defaultdict(list)
    for t in sorted(meta["triggers"], key=lambda t: (t["table_schema"] != SCHEMA, t["table_schema"], t["table"], t["name"])):
        if t["table_schema"] == SCHEMA:
            trig_by[t["table"]].append(t)
        if t["function_schema"] == SCHEMA:
            qual = "" if t["table_schema"] == SCHEMA else f'{t["table_schema"]}.'
            fn_used_by[t["function"]].append(f'{qual}{t["table"]}.{t["name"]}')
    tpriv = {(p["table"], p["role"]): p for p in meta["table_privs"]}
    cpriv = defaultdict(list)
    for p in sorted(meta["column_privs"], key=lambda p: (p["table"], p["role"], p["attnum"])):
        cpriv[(p["table"], p["role"])].append(p)
    pub = {p["table"]: p for p in meta["publication"] if p["schema"] == SCHEMA}
    enums = sorted([t for t in types if t["schema"] == SCHEMA and t["enums"]], key=lambda t: t["name"])
    comps = sorted([t for t in types if t["schema"] == SCHEMA and t["attributes"]], key=lambda t: t["name"])
    fns = sorted([f for f in meta["functions"] if not f["is_extension_member"]],
                 key=lambda f: (f["name"], f["identity_argument_types"]))
    counts = {
        "tables": sum(1 for r in tables if r["kind"] in ("r", "p")),
        "views": sum(1 for r in tables if r["kind"] in ("v", "m")),
        "functions": len(fns),
        "functions_non_trigger": sum(1 for f in fns if f["return_type"] not in ("trigger", "event_trigger")),
        "enums": len(enums),
        "composite_types": len(comps),
        "policies_public": sum(1 for p in meta["policies"] if p["schema"] == SCHEMA),
        "policies_storage": sum(1 for p in meta["policies"] if p["schema"] == "storage"),
        "buckets": len(meta["buckets"]),
    }

    def rls_label(r, long=False):
        if r["kind"] in ("v", "m"):
            if r["kind"] == "v" and r.get("security_invoker"):
                return "security_invoker view (base-table RLS applies to the caller)"
            return "**view runs as its owner (base-table RLS bypassed)**"
        if r["rls_enabled"]:
            return ("RLS on" if long else "on") + (" (forced)" if r["rls_forced"] else "")
        return "**RLS OFF**" if long else "**OFF**"

    def exec_roles(f):
        r = [x for x in API_ROLES if f[f"exec_{x}"]]
        return ", ".join(r) if r else "none of anon/authenticated/service_role"

    def fn_file_info(f):
        defs = scan["funcs"].get(f["name"], [])
        files = []
        for fl, _c in defs:
            if fl not in files:
                files.append(fl)
        comment = (f["comment"] or "").strip()
        src = "COMMENT ON"
        if not comment:
            # comment block above the effective (last) definition, else any definition
            for fl, c in reversed(defs):
                if c:
                    comment, src = c, fl
                    break
        if not comment:
            # e.g. a file-header list describing several functions
            for fl in files:
                c = listed_in_comments(scan["file_lines"].get(fl, []), f["name"])
                if c:
                    comment, src = c, "header"
                    break
        return files, comment, src

    def grants_line(tname):
        parts = []
        for role in ("anon", "authenticated"):
            p = tpriv.get((tname, role))
            if not p:
                continue
            letters = "".join(ch for ch, k in (("S", "s"), ("I", "i"), ("U", "u"), ("D", "d")) if p[k]) or "—"
            extra = []
            for priv, k in (("SELECT", "s"), ("INSERT", "i"), ("UPDATE", "u")):
                if p[k]:
                    continue
                cc = [c["column"] for c in cpriv.get((tname, role), []) if c[k]]
                if cc:
                    extra.append(f"{priv}({', '.join(cc)})")
            parts.append(f"{role}={letters}" + (f" + cols {' '.join(extra)}" if extra else ""))
        return "; ".join(parts)

    L = []
    w = L.append
    w("# Detail CRM — database schema (column-level contract)\n")
    w("> Generated by `python3 scripts/gen_types.py` from a throwaway Postgres cluster built with "
      "`scripts/test_db.sh` (local Supabase shim + every migration from zero). **Do not edit by hand**: change a "
      "migration and regenerate. `python3 scripts/check_contracts.py` fails when this file or "
      "`web/src/lib/database.types.ts` is stale, and verifies every table, column, RPC and storage bucket that the "
      "web app, the iOS app and the edge functions reference against the same live schema (SPEC §8.2).\n")
    w(f"- Migrations applied: {applied if applied is not None else len(scan['files'])} "
      f"(`{scan['files'][0] if scan['files'] else '-'}` … `{scan['files'][-1] if scan['files'] else '-'}`), "
      f"content sha256/16: `{scan['sha']}`")
    w(f"- Counts: {counts['tables']} tables, {counts['views']} views, {counts['functions']} functions "
      f"({counts['functions_non_trigger']} non-trigger), {counts['enums']} enums, {counts['composite_types']} composite types, "
      f"{counts['policies_public']} public RLS policies, {counts['buckets']} storage buckets "
      f"({counts['policies_storage']} storage.objects policies)")
    w("- TypeScript: `web/src/lib/database.types.ts` (same generator run). Swift: models map these names 1:1 through "
      "explicit `CodingKeys` under a `// table: <name>` or `// rpc: <name>` annotation.")
    w("- Legend: grants `S/I/U/D` = table-level SELECT/INSERT/UPDATE/DELETE for the PostgREST role (RLS still applies; "
      "`service_role` bypasses RLS). `cols UPDATE(a, b)` = column-level grant only. Policy expressions are abbreviated "
      "(`public.` stripped, whitespace collapsed, long ones truncated with …). `exec:` = roles with EXECUTE on a function "
      "(includes PUBLIC grants). DEFINER = SECURITY DEFINER.\n")

    # ---- index
    w("## Index\n")
    w("### Tables\n")
    w("| table | created in | RLS | realtime | anon / authenticated grants |")
    w("|---|---|---|---|---|")
    for r in tables:
        f = scan["tables"].get(r["name"], (None, ""))[0]
        kind = {"v": " (view)", "m": " (matview)", "f": " (foreign)"}.get(r["kind"], "")
        w(f"| `{r['name']}`{kind} | {f or '?'} | {rls_label(r)} | "
          f"{'yes' if r['name'] in pub else ''} | {md_cell(grants_line(r['name']))} |")
    w("")
    w("### Client-callable RPCs (EXECUTE granted to `anon` and/or `authenticated`)\n")
    def arg_names(f):
        args = [a for a in f.get("args_declared", []) if a["mode"] in ("in", "inout", "variadic")]
        return ", ".join((a["name"] or "(unnamed)") + ("?" if a["has_default"] else "") for a in args) or "—"

    w("| function | args (`?` = has default) | exec | returns | file |")
    w("|---|---|---|---|---|")
    for f in fns:
        if f["return_type"] in ("trigger", "event_trigger"):
            continue
        if not (f["exec_anon"] or f["exec_authenticated"]):
            continue
        files, _c, _s = fn_file_info(f)
        roles = ", ".join(x for x in ("anon", "authenticated") if f[f"exec_{x}"])
        w(f"| `{f['name']}` | {md_cell(arg_names(f))} | {roles}{' · DEFINER' if f['security_definer'] else ''} | "
          f"`{md_cell(abbrev(strip_public(f['return_type']), 90))}` | {files[0] if files else '?'} |")
    w("")
    w("### Server-only functions (EXECUTE for `service_role` only: edge functions, webhooks, pg_cron)\n")
    w("| function | args (`?` = has default) | returns | file |")
    w("|---|---|---|---|")
    for f in fns:
        if f["return_type"] in ("trigger", "event_trigger"):
            continue
        if f["exec_anon"] or f["exec_authenticated"] or not f["exec_service_role"]:
            continue
        files, _c, _s = fn_file_info(f)
        w(f"| `{f['name']}` | {md_cell(arg_names(f))} | `{md_cell(abbrev(strip_public(f['return_type']), 90))}` | "
          f"{files[0] if files else '?'} |")
    w("")

    # ---- per domain
    by_domain = defaultdict(lambda: {"enums": [], "comps": [], "tables": [], "fns": [], "trig_fns": []})
    for e in enums:
        by_domain[domain_of(scan["types"].get(e["name"], (None,))[0])]["enums"].append(e)
    for c in comps:
        by_domain[domain_of(scan["types"].get(c["name"], (None,))[0])]["comps"].append(c)
    for r in tables:
        by_domain[domain_of(scan["tables"].get(r["name"], (None,))[0])]["tables"].append(r)
    for f in fns:
        files, _c, _s = fn_file_info(f)
        d = by_domain[domain_of(files[0] if files else None)]
        (d["trig_fns"] if f["return_type"] in ("trigger", "event_trigger") else d["fns"]).append(f)

    order = [label for _lo, _hi, label in DOMAINS] + sorted(k for k in by_domain if k not in {d[2] for d in DOMAINS})
    for label in order:
        if label not in by_domain:
            continue
        d = by_domain[label]
        w(f"## {label}\n")
        if d["enums"]:
            w("### Enums\n")
            for e in d["enums"]:
                fl, cm = scan["types"].get(e["name"], ("?", ""))
                w(f"- `{e['name']}`: {' | '.join(e['enums'])}  _({fl})_" + (f" — {abbrev(e['comment'] or cm, 300)}" if (e['comment'] or cm) else ""))
            w("")
        if d["comps"]:
            w("### Composite types\n")
            for c in d["comps"]:
                fl, cm = scan["types"].get(c["name"], ("?", ""))
                attrs = ", ".join(f"{a['name']} {strip_public(a['full_type'])}" for a in c["attributes"])
                w(f"- `{c['name']}`({attrs})  _({fl})_" + (f" — {abbrev(c['comment'] or cm, 300)}" if (c['comment'] or cm) else ""))
            w("")
        if d["tables"]:
            w("### Tables\n")
        for r in d["tables"]:
            name = r["name"]
            fl, cm = scan["tables"].get(name, ("?", ""))
            also = [x for x in scan["touches"].get(name, []) if x != fl]
            flags = [f"file `{fl}`"]
            if also:
                flags.append("also altered/policies in " + ", ".join(f"`{x}`" for x in also))
            flags.append(rls_label(r, long=True))
            flags.append("realtime: " + ("**yes**" if name in pub else "no"))
            w(f"#### `{name}`" + {"v": " (view)", "m": " (materialized view)", "f": " (foreign table)"}.get(r["kind"], "") + "\n")
            w(" · ".join(flags))
            desc = (r["comment"] or "").strip() or cm
            if re.sub(r"[^a-z0-9_]", "", (desc or "").lower()) == name:
                desc = ""  # section header that only repeats the table name
            if desc:
                w(f"\n> {abbrev(desc, 700)}")
            w("")
            cols = cols_by.get(name, [])
            has_notes = any(c["comment"] for c in cols)
            w("| column | type | null | default |" + (" note |" if has_notes else ""))
            w("|---|---|---|---|" + ("---|" if has_notes else ""))
            for c in cols:
                if c["is_generated"]:
                    dflt = f"GENERATED: {abbrev(c['default_value'], 140)}"
                elif c["identity_generation"]:
                    dflt = f"identity {c['identity_generation'].lower()}"
                else:
                    dflt = abbrev(c["default_value"], 100) or ""
                row = (f"| {c['name']} | {md_cell(strip_public(c['full_type']))} | {'yes' if c['is_nullable'] else 'no'} | "
                       f"{md_cell(dflt)} |")
                if has_notes:
                    row += f" {md_cell(abbrev(c['comment'], 200) or '')} |"
                w(row)
            w("")
            kinds = defaultdict(list)
            for k in cons_by.get(name, []):
                kinds[k["type"]].append(k)
            if kinds.get("p"):
                w("- PK: " + "; ".join(f"({', '.join(k['columns'] or [])})" for k in kinds["p"]))
            uniq = [f"({', '.join(k['columns'] or [])})" for k in kinds.get("u", [])]
            uniq += [abbrev(re.sub(r"^CREATE UNIQUE INDEX (\S+) ON (public\.)?\S+ USING btree ", r"\1 ", u["def"]), 200)
                     for u in uidx_by.get(name, [])]
            if uniq:
                w("- UNIQUE: " + "; ".join(uniq))
            for k in kinds.get("f", []):
                w(f"- FK `{k['name']}`: {abbrev(k['def'], 240)}")
            for k in kinds.get("x", []):
                w(f"- EXCLUDE `{k['name']}`: {abbrev(k['def'], 240)}")
            checks = kinds.get("c", [])
            if checks:
                w("- CHECK: " + "; ".join(f"`{k['name']}` {abbrev(re.sub(r'^CHECK ', '', k['def']), 220)}" for k in checks))
            g = grants_line(name)
            if g:
                w(f"- Grants: {g}")
            pols = pol_by.get((SCHEMA, name), [])
            if pols:
                w("- Policies:")
                for p in pols:
                    roles = ",".join(p["roles"]) if isinstance(p["roles"], list) else str(p["roles"])
                    parts = [f"  - `{p['name']}` {p['cmd']} to {roles}" + ("" if p["permissive"] == "PERMISSIVE" else " (RESTRICTIVE)")]
                    if p["qual"]:
                        parts.append(f"USING `{abbrev(p['qual'])}`")
                    if p["with_check"]:
                        parts.append(f"CHECK `{abbrev(p['with_check'])}`")
                    w(" — ".join(parts))
            elif r["rls_enabled"]:
                w("- Policies: none (RLS on → no direct access except service_role / SECURITY DEFINER RPCs)")
            trs = trig_by.get(name, [])
            if trs:
                w("- Triggers: " + "; ".join(f"`{t['name']}` {trig_summary(t['def'], name)}" + ("" if t["enabled"] else " (DISABLED)") for t in trs))
            if name in pub and pub[name].get("rowfilter"):
                w(f"- Realtime row filter: `{abbrev(pub[name]['rowfilter'])}`")
            w("")
        if d["fns"]:
            w("### Functions\n")
            for f in d["fns"]:
                files, comment, src = fn_file_info(f)
                w(f"#### `{f['name']}`\n")
                w(f"`{f['name']}({strip_public(f['argument_types'])})` → `{strip_public(f['return_type'])}`\n")
                meta_bits = ["**DEFINER**" if f["security_definer"] else "invoker",
                             f["language"], {"i": "immutable", "s": "stable", "v": "volatile"}[f["volatility"]],
                             f"exec: {exec_roles(f)}"]
                cfg = [c for c in (f["config"] or []) if c.startswith("search_path")]
                if cfg:
                    meta_bits.append(cfg[0].replace("search_path=", "search_path="))
                meta_bits.append("file " + ", ".join(f"`{x}`" for x in files) if files else "file ?")
                w("- " + " · ".join(meta_bits))
                if comment:
                    tag = {"COMMENT ON": "(COMMENT ON) ", "header": "(file header) "}.get(src, "")
                    w(f"- {tag}{abbrev(comment, 1200)}")
                w("")
        if d["trig_fns"]:
            w("### Trigger functions\n")
            for f in d["trig_fns"]:
                files, comment, src = fn_file_info(f)
                used = fn_used_by.get(f["name"], [])
                line = (f"- `{f['name']}()` — {'**DEFINER**' if f['security_definer'] else 'invoker'} · "
                        f"{', '.join(f'`{x}`' for x in files) or '?'} · used by "
                        + (", ".join(used) if used else "no trigger in public"))
                if comment:
                    line += f" — {abbrev(comment, 400)}"
                w(line)
            w("")

    # ---- storage + realtime
    w("## Storage (buckets and `storage.objects` policies)\n")
    if meta["buckets"]:
        w("| bucket | public | size limit | allowed mime types |")
        w("|---|---|---|---|")
        for b in sorted(meta["buckets"], key=lambda b: b.get("id") or ""):
            lim = b.get("file_size_limit")
            lim_s = f"{lim} B ({lim / 1048576:.0f} MiB)" if isinstance(lim, (int, float)) and lim else "—"
            w(f"| `{b.get('id')}` | {'yes' if b.get('public') else 'no'} | {lim_s} | {', '.join(b.get('allowed_mime_types') or []) or 'any'} |")
        w("")
    else:
        w("_No buckets._\n")
    conv = storage_conventions(meta, scan, fns, fn_file_info)
    if conv["buckets"]:
        w("### Object path conventions\n")
        w("Object names are `/`-separated folders. The layout is the one documented next to the bucket definition; "
          "the folder checks are derived from the `storage.objects` policies (`storage_path_uuid(name, N)` passed to "
          "a public function names the argument that folder N must satisfy); the columns are the table columns that "
          "store object names of the bucket (from their column comments or the trigger that requires the object).\n")
        for b in conv["buckets"]:
            w(f"#### `{b['id']}`\n")
            if b["layout"]:
                w(f"- Layout: `{b['layout'][0]}` _(documented in `{b['layout'][1]}`)_")
            else:
                w("- Layout: not documented in a migration")
            for folder, uses in b["folders"]:
                w(f"- Folder {folder}: " + "; ".join(f"`{arg}` of {', '.join(f'`{fn}`' for fn in fns_)}"
                                                    for arg, fns_ in uses))
            if b["whole"]:
                w("- Whole-name checks: " + ", ".join(f"`{fn}`" for fn in b["whole"]))
            if b["columns"]:
                w("- Stored in: " + ", ".join(f"`{c}" for c in b["columns"]))
            w("")
        if conv["other_columns"]:
            w("Other object-path columns (no bucket named by the schema): "
              + ", ".join(f"`{c}`" for c in conv["other_columns"]) + "\n")
    spols = pol_by.get(("storage", "objects"), [])
    if spols:
        w("storage.objects policies:")
        for p in spols:
            roles = ",".join(p["roles"]) if isinstance(p["roles"], list) else str(p["roles"])
            parts = [f"- `{p['name']}` {p['cmd']} to {roles}"]
            if p["qual"]:
                parts.append(f"USING `{abbrev(p['qual'], 500)}`")
            if p["with_check"]:
                parts.append(f"CHECK `{abbrev(p['with_check'], 500)}`")
            w(" — ".join(parts))
        w("")
    bpols = pol_by.get(("storage", "buckets"), [])
    if bpols:
        w("storage.buckets policies:")
        for p in bpols:
            roles = ",".join(p["roles"]) if isinstance(p["roles"], list) else str(p["roles"])
            w(f"- `{p['name']}` {p['cmd']} to {roles}" + (f" — USING `{abbrev(p['qual'])}`" if p["qual"] else ""))
        w("")
    w("## Realtime publication `supabase_realtime`\n")
    if meta["publication"]:
        for p in sorted(meta["publication"], key=lambda p: (p["schema"], p["table"])):
            w(f"- `{p['schema']}.{p['table']}`" + (f" (row filter `{abbrev(p['rowfilter'])}`)" if p.get("rowfilter") else "")
              + " — subscribers only receive rows their RLS SELECT policies allow")
    else:
        w("_No tables in the publication._")
    w("")
    return "\n".join(L).rstrip() + "\n", counts


def _call_args(text: str, open_i: int) -> tuple[list[str], int]:
    """Top-level comma-separated arguments of the call whose '(' is text[open_i]."""
    depth, cur, args, i = 0, [], [], open_i
    quoted = False
    while i < len(text):
        ch = text[i]
        if ch == "'":
            quoted = not quoted
        elif not quoted:
            if ch == "(":
                depth += 1
                if depth == 1:
                    i += 1
                    continue
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    args.append("".join(cur).strip())
                    return [a for a in args if a], i
            elif ch == "," and depth == 1:
                args.append("".join(cur).strip())
                cur = []
                i += 1
                continue
        cur.append(ch)
        i += 1
    return [], len(text)


RE_BUCKET_EQ = re.compile(r"\bbucket_id\s*=\s*'([^']+)'")
RE_FOLDER_ARG = re.compile(r"^storage_path_uuid\(name,\s*(\d+)\)$")


def storage_conventions(meta: dict, scan: dict, fns: list, fn_file_info) -> dict:
    """Per bucket: documented layout, policy folder checks, columns holding its object names."""
    bucket_ids = sorted(b.get("id") for b in meta["buckets"] if b.get("id"))

    def buckets_in(text: str) -> list[str]:
        return [b for b in bucket_ids if re.search(r"(?<![\w-])" + re.escape(b) + r"(?![\w-])", text or "")]

    # layout: a migration comment line "<bucket>  ...  <path pattern>" (a bucket table in a file header)
    layout = {}
    creates = [f for f in scan["files"]
               if re.search(r"insert\s+into\s+storage\.buckets", "\n".join(scan["file_lines"].get(f, [])), re.I)]
    for fname in creates + [f for f in scan["files"] if f not in creates]:
        for line in scan["file_lines"].get(fname, []):
            body = line.strip()
            if not body.startswith("--"):
                continue
            body = body[2:].strip()
            for b in bucket_ids:
                m = re.match(re.escape(b) + r"\s{2,}.*?\s(<\S+)$", body)
                if m and b not in layout:
                    layout[b] = (m.group(1), fname)

    in_args = {}
    for f in fns:
        in_args.setdefault(f["name"], [a["name"] for a in f.get("args_declared", []) if a["mode"] in ("in", "inout", "variadic")])
    folders = defaultdict(lambda: defaultdict(lambda: defaultdict(set)))  # bucket -> folder -> arg -> {fn}
    whole = defaultdict(set)
    for p in meta["policies"]:
        if p["schema"] != "storage" or p["table"] != "objects":
            continue
        for expr in (p["qual"], p["with_check"]):
            text = strip_public(expr or "")
            for b in sorted(set(RE_BUCKET_EQ.findall(text)) & set(bucket_ids)):
                for m in re.finditer(r"\b([a-z_][a-z0-9_]*)\(", text):
                    fn = m.group(1)
                    if fn == "storage_path_uuid" or fn not in in_args:
                        continue
                    args, _end = _call_args(text, m.end() - 1)
                    names = in_args[fn]
                    for i, a in enumerate(args):
                        fm = RE_FOLDER_ARG.match(a)
                        if fm:
                            arg = names[i] if i < len(names) and names[i] else f"argument {i + 1}"
                            folders[b][int(fm.group(1))][re.sub(r"^p_", "", arg)].add(fn)
                        elif a == "name":
                            whole[b].add(fn)

    # columns that store object names
    fn_buckets = {}
    for f in fns:
        _files, comment, _src = fn_file_info(f)
        fn_buckets.setdefault(f["name"], buckets_in(comment))
    trig_cols = defaultdict(set)  # (table, column) -> buckets
    for t in meta["triggers"]:
        m = re.search(r"EXECUTE (?:FUNCTION|PROCEDURE) (?:public\.)?(\w+)\((.*)\)\s*$", t["def"])
        if t["table_schema"] != SCHEMA or not m:
            continue
        hit = fn_buckets.get(m.group(1), [])
        if len(hit) != 1:
            continue
        for arg in re.findall(r"'([^']+)'", m.group(2)):
            trig_cols[(t["table"], arg)].add(hit[0])
    tables = {r["name"] for r in meta["relations"] if r["schema"] == SCHEMA}
    table_cols = defaultdict(set)
    for c in meta["columns"]:
        table_cols[c["table"]].add(c["name"])
    by_bucket, other = defaultdict(list), []
    for c in sorted(meta["columns"], key=lambda c: (c["table"], c["name"])):
        if c["table"] not in tables or not (c["name"] == "path" or c["name"].endswith("_path")):
            continue
        ref = f"{c['table']}.{c['name']}"
        hit = buckets_in(c["comment"] or "") or sorted(trig_cols.get((c["table"], c["name"]), ()))
        if hit:
            for b in hit:
                by_bucket[b].append(ref + "`")
        elif "bucket_id" in table_cols[c["table"]]:
            for b in bucket_ids:
                by_bucket[b].append(ref + "` (rows whose `bucket_id` is this bucket)")
        else:
            other.append(ref)
    out = []
    for b in bucket_ids:
        out.append({
            "id": b,
            "layout": layout.get(b),
            "folders": [(n, [(arg, sorted(fs)) for arg, fs in sorted(folders[b][n].items())])
                        for n in sorted(folders[b])],
            "whole": sorted(whole[b]),
            "columns": by_bucket.get(b, []),
        })
    return {"buckets": out, "other_columns": other}


# --------------------------------------------------------------------------
# Library API (also used by scripts/check_contracts.py)
# --------------------------------------------------------------------------
class GenError(RuntimeError):
    """A generator failure with a message meant for people (no traceback)."""


def _install_signal_cleanup():
    """Make SIGTERM/SIGHUP unwind through `finally` so the cluster is removed."""
    def _sig(signum, _frame):
        raise SystemExit(128 + signum)
    for s in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(s, _sig)


def load_live_meta(repo: Path, log=print, pg_env: bool = False) -> tuple[dict, int | None]:
    """Introspection dict of the live schema: shim + every migration on a
    throwaway cluster (always stopped and removed), or with `pg_env` the
    already migrated database named by the libpq environment."""
    if pg_env:
        db = EnvDatabase()
        meta = introspect(db)
        log("introspected the database named by the PG* environment")
        meta["applied_migrations"] = None
        return meta, None
    _install_signal_cleanup()
    cluster = Cluster(repo)
    try:
        applied = cluster.start()
        log(f"cluster up: shim + {applied} migrations applied")
        meta = introspect(cluster)
    finally:
        cluster.stop()
    meta["applied_migrations"] = applied
    return meta, applied


def load_meta_file(path: Path) -> tuple[dict, int | None]:
    meta = json.loads(Path(path).read_text())
    return meta, meta.get("applied_migrations")


def render(meta: dict, applied: int | None, repo: Path, postgrest_version: str | None = "12",
           use_prettier: bool = True) -> dict:
    """Both contract files as {repo-relative Path: text} plus a summary."""
    has_prettier = (repo / "web/node_modules/.bin/prettier").exists()
    if use_prettier and not has_prettier:
        raise GenError("web/node_modules/.bin/prettier not found: run `npm ci` in web/ first "
                       "(or pass --no-prettier for a throwaway, unformatted preview)")
    gen = TsGen(meta, postgrest_version or None, quote_keys=use_prettier)
    ts = gen.generate()
    if use_prettier:
        ts = prettier_format(ts, repo)
    scan = scan_migrations(repo / "supabase/migrations")
    md, counts = build_snapshot(meta, scan, repo, applied)
    n_ts_fns = len({fn["name"] for fn, _ in gen.schema_functions()})
    summary = (f"{len(gen.tables) + len(gen.foreign_tables)} tables, {len(gen.views) + len(gen.mat_views)} views, "
               f"{n_ts_fns} RPC-visible functions, "
               f"{sum(1 for t in gen.types if t['schema'] == SCHEMA and t['enums'])} enums, "
               f"{sum(1 for t in gen.types if t['schema'] == SCHEMA and t['attributes'])} composite types; "
               f"{counts['policies_public']} RLS policies, {counts['buckets']} buckets")
    return {"files": {TS_PATH: ts, MD_PATH: md}, "summary": summary, "warnings": list(gen.warnings)}


def stale_files(repo: Path, files: dict, targets: dict | None = None) -> list[str]:
    """Repo-relative names of outputs whose committed text differs from `files`.
    `targets` maps each output to the path actually compared (defaults to repo/rel)."""
    stale = []
    for rel, text in files.items():
        path = (targets or {}).get(rel, repo / rel)
        try:
            current = Path(path).read_text()
        except FileNotFoundError:
            current = None
        if current != text:
            stale.append(str(rel) + (" (missing)" if current is None else ""))
    return stale


# --------------------------------------------------------------------------
# Self-test: a tiny fixture schema on a throwaway cluster
# --------------------------------------------------------------------------
FIXTURE_MIGRATION = """\
-- Fixture schema for `scripts/gen_types.py --self-test` (never applied to a
-- real database).
--
--   bucket         visibility  path
--   visit-photos   private     <shop_id>/<visit_id>/<file>

-- Enums
create type public.visit_status as enum ('booked', 'in_progress', 'done');

-- A money amount with its currency.
create type public.money as (amount_cents bigint, currency text);

-- Tenant root.
create table public.shops (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  seq         bigint generated always as identity,
  name_upper  text generated always as (upper(name)) stored,
  unique (id, seq)
);
comment on column public.shops.name is 'Display name shown to customers.';

-- Visits of a shop.
create table public.visits (
  id          uuid not null default gen_random_uuid(),
  shop_id     uuid not null references public.shops (id) on delete cascade,
  status      public.visit_status not null default 'booked',
  notes       text,
  tags        text[] not null default '{}',
  meta        jsonb,
  photo_path  text,
  primary key (id),
  unique (shop_id, id)
);
comment on column public.visits.photo_path is 'Object name in the visit-photos bucket: <shop_id>/<visit_id>/<file>.';

create table public.visit_notes (
  id        uuid primary key default gen_random_uuid(),
  shop_id   uuid not null,
  visit_id  uuid not null,
  body      text not null check (char_length(body) <= 2000),
  unique (shop_id, visit_id),
  constraint visit_notes_visit_fk foreign key (shop_id, visit_id)
    references public.visits (shop_id, id) on delete cascade
);

create view public.open_visits with (security_invoker = true) as
  select id, shop_id, status from public.visits where status <> 'done';

alter table public.shops enable row level security;
alter table public.visits enable row level security;
alter table public.visit_notes enable row level security;

revoke all on public.visits from anon;
revoke all on public.visit_notes from anon, authenticated;
grant select (id, shop_id, body) on public.visit_notes to authenticated;

create policy visits_select on public.visits for select to authenticated using (status <> 'done');

create function public.storage_path_uuid(p_name text, p_index integer) returns uuid
language sql immutable set search_path = '' as $$
  select case when split_part(p_name, '/', p_index) ~ '^[0-9a-f-]{36}$'
              then split_part(p_name, '/', p_index)::uuid end
$$;

-- Whether the caller may see a visit.
create function public.can_see_visit(p_shop_id uuid, p_visit_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.visits v where v.shop_id = p_shop_id and v.id = p_visit_id)
$$;

-- Number of visits of a shop, optionally with one status.
create function public.visit_count(p_shop_id uuid, p_status public.visit_status default null) returns integer
language sql stable security definer set search_path = '' as $$
  select count(*)::integer from public.visits v
  where v.shop_id = p_shop_id and (p_status is null or v.status = p_status)
$$;
revoke execute on function public.visit_count(uuid, public.visit_status) from public, anon;

create function public.shop_visits(p_shop_id uuid) returns setof public.visits
language sql stable set search_path = '' as $$
  select * from public.visits v where v.shop_id = p_shop_id
$$;

create function public.visit_summary(p_shop_id uuid)
returns table (status public.visit_status, n bigint)
language sql stable set search_path = '' as $$
  select v.status, count(*) from public.visits v where v.shop_id = p_shop_id group by v.status
$$;

-- Deletes finished visits (pg_cron).
create function public.purge_visits(p_before timestamptz default now()) returns void
language sql security definer set search_path = '' as $$
  delete from public.visits where status = 'done'
$$;
revoke execute on function public.purge_visits(timestamptz) from public, anon, authenticated;
grant execute on function public.purge_visits(timestamptz) to service_role;

create function public.visits_touch() returns trigger
language plpgsql set search_path = '' as $$
begin
  return new;
end
$$;
create trigger visits_touch before update on public.visits
  for each row execute function public.visits_touch();

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('visit-photos', 'visit-photos', false, 1048576, array['image/png']);

create policy visit_photos_read on storage.objects for select to authenticated
  using (bucket_id = 'visit-photos'
         and public.can_see_visit(public.storage_path_uuid(name, 1), public.storage_path_uuid(name, 2)));

alter publication supabase_realtime add table public.visits;
"""

# Exact supabase-js shapes the fixture must produce (prettier-formatted, as in
# `supabase gen types typescript`).
FIXTURE_TS_EXPECT = [
    # identity ALWAYS and generated columns: readable, never writable
    """      shops: {
        Row: {
          id: string
          name: string
          name_upper: string | null
          seq: number
        }
        Insert: {
          id?: string
          name: string
          name_upper?: never
          seq?: never
        }
        Update: {
          id?: string
          name?: string
          name_upper?: never
          seq?: never
        }
        Relationships: []
      }""",
    # composite tenant FK, unique (shop_id, visit_id) → one-to-one
    """        Relationships: [
          {
            foreignKeyName: "visit_notes_visit_fk"
            columns: ["shop_id", "visit_id"]
            isOneToOne: true
            referencedRelation: "visits"
            referencedColumns: ["shop_id", "id"]
          },
        ]""",
    """        Row: {
          id: string
          meta: Json | null
          notes: string | null
          photo_path: string | null
          shop_id: string
          status: Database["public"]["Enums"]["visit_status"]
          tags: string[]
        }
        Insert: {
          id?: string
          meta?: Json | null
          notes?: string | null
          photo_path?: string | null
          shop_id: string
          status?: Database["public"]["Enums"]["visit_status"]
          tags?: string[]
        }""",
    # auto-updatable view: Row/Insert/Update with every column optional
    """      open_visits: {
        Row: {
          id: string | null
          shop_id: string | null
          status: Database["public"]["Enums"]["visit_status"] | null
        }
        Insert: {
          id?: string | null
          shop_id?: string | null
          status?: Database["public"]["Enums"]["visit_status"] | null
        }""",
    """      purge_visits: { Args: { p_before?: string }; Returns: undefined }""",
    """      visit_count: {
        Args: {
          p_shop_id: string
          p_status?: Database["public"]["Enums"]["visit_status"]
        }
        Returns: number
      }""",
    """        SetofOptions: {
          from: "*"
          to: "visits"
          isOneToOne: false
          isSetofReturn: true
        }""",
    """      visit_summary: {
        Args: { p_shop_id: string }
        Returns: {
          n: number
          status: Database["public"]["Enums"]["visit_status"]
        }[]
      }""",
    """    Enums: {
      visit_status: "booked" | "in_progress" | "done"
    }
    CompositeTypes: {
      money: {
        amount_cents: number | null
        currency: string | null
      }
    }""",
    """export const Constants = {
  public: {
    Enums: {
      visit_status: ["booked", "in_progress", "done"],
    },
  },
} as const""",
    """  __InternalSupabase: {
    PostgrestVersion: "12"
  }""",
]

FIXTURE_MD_EXPECT = [
    "- Migrations applied: 1 (`0001_fixture.sql` … `0001_fixture.sql`)",
    "- Counts: 3 tables, 1 views, 7 functions (6 non-trigger), 1 enums, 1 composite types, 1 public RLS policies, "
    "1 storage buckets (1 storage.objects policies)",
    "## Foundation (0001–0009): tenancy, shop setup, CRM, catalog, jobs, scheduling",
    "#### `visits`\n\nfile `0001_fixture.sql` · RLS on · realtime: **yes**\n\n> Visits of a shop.",
    "| photo_path | text | yes |  | Object name in the visit-photos bucket: <shop_id>/<visit_id>/<file>. |",
    "| seq | bigint | no | identity always |",
    "| tags | text[] | no | '{}'::text[] |  |",
    "| `open_visits` (view) | 0001_fixture.sql | security_invoker view (base-table RLS applies to the caller) |  | "
    "anon=SIUD; authenticated=SIUD |",
    "| name_upper | text | yes | GENERATED: upper(name) |",
    "- FK `visit_notes_visit_fk`: FOREIGN KEY (shop_id, visit_id) REFERENCES visits(shop_id, id) ON DELETE CASCADE",
    "- Grants: anon=—; authenticated=— + cols SELECT(id, shop_id, body)",
    "  - `visits_select` SELECT to authenticated — USING `(status <> 'done'::visit_status)`",
    "- Policies: none (RLS on → no direct access except service_role / SECURITY DEFINER RPCs)",
    "- Triggers: `visits_touch` BEFORE UPDATE ROW → visits_touch()",
    "| `visit_count` | p_shop_id, p_status? | authenticated · DEFINER | `integer` | 0001_fixture.sql |",
    "| `purge_visits` | p_before? | `void` | 0001_fixture.sql |",
    "- **DEFINER** · sql · stable · exec: authenticated, service_role · search_path=\"\" · file `0001_fixture.sql`\n"
    "- Number of visits of a shop, optionally with one status.",
    "- `visits_touch()` — invoker · `0001_fixture.sql` · used by visits.visits_touch",
    "- `visit_status`: booked | in_progress | done  _(0001_fixture.sql)_",
    "- `money`(amount_cents bigint, currency text)  _(0001_fixture.sql)_ — A money amount with its currency.",
    "| `visit-photos` | no | 1048576 B (1 MiB) | image/png |",
    "- Layout: `<shop_id>/<visit_id>/<file>` _(documented in `0001_fixture.sql`)_",
    "- Folder 1: `shop_id` of `can_see_visit`",
    "- Folder 2: `visit_id` of `can_see_visit`",
    "- Stored in: `visits.photo_path`",
    "- `public.visits` — subscribers only receive rows their RLS SELECT policies allow",
]


def self_test(repo: Path) -> int:
    """Generate both files from FIXTURE_MIGRATION and check them; also prove
    that --pg-env introspection equals the throwaway-cluster path, that the
    output is deterministic and that the cluster is always removed."""
    failures: list[str] = []

    def expect(name: str, cond: bool, detail: str = "") -> None:
        if not cond:
            failures.append(name + (f": {detail}" if detail else ""))

    if not (repo / "web/node_modules/.bin/prettier").exists():
        print("gen_types self-test: web/node_modules/.bin/prettier not found: run `npm ci` in web/ first",
              file=sys.stderr)
        return 2
    _install_signal_cleanup()
    with tempfile.TemporaryDirectory(prefix="gt-self-") as tmp:
        fx = Path(tmp)
        (fx / "scripts").mkdir()
        shutil.copy2(repo / "scripts/test_db.sh", fx / "scripts/test_db.sh")
        shutil.copytree(repo / "supabase/shim", fx / "supabase/shim")
        (fx / "supabase/migrations").mkdir(parents=True)
        (fx / "supabase/migrations/0001_fixture.sql").write_text(FIXTURE_MIGRATION)
        (fx / "web").mkdir()
        (fx / "web/node_modules").symlink_to(repo / "web/node_modules", target_is_directory=True)

        cluster = Cluster(fx)
        try:
            applied = cluster.start()
            meta = introspect(cluster)
            env = dict(os.environ, PGHOST=cluster.host, PGPORT=cluster.port, PGUSER="postgres",
                       PGDATABASE="postgres", PG_BIN=cluster.pg_bin)
            env.pop("DATABASE_URL", None)
            env.pop("PGSERVICE", None)
            meta_env = introspect(EnvDatabase(env))
            parent = cluster.parent
        finally:
            cluster.stop()
        expect("cluster directory removed after stop", not os.path.exists(parent), parent)
        expect("fixture migration applied", applied == 1, str(applied))
        expect("--pg-env introspection equals the throwaway cluster",
               json.dumps(meta, sort_keys=True) == json.dumps(meta_env, sort_keys=True))

        out = render(meta, applied, fx)
        ts, md = out["files"][TS_PATH], out["files"][MD_PATH]
        again = render(json.loads(json.dumps(meta)), applied, fx)
        expect("rendering is deterministic", again["files"] == out["files"])
        via_env = render(meta_env, None, fx)
        expect("--pg-env output equals cluster output", via_env["files"] == out["files"])
        for snippet in FIXTURE_TS_EXPECT:
            expect("database.types.ts contains:\n" + snippet, snippet in ts)
        for snippet in FIXTURE_MD_EXPECT:
            expect("SCHEMA.md contains:\n" + snippet, snippet in md)
        expect("trigger functions are not RPCs", "visits_touch:" not in ts)
        expect("storage helper without API use still typed", "storage_path_uuid: {" in ts)
        expect("Views block present", "    Views: {\n      open_visits: {" in ts)
        expect("tables sorted", ts.index("      shops: {") < ts.index("      visit_notes: {") < ts.index("      visits: {"))

        # write + --check round trip through the CLI on the fixture repo
        meta_file = fx / "meta.json"
        meta_file.write_text(json.dumps(meta))
        cmd = [sys.executable, str(Path(__file__).resolve()), "--repo", str(fx), "--meta", str(meta_file)]
        first = subprocess.run(cmd, capture_output=True, text=True)
        expect("CLI write succeeds", first.returncode == 0, first.stderr)
        check = subprocess.run(cmd + ["--check"], capture_output=True, text=True)
        expect("CLI --check passes right after writing", check.returncode == 0, check.stderr)
        (fx / MD_PATH).write_text((fx / MD_PATH).read_text() + "hand edit\n")
        stale = subprocess.run(cmd + ["--check"], capture_output=True, text=True)
        expect("CLI --check fails on a hand-edited SCHEMA.md",
               stale.returncode == 1 and "docs/SCHEMA.md" in stale.stderr, stale.stderr)
        no_env = subprocess.run([sys.executable, str(Path(__file__).resolve()), "--repo", str(fx), "--pg-env",
                                 "--check"], capture_output=True, text=True,
                                env={k: v for k, v in os.environ.items() if k not in PG_ENV_VARS})
        expect("--pg-env without a connection is a clear setup error",
               no_env.returncode == 2 and "--pg-env needs a connection" in no_env.stderr, no_env.stderr)

    if failures:
        for f in failures:
            print(f"self-test FAILED: {f}")
        return 1
    print("gen_types self-test: all checks passed")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=str(DEFAULT_REPO))
    ap.add_argument("--ts-out", default=None, help=f"default: <repo>/{TS_PATH}")
    ap.add_argument("--md-out", default=None, help=f"default: <repo>/{MD_PATH}")
    ap.add_argument("--postgrest-version", default="12",
                    help="emitted as __InternalSupabase.PostgrestVersion ('' to omit); Supabase serves PostgREST 12")
    ap.add_argument("--no-prettier", action="store_true",
                    help="skip prettier (output then differs from the committed file; previews only)")
    ap.add_argument("--check", action="store_true", help="write nothing; exit 1 if an output is stale")
    ap.add_argument("--meta", default=None, help="render from a saved --dump-meta JSON instead of a live cluster")
    ap.add_argument("--pg-env", action="store_true",
                    help="introspect the already migrated database named by PGHOST/PGPORT/PGUSER/PGDATABASE "
                         "(or PGSERVICE / DATABASE_URL), e.g. one left running by `scripts/test_db.sh --keep`, "
                         "instead of starting a throwaway cluster")
    ap.add_argument("--self-test", action="store_true",
                    help="generate from a tiny fixture schema on a throwaway cluster and check the output")
    ap.add_argument("--dump-meta", default=None, help="also write the raw introspection JSON here")
    args = ap.parse_args()
    if args.self_test:
        return self_test(Path(args.repo).resolve())

    repo = Path(args.repo).resolve()
    targets = {TS_PATH: Path(args.ts_out) if args.ts_out else repo / TS_PATH,
               MD_PATH: Path(args.md_out) if args.md_out else repo / MD_PATH}
    try:
        if args.meta:
            meta, applied = load_meta_file(Path(args.meta))
        else:
            meta, applied = load_live_meta(repo, pg_env=args.pg_env)
        if args.dump_meta:
            Path(args.dump_meta).write_text(json.dumps(meta, indent=1, sort_keys=True) + "\n")
        out = render(meta, applied, repo, args.postgrest_version, use_prettier=not args.no_prettier)
    except (GenError, RuntimeError) as exc:
        print(f"gen_types: {exc}", file=sys.stderr)
        return 2

    if args.check:
        stale = stale_files(repo, out["files"], targets)
        if stale:
            print("gen_types: stale generated files (run `python3 scripts/gen_types.py`): " + ", ".join(stale),
                  file=sys.stderr)
            return 1
        print(f"gen_types: generated files are current ({out['summary']})")
        return 0

    for rel, text in out["files"].items():
        path = targets[rel]
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        print(f"wrote {path} ({len(text.splitlines())} lines)")
    print(f"schema: {out['summary']}")
    for wmsg in out["warnings"]:
        print(f"warning: {wmsg}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
