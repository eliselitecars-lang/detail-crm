/**
 * Keeps supabase/setup/cron.sql and the runbook that describes it in sync:
 * every scheduled job is listed in the file's own header and in its
 * unschedule list, and docs/DEPLOY.md section 3.5 states the real job count
 * (an operator checks the Dashboard's cron list against it), and the
 * functions README's launch checklist lists every job by name.
 */
import { assert, assertEquals } from "@std/assert";

const CRON_SQL = new URL("../../setup/cron.sql", import.meta.url);
const DEPLOY_MD = new URL("../../../docs/DEPLOY.md", import.meta.url);
const README_MD = new URL("../README.md", import.meta.url);

const NUMBER_WORDS = [
  "zero",
  "one",
  "two",
  "three",
  "four",
  "five",
  "six",
  "seven",
  "eight",
  "nine",
  "ten",
  "eleven",
  "twelve",
  "thirteen",
  "fourteen",
  "fifteen",
  "sixteen",
  "seventeen",
  "eighteen",
  "nineteen",
  "twenty",
];

function scheduledJobs(sql: string): string[] {
  return [...sql.matchAll(/^select cron\.schedule\(\s*'([^']+)'/gm)].map((m) => m[1] ?? "");
}

function headerJobs(sql: string): string[] {
  const start = sql.indexOf("-- Jobs:");
  assert(start >= 0, "cron.sql header has a 'Jobs:' list");
  const names: string[] = [];
  for (const line of sql.slice(start).split("\n").slice(1)) {
    if (!line.startsWith("--")) break;
    const m = /^--\s{3}(detail-crm-[a-z0-9-]+)\s/.exec(line);
    if (m?.[1]) names.push(m[1]);
  }
  return names;
}

function unscheduledJobs(sql: string): string[] {
  const m = /where j\.jobname in \(([^)]*)\)/.exec(sql);
  assert(m?.[1], "cron.sql unschedules its jobs by name");
  return [...m[1].matchAll(/'([^']+)'/g)].map((x) => x[1] ?? "");
}

Deno.test("cron.sql: header list, unschedule list and schedule calls name the same jobs", async () => {
  const sql = await Deno.readTextFile(CRON_SQL);
  const scheduled = scheduledJobs(sql);
  assert(scheduled.length > 0, "cron.sql schedules jobs");
  assertEquals(new Set(scheduled).size, scheduled.length, "no job is scheduled twice");
  assertEquals(headerJobs(sql).sort(), [...scheduled].sort(), "header 'Jobs:' list");
  assertEquals(unscheduledJobs(sql).sort(), [...scheduled].sort(), "unschedule list");
});

Deno.test("DEPLOY.md 3.5 states cron.sql's job count", async () => {
  const sql = await Deno.readTextFile(CRON_SQL);
  const count = scheduledJobs(sql).length;
  const word = NUMBER_WORDS[count];
  assert(word, `no number word for ${count} jobs: extend NUMBER_WORDS`);
  const md = await Deno.readTextFile(DEPLOY_MD);
  const stated = [...md.matchAll(/schedules the (\w+) pg_cron jobs/g)].map((m) => m[1]);
  assertEquals(stated, [word], "DEPLOY.md: 'schedules the <count> pg_cron jobs'");
});

Deno.test("functions README launch checklist names every cron.sql job", async () => {
  const sql = await Deno.readTextFile(CRON_SQL);
  const md = await Deno.readTextFile(README_MD);
  const start = md.indexOf("Jobs today");
  assert(start >= 0, "README launch checklist has a 'Jobs today' list");
  const end = md.indexOf("cron.sql is https-only", start);
  assert(end > start, "README 'Jobs today' list ends before 'cron.sql is https-only'");
  const listed = [...md.slice(start, end).matchAll(/^\s*- `(detail-crm-[a-z0-9-]+)`/gm)].map((m) =>
    m[1] ?? ""
  );
  assertEquals(listed.sort(), scheduledJobs(sql).sort(), "README 'Jobs today' list");
});
