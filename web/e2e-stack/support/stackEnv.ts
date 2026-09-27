import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

/**
 * Connection details of the real local stack, from the STACK_* environment
 * variables or scripts/stack/.state/stack.env (written by scripts/stack/up.sh).
 */
export interface StackEnv {
  apiUrl: string;
  functionsUrl: string;
  anonKey: string;
  serviceRoleKey: string;
  dbUrl: string;
  appUrl: string;
  mailpitUrl: string;
  stripeMockUrl: string;
  providerMockUrl: string;
  stripeWebhookSecret: string;
  twilioAuthToken: string;
  cronSecret: string;
}

const STATE_FILE = join(
  dirname(fileURLToPath(import.meta.url)),
  '..',
  '..',
  '..',
  'scripts',
  'stack',
  '.state',
  'stack.env',
);

function readStateFile(): Record<string, string> {
  if (!existsSync(STATE_FILE)) return {};
  const out: Record<string, string> = {};
  for (const line of readFileSync(STATE_FILE, 'utf8').split('\n')) {
    const match = /^([A-Z0-9_]+)=(.*)$/.exec(line.trim());
    if (match?.[1] !== undefined && match[2] !== undefined) out[match[1]] = match[2];
  }
  return out;
}

let cached: StackEnv | undefined;

export function stackEnv(): StackEnv {
  if (cached) return cached;
  const file = readStateFile();
  const get = (name: string, fallback?: string): string => {
    const value = process.env[name] ?? file[name] ?? fallback;
    if (value === undefined || value === '') {
      throw new Error(
        `${name} is not set: start the real stack with scripts/stack/up.sh (it writes ${STATE_FILE})`,
      );
    }
    return value;
  };
  const apiUrl = get('STACK_API_URL');
  cached = {
    apiUrl,
    functionsUrl: get('STACK_FUNCTIONS_URL', `${apiUrl}/functions/v1`),
    anonKey: get('STACK_ANON_KEY'),
    serviceRoleKey: get('STACK_SERVICE_ROLE_KEY'),
    dbUrl: get('STACK_DB_URL'),
    appUrl: get('STACK_APP_URL', 'http://127.0.0.1:5173'),
    mailpitUrl: get('STACK_MAILPIT_URL', 'http://127.0.0.1:54324'),
    stripeMockUrl: get('STACK_STRIPE_MOCK_URL', 'http://127.0.0.1:12111'),
    providerMockUrl: get('STACK_PROVIDER_MOCK_URL', 'http://127.0.0.1:12120'),
    stripeWebhookSecret: get('STACK_STRIPE_WEBHOOK_SECRET'),
    twilioAuthToken: get('STACK_TWILIO_AUTH_TOKEN'),
    cronSecret: get('STACK_CRON_SECRET'),
  };
  return cached;
}
