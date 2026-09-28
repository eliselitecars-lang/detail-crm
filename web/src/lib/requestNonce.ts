/**
 * Request nonces for server calls a person may retry (messages.request_nonce,
 * the edge money actions, and 0095's add_fee_line / import chunks): one
 * random value per user action, REUSED when that same action is retried after
 * an uncertain failure (network, server or unknown error: the first attempt
 * may have been applied, and the server then answers with its first result
 * instead of doing it twice), and RENEWED after a success or a definitive
 * refusal (validation, permission, conflict, subscription…), so a later,
 * deliberate repeat is a new request.
 */
import { useState } from 'react';
import { toAppError } from './errors';

/** Url-safe idempotency nonce, 8–64 characters `[A-Za-z0-9_-]` (the server's format). */
export function newRequestNonce(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID().replace(/-/g, '');
  }
  return `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 12)}`;
}

/** The request may or may not have been applied: retry it with the same nonce. */
export function isUncertainOutcome(error: unknown): boolean {
  const kind = toAppError(error).kind;
  return kind === 'network' || kind === 'server' || kind === 'unknown';
}

/**
 * One pending nonce per action key (the key names WHAT is being done, e.g.
 * `invoice:<id>:fee:<fee id>`, so a different action never reuses a nonce —
 * the server refuses a nonce reused for a different request).
 */
export class RequestNonces {
  private readonly pending = new Map<string, string>();

  /** The nonce for this action: the one of an unsettled earlier attempt, else a new one. */
  take(key: string): string {
    let nonce = this.pending.get(key);
    if (nonce === undefined) {
      nonce = newRequestNonce();
      this.pending.set(key, nonce);
    }
    return nonce;
  }

  /**
   * The attempt for `key` finished: its nonce is kept only when the outcome
   * is uncertain (pass the error; omit it after a success).
   */
  settle(key: string, error?: unknown): void {
    if (error !== undefined && error !== null && isUncertainOutcome(error)) return;
    this.pending.delete(key);
  }
}

/** A RequestNonces that lives as long as the component (one per form / dialog / hook user). */
export function useRequestNonces(): RequestNonces {
  const [nonces] = useState(() => new RequestNonces());
  return nonces;
}

/**
 * A short, stable fingerprint of a JSON-able value (FNV-1a, 32 bit, hex):
 * part of an action key when the payload itself decides what the action is
 * (an import chunk's rows).
 */
export function payloadFingerprint(value: unknown): string {
  const text = JSON.stringify(value) ?? '';
  let hash = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    hash ^= text.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(16).padStart(8, '0');
}
