/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_SUPABASE_URL?: string;
  readonly VITE_SUPABASE_ANON_KEY?: string;
  /** Operator details for /privacy and /terms (all optional; see features/legal/operator.ts). */
  readonly VITE_LEGAL_ENTITY_NAME?: string;
  readonly VITE_SUPPORT_EMAIL?: string;
  readonly VITE_LEGAL_COUNTRY?: string;
  readonly VITE_LEGAL_ADDRESS?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
