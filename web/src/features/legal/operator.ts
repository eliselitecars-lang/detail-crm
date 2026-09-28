/**
 * Who operates this deployment, for the privacy policy and terms. Build-time
 * values (VITE_LEGAL_ENTITY_NAME, VITE_SUPPORT_EMAIL, VITE_LEGAL_COUNTRY,
 * optional VITE_LEGAL_ADDRESS; see web/README.md and docs/DEPLOY.md). Any of
 * them may be missing: the pages then use neutral wording ("the operator of
 * this service") and never make up a company, address or email.
 */
export interface LegalOperator {
  /** Legal name of the company or person running this deployment. */
  entityName: string | null;
  /** Where people send privacy requests and questions. */
  supportEmail: string | null;
  /** Governing law, written as it reads after "the laws of" (e.g. "the State of Delaware, United States"). */
  country: string | null;
  /** Postal address (one line or several). */
  address: string | null;
}

const MAX_LENGTH = 300;
const EMAIL_RE = /^[^\s@<>()[\]",;:]+@[^\s@<>()[\]",;:]+\.[^\s@<>()[\]",;:]{2,}$/;

/** A trimmed value, or null when blank, a `YOUR_…` placeholder or implausibly long. */
function text(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const trimmed = value.replace(/\s+/g, ' ').trim();
  if (!trimmed || /^YOUR_/i.test(trimmed) || trimmed.length > MAX_LENGTH) return null;
  return trimmed;
}

/** Keeps line breaks (a postal address may be written over several lines). */
function address(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const lines = value
    .split(/\r?\n|\\n/)
    .map((line) => line.replace(/\s+/g, ' ').trim())
    .filter(Boolean);
  const joined = lines.join('\n');
  if (!joined || /^YOUR_/i.test(joined) || joined.length > MAX_LENGTH) return null;
  return joined;
}

function email(value: unknown): string | null {
  const trimmed = text(value);
  return trimmed && EMAIL_RE.test(trimmed) ? trimmed : null;
}

export function readLegalOperator(
  source: Record<string, unknown> = import.meta.env,
): LegalOperator {
  return {
    entityName: text(source.VITE_LEGAL_ENTITY_NAME),
    supportEmail: email(source.VITE_SUPPORT_EMAIL),
    country: text(source.VITE_LEGAL_COUNTRY),
    address: address(source.VITE_LEGAL_ADDRESS),
  };
}

/** This build's operator details. */
export const LEGAL_OPERATOR: LegalOperator = readLegalOperator();

/** VITE_LEGAL_ENTITY_NAME, or "the operator of this service" (mid-sentence). */
export function operatorName(operator: LegalOperator): string {
  return operator.entityName ?? 'the operator of this service';
}

/** The same at the start of a sentence. */
export function operatorNameStart(operator: LegalOperator): string {
  return operator.entityName ?? 'The operator of this service';
}

/** When the text was last changed (update together with the wording in content.tsx). */
export const LEGAL_LAST_UPDATED = { iso: '2026-09-28', label: 'September 28, 2026' } as const;
