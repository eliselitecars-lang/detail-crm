/**
 * Keeps supabase/config.toml, the function directories and deno.json in sync:
 * every deployable function must have an explicit, reviewed verify_jwt choice
 * and use the shared pinned import map.
 */
import { assert, assertEquals } from "@std/assert";
import { parse } from "@std/toml";

const FUNCTIONS_DIR = new URL("../", import.meta.url);
const CONFIG = new URL("../../config.toml", import.meta.url);

/**
 * The reviewed gateway-JWT decision per function (see config.toml comments).
 * false = the function authenticates every request itself (webhook
 * signature, cron secret, public token, or in-function JWT verification).
 */
const EXPECTED_VERIFY_JWT: Record<string, boolean> = {
  "stripe-connect": true,
  "payments": false,
  "stripe-webhook": false,
  "messaging": false,
  "invites": true,
  "storage-purge": false,
  "account": true,
  "push": false,
  "calendar-feed": false,
  "public-media": false,
  "sms-provisioning": false,
  "webhooks": false,
  "pdf": false,
  "billing": false,
  "billing-webhook": false,
};

interface FunctionConfig {
  verify_jwt?: unknown;
  import_map?: unknown;
}

async function loadConfig(): Promise<Record<string, unknown>> {
  return parse(await Deno.readTextFile(CONFIG)) as Record<string, unknown>;
}

async function functionDirs(): Promise<string[]> {
  const names: string[] = [];
  for await (const entry of Deno.readDir(FUNCTIONS_DIR)) {
    if (!entry.isDirectory || entry.name.startsWith("_") || entry.name.startsWith(".")) continue;
    names.push(entry.name);
  }
  return names.sort();
}

Deno.test("config.toml: planned functions have the reviewed verify_jwt and shared import map", async () => {
  const config = await loadConfig();
  const functions = (config.functions ?? {}) as Record<string, FunctionConfig>;
  assertEquals(Object.keys(functions).sort(), Object.keys(EXPECTED_VERIFY_JWT).sort());
  for (const [name, expected] of Object.entries(EXPECTED_VERIFY_JWT)) {
    assertEquals(functions[name]?.verify_jwt, expected, `${name}.verify_jwt`);
    assertEquals(functions[name]?.import_map, "./functions/deno.json", `${name}.import_map`);
  }
});

Deno.test("config.toml: every function directory is declared and has an index.ts", async () => {
  const config = await loadConfig();
  const declared = Object.keys((config.functions ?? {}) as Record<string, unknown>);
  for (const dir of await functionDirs()) {
    assert(declared.includes(dir), `supabase/functions/${dir} has no [functions.${dir}] entry`);
    const index = await Deno.stat(new URL(`${dir}/index.ts`, FUNCTIONS_DIR)).catch(() => null);
    assert(index?.isFile, `supabase/functions/${dir}/index.ts is missing`);
  }
});

Deno.test("config.toml: edge runtime is Deno 2", async () => {
  const config = await loadConfig();
  const runtime = config.edge_runtime as Record<string, unknown> | undefined;
  assertEquals(runtime?.deno_version, 2);
  assertEquals(runtime?.enabled, true);
});

Deno.test("deno.json: remote dependencies are pinned to exact versions", async () => {
  const denoJson = JSON.parse(await Deno.readTextFile(new URL("deno.json", FUNCTIONS_DIR))) as {
    imports: Record<string, string>;
  };
  for (const [name, specifier] of Object.entries(denoJson.imports)) {
    assert(
      /^(npm|jsr):@?[a-z0-9/_.-]+@\d+\.\d+\.\d+\/?$/.test(specifier),
      `${name} -> ${specifier} must be pinned to an exact version`,
    );
  }
});

/**
 * The runbooks name the functions that keep the gateway JWT check in plain
 * text (an operator deploys, rolls back and reads the deployed verify_jwt
 * back against them). Each marker phrase must be preceded, within its own
 * clause, by exactly the verify_jwt = true functions of config.toml.
 */
const JWT_DOC_MARKERS: { file: URL; marker: string; count: number }[] = [
  {
    file: new URL("../../../docs/DEPLOY.md", import.meta.url),
    marker: "keep the gateway JWT check",
    count: 2,
  },
  {
    file: new URL("../README.md", import.meta.url),
    marker: "require a Supabase JWT at the gateway",
    count: 1,
  },
  {
    file: new URL("../README.md", import.meta.url),
    marker: "(`verify_jwt = true`) the Supabase gateway",
    count: 1,
  },
];

/** Function names in backticks between the clause start (`;`, `. `, a blank line) and `end`. */
function functionsNamedBefore(text: string, end: number, known: Set<string>): string[] {
  const head = text.slice(0, end);
  const start = Math.max(head.lastIndexOf(";"), head.lastIndexOf(". "), head.lastIndexOf("\n\n"));
  const clause = head.slice(start + 1);
  return [...clause.matchAll(/`([a-z0-9-]+)`/g)].map((m) => m[1] ?? "").filter((n) => known.has(n));
}

Deno.test("docs: the functions said to keep the gateway JWT check are exactly the verify_jwt = true ones", async () => {
  const config = await loadConfig();
  const functions = (config.functions ?? {}) as Record<string, FunctionConfig>;
  const known = new Set(Object.keys(functions));
  const gated = Object.keys(functions).filter((n) => functions[n]?.verify_jwt === true).sort();
  assert(gated.length > 0, "config.toml has verify_jwt = true functions");
  for (const { file, marker, count } of JWT_DOC_MARKERS) {
    const text = (await Deno.readTextFile(file)).replace(
      /\s+/g,
      (ws) => (ws.includes("\n\n") ? "\n\n" : " "),
    );
    const hits: number[] = [];
    for (let i = text.indexOf(marker); i >= 0; i = text.indexOf(marker, i + 1)) hits.push(i);
    const where = `${file.pathname.split("/").slice(-2).join("/")} '${marker}'`;
    assertEquals(hits.length, count, `${where}: occurrences`);
    for (const at of hits) {
      assertEquals(functionsNamedBefore(text, at, known).sort(), gated, where);
    }
  }
});
