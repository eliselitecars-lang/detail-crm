/**
 * TEMPORARY permissive placeholder.
 *
 * The real file is generated from the live schema by `scripts/gen_types.py`
 * (contracts workflow) and overwrites this one. Nothing in the app may rely on
 * anything here except the exported `Database` type name, so the generated
 * version drops in without code changes. Rows are `Record<string, unknown>`
 * (never `any`) so code that compiles against this placeholder validates
 * results (zod / explicit mappers) instead of trusting shapes blindly.
 */

type PlaceholderTable = {
  Row: Record<string, unknown>;
  Insert: Record<string, unknown>;
  Update: Record<string, unknown>;
  Relationships: [];
};

type PlaceholderFunction = {
  Args: Record<string, unknown>;
  Returns: unknown;
};

export type Database = {
  __InternalSupabase: {
    PostgrestVersion: '12';
  };
  public: {
    Tables: Record<string, PlaceholderTable>;
    Views: Record<string, PlaceholderTable>;
    Functions: Record<string, PlaceholderFunction>;
    Enums: Record<string, string>;
    CompositeTypes: Record<string, Record<string, unknown>>;
  };
};
