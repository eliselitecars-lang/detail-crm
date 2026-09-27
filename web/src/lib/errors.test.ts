import { describe, expect, it } from 'vitest';
import {
  AppError,
  edgeFunctionError,
  errorMessage,
  GENERIC_ERROR_MESSAGE,
  isNonRetryable,
  sentenceCase,
  toAppError,
} from './errors';

const pg = (code: string, message: string, details: string | null = null) => ({
  code,
  message,
  details,
  hint: null,
  name: 'PostgrestError',
});

describe('toAppError — Postgres / PostgREST', () => {
  it('hides RLS policy denials behind a permission message', () => {
    const e = toAppError(
      pg('42501', 'new row violates row-level security policy for table "jobs"'),
    );
    expect(e.kind).toBe('permission');
    expect(e.message).toBe("You don't have permission to do that.");
    expect(e.message).not.toMatch(/jobs|policy/);
  });

  it('shows our own RAISE EXCEPTION text, sentence-cased', () => {
    expect(errorMessage(pg('22023', 'slug "app" is reserved'))).toBe('Slug "app" is reserved.');
    expect(errorMessage(pg('P0001', 'That time slot is no longer available.'))).toBe(
      'That time slot is no longer available.',
    );
    const denied = toAppError(pg('42501', 'only owners and admins can invite team members'));
    expect(denied.kind).toBe('permission');
    expect(denied.message).toBe('Only owners and admins can invite team members.');
    const missing = toAppError(pg('P0002', 'invite not found'));
    expect(missing.kind).toBe('not_found');
    expect(missing.message).toBe('Invite not found.');
    const taken = toAppError(pg('23505', 'slug "joes" is already taken'));
    expect(taken.kind).toBe('conflict');
    expect(taken.message).toBe('Slug "joes" is already taken.');
  });

  it('replaces Postgres constraint wording with friendly text and keeps the constraint', () => {
    const dup = toAppError(
      pg(
        '23505',
        'duplicate key value violates unique constraint "coupons_shop_code_key"',
        'Key (...) already exists.',
      ),
    );
    expect(dup.kind).toBe('conflict');
    expect(dup.constraint).toBe('coupons_shop_code_key');
    expect(dup.message).toBe('That already exists. Use a different value.');

    expect(
      errorMessage(
        pg(
          '23514',
          'new row for relation "shops" violates check constraint "shops_tax_rate_bps_check"',
        ),
      ),
    ).toMatch(/out of the allowed range/);
    expect(
      errorMessage(pg('23502', 'null value in column "name" violates not-null constraint')),
    ).toBe('A required field is missing.');
    expect(
      errorMessage(
        pg(
          '23503',
          'update or delete on table "services" violates foreign key constraint "x" on table "job_line_items"',
          'Key (id)=(1) is still referenced from table "job_line_items".',
        ),
      ),
    ).toMatch(/still in use/);
    expect(
      errorMessage(
        pg(
          '23503',
          'insert or update on table "jobs" violates foreign key constraint "jobs_customer_fk"',
        ),
      ),
    ).toMatch(/no longer exists/);
    expect(
      errorMessage(
        pg(
          '23P01',
          'conflicting key value violates exclusion constraint "business_hours_no_overlap"',
        ),
      ),
    ).toBe('That overlaps with an existing entry.');
    expect(errorMessage(pg('22P02', 'invalid input syntax for type uuid: "abc"'))).toBe(
      'Some values are not in a valid format.',
    );
  });

  it('maps PostgREST codes', () => {
    expect(
      toAppError(pg('PGRST116', 'JSON object requested, multiple (or no) rows returned')).kind,
    ).toBe('not_found');
    expect(toAppError(pg('PGRST301', 'JWT expired')).kind).toBe('session_expired');
    expect(errorMessage(pg('PGRST202', 'Could not find the function public.search_shop'))).toBe(
      'This feature is not available on the server yet.',
    );
  });
});

describe('toAppError — auth, network, unknown', () => {
  it('maps Supabase Auth errors by code and message', () => {
    expect(
      errorMessage({
        name: 'AuthApiError',
        code: 'invalid_credentials',
        message: 'Invalid login credentials',
        status: 400,
      }),
    ).toBe('Email or password is incorrect.');
    expect(
      errorMessage({ name: 'AuthApiError', message: 'Email not confirmed', status: 400 }),
    ).toMatch(/confirm your email/);
    expect(toAppError({ name: 'AuthApiError', message: 'Too many', status: 429 }).kind).toBe(
      'rate_limited',
    );
    expect(
      toAppError({ name: 'AuthWeakPasswordError', code: 'weak_password', message: 'weak' }).kind,
    ).toBe('validation');
  });

  it('maps network failures', () => {
    expect(toAppError(new TypeError('Failed to fetch')).kind).toBe('network');
    expect(toAppError({ name: 'FunctionsFetchError', message: 'x' }).kind).toBe('network');
  });

  it('falls back to a generic message and keeps the cause', () => {
    const original = new Error('boom: internal detail');
    const e = toAppError(original);
    expect(e.message).toBe(GENERIC_ERROR_MESSAGE);
    expect(e.cause).toBe(original);
    expect(toAppError('weird').message).toBe(GENERIC_ERROR_MESSAGE);
  });

  it('is idempotent and classifies retryability', () => {
    const e = new AppError('x', { kind: 'permission' });
    expect(toAppError(e)).toBe(e);
    expect(isNonRetryable(e)).toBe(true);
    expect(isNonRetryable(new TypeError('Failed to fetch'))).toBe(false);
  });
});

describe('edgeFunctionError', () => {
  it('reads the JSON error body of FunctionsHttpError', async () => {
    const response = new Response(JSON.stringify({ error: 'Invoice is already paid.' }), {
      status: 409,
    });
    const e = await edgeFunctionError({ name: 'FunctionsHttpError', context: response });
    expect(e.message).toBe('Invoice is already paid.');
    expect(e.kind).toBe('conflict');
  });
  it('falls back on non-JSON bodies', async () => {
    const e = await edgeFunctionError({
      name: 'FunctionsHttpError',
      context: new Response('nope', { status: 403 }),
    });
    expect(e.kind).toBe('permission');
  });
});

describe('sentenceCase', () => {
  it('capitalizes and terminates', () => {
    expect(sentenceCase('invite not found')).toBe('Invite not found.');
    expect(sentenceCase('Done!')).toBe('Done!');
  });
});

describe('edgeFunctionError status fallbacks (non-envelope bodies)', () => {
  const httpError = (status: number, body: unknown) => ({
    name: 'FunctionsHttpError',
    context: new Response(typeof body === 'string' ? body : JSON.stringify(body), { status }),
  });

  it('maps the gateway 401 body to an expired session', async () => {
    const e = await edgeFunctionError(httpError(401, { code: 401, message: 'Invalid JWT' }));
    expect(e.kind).toBe('session_expired');
    expect(e.message).toBe('Your session has expired. Sign in again.');
    expect(e.status).toBe(401);
  });

  it('maps a gateway 403 / 404 / 429 without our envelope by status', async () => {
    const forbidden = await edgeFunctionError(httpError(403, { msg: 'forbidden' }));
    expect(forbidden.kind).toBe('permission');
    expect(forbidden.message).toBe("You don't have permission to do that.");
    const missing = await edgeFunctionError(
      httpError(404, { code: 'NOT_FOUND', message: 'Requested function was not found' }),
    );
    expect(missing.kind).toBe('not_found');
    expect(missing.message).toBe('Not found.');
    const limited = await edgeFunctionError(httpError(429, 'Too Many Requests'));
    expect(limited.kind).toBe('rate_limited');
  });

  it('never shows gateway text for 5xx', async () => {
    const e = await edgeFunctionError(httpError(502, { message: 'upstream connect error' }));
    expect(e.kind).toBe('server');
    expect(e.message).toBe(GENERIC_ERROR_MESSAGE);
    const html = await edgeFunctionError(httpError(504, '<html>Gateway Timeout</html>'));
    expect(html.message).toBe(GENERIC_ERROR_MESSAGE);
  });

  it('uses message / msg for other statuses and keeps our envelope text', async () => {
    const e = await edgeFunctionError(httpError(400, { message: 'body is not valid JSON' }));
    expect(e.kind).toBe('validation');
    expect(e.message).toBe('Body is not valid JSON.');
    const envelope = await edgeFunctionError(
      httpError(401, { error: 'Sign in to continue.', code: 'unauthorized' }),
    );
    expect(envelope.message).toBe('Sign in to continue.');
    expect(envelope.kind).toBe('session_expired');
  });
});

describe('PT404 (public RPC not found)', () => {
  it('is a not_found error showing our message', () => {
    const e = toAppError({ code: 'PT404', message: 'quote not found', details: null, hint: null });
    expect(e.kind).toBe('not_found');
    expect(e.message).toBe('Quote not found.');
    expect(isNonRetryable(e)).toBe(true);
  });
});
