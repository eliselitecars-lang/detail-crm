/**
 * Dev-server ports for the mocked e2e suite. PW_PORT moves both (e.g. when
 * 5173 is taken): the configured app on PW_PORT, the Setup-screen app (blank
 * Supabase env) on PW_PORT + 1.
 */
export const CONFIGURED_PORT = Number(process.env.PW_PORT ?? 5173);
export const UNCONFIGURED_PORT = CONFIGURED_PORT + 1;
