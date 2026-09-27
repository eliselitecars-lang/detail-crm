/**
 * Typed wrapper over `supabase.functions.invoke` for the money features.
 * Every edge-function error body is `{ error, code, details? }`
 * (supabase/functions/README.md → Errors); clients branch on `code` and
 * `details.reason` (e.g. `authentication_required` on a saved-card charge).
 */
import { FunctionsHttpError } from '@supabase/supabase-js';
import { z } from 'zod';
import { AppError, edgeFunctionError, type AppErrorOptions } from '@/lib/errors';
import { supabase } from '@/lib/supabase';

export type EdgeFunctionName = 'payments' | 'messaging' | 'account';

export class EdgeFunctionError extends AppError {
  /** Stable edge error code (`payment_failed`, `unprocessable`, `conflict`…). */
  readonly edgeCode: string | null;
  /** `details.reason` when the function supplied one. */
  readonly reason: string | null;
  readonly details: Readonly<Record<string, unknown>>;

  constructor(
    message: string,
    options: AppErrorOptions & {
      edgeCode?: string | null;
      reason?: string | null;
      details?: Record<string, unknown>;
    },
  ) {
    super(message, options);
    this.name = 'EdgeFunctionError';
    this.edgeCode = options.edgeCode ?? null;
    this.reason = options.reason ?? null;
    this.details = options.details ?? {};
  }
}

const errorBodySchema = z.object({
  error: z.string().optional(),
  code: z.string().optional(),
  details: z.record(z.string(), z.unknown()).optional(),
});

async function readErrorBody(error: unknown): Promise<z.infer<typeof errorBodySchema> | null> {
  if (!(error instanceof FunctionsHttpError)) return null;
  const context: unknown = error.context;
  if (!(context instanceof Response)) return null;
  try {
    const body: unknown = await context.clone().json();
    const parsed = errorBodySchema.safeParse(body);
    return parsed.success ? parsed.data : null;
  } catch {
    return null;
  }
}

/** Maps any invoke error to an EdgeFunctionError (friendly message + code/reason). */
export async function toEdgeError(error: unknown): Promise<EdgeFunctionError> {
  if (error instanceof EdgeFunctionError) return error;
  const base = await edgeFunctionError(error);
  const body = await readErrorBody(error);
  const details = body?.details ?? {};
  const reason = typeof details.reason === 'string' ? details.reason : null;
  return new EdgeFunctionError(base.message, {
    kind: base.kind,
    status: base.status,
    code: body?.code ?? base.code,
    cause: error,
    edgeCode: body?.code ?? null,
    reason,
    details,
  });
}

/**
 * Invokes `fn` with `{ action, ...params }` and validates the JSON result.
 * Throws EdgeFunctionError on any failure.
 */
export async function invokeEdge<S extends z.ZodType>(
  fn: EdgeFunctionName,
  action: string,
  params: Record<string, unknown>,
  schema: S,
): Promise<z.output<S>> {
  let response: Awaited<ReturnType<typeof supabase.functions.invoke<unknown>>>;
  try {
    response = await supabase.functions.invoke<unknown>(fn, { body: { action, ...params } });
  } catch (error) {
    throw await toEdgeError(error);
  }
  if (response.error) throw await toEdgeError(response.error);
  const parsed = schema.safeParse(response.data);
  if (!parsed.success) {
    throw new EdgeFunctionError('The server sent an unexpected response. Please try again.', {
      kind: 'server',
      cause: parsed.error,
    });
  }
  return parsed.data;
}
