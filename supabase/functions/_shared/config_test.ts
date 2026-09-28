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
