/**
 * `public-media` edge function (supabase/functions/public-media): short-lived
 * (10 minute) signed URLs for what customers may see. The database decides
 * which objects a credential covers; the client only ever sends the token
 * (or a document id for portal clients), never a bucket or storage path.
 *
 *   job_report         {token}        /r/<token> report photos, videos, posters, damage photos, documents
 *   booking_documents  {token}        documents shared on a booking (/booking/<token>)
 *   portal_document    {document_id}  one document of a signed-in portal client
 *
 * Shared by the job-report, booking and portal features.
 */
import { z } from 'zod';
import { AppError } from '@/lib/errors';
import { supabase } from '@/lib/supabase';
import { toEdgeError } from '@/features/quotes/shared/edge';

export const MEDIA_KINDS = ['photo', 'video', 'poster', 'mark_photo', 'document'] as const;
export type MediaKind = (typeof MEDIA_KINDS)[number];

const mediaListSchema = z.object({
  expires_in: z.number(),
  items: z.array(
    z.object({ ref_id: z.string(), kind: z.enum(MEDIA_KINDS), url: z.string().url() }),
  ),
});
export type MediaList = z.output<typeof mediaListSchema>;

const singleMediaSchema = z.object({ expires_in: z.number(), url: z.string().url() });

/** Signed URLs expire after 10 minutes: refresh a little before that. */
export const MEDIA_REFRESH_MS = 8 * 60_000;
export const MEDIA_STALE_MS = 5 * 60_000;

async function invokeMedia<S extends z.ZodType>(
  body: Record<string, string>,
  schema: S,
): Promise<z.output<S>> {
  let response: Awaited<ReturnType<typeof supabase.functions.invoke<unknown>>>;
  try {
    response = await supabase.functions.invoke<unknown>('public-media', { body });
  } catch (error) {
    throw await toEdgeError(error);
  }
  if (response.error) throw await toEdgeError(response.error);
  const parsed = schema.safeParse(response.data);
  if (!parsed.success) {
    throw new AppError('The server sent an unexpected response. Please try again.', {
      kind: 'server',
      cause: parsed.error,
    });
  }
  return parsed.data;
}

/** Only https URLs are ever put in an href / src. */
function safeUrl(url: string): string | null {
  try {
    return new URL(url).protocol === 'https:' ? url : null;
  } catch {
    return null;
  }
}

/** A report's media as `${kind}:${ref_id}` → URL. */
export async function fetchReportMedia(token: string): Promise<Map<string, string>> {
  const list = await invokeMedia({ action: 'job_report', token }, mediaListSchema);
  return toMediaMap(list);
}

/** A booking's shared documents as `document:${id}` → URL. */
export async function fetchBookingDocumentMedia(token: string): Promise<Map<string, string>> {
  const list = await invokeMedia({ action: 'booking_documents', token }, mediaListSchema);
  return toMediaMap(list);
}

/** One portal document (the signed-in client's own). */
export async function fetchPortalDocumentUrl(documentId: string): Promise<string> {
  const result = await invokeMedia(
    { action: 'portal_document', document_id: documentId },
    singleMediaSchema,
  );
  const url = safeUrl(result.url);
  if (!url) throw new AppError('This document can’t be opened.', { kind: 'server' });
  return url;
}

export function mediaKey(kind: MediaKind, refId: string): string {
  return `${kind}:${refId}`;
}

export function toMediaMap(list: MediaList): Map<string, string> {
  const map = new Map<string, string>();
  for (const item of list.items) {
    const url = safeUrl(item.url);
    if (url) map.set(mediaKey(item.kind, item.ref_id), url);
  }
  return map;
}

/** "application/pdf" → "PDF", Word, image… for document rows. */
export function documentTypeLabel(contentType: string | null | undefined): string {
  const type = (contentType ?? '').toLowerCase();
  if (type === 'application/pdf') return 'PDF';
  if (type.startsWith('image/')) return 'Image';
  if (type.includes('word') || type.includes('officedocument.wordprocessing')) return 'Word';
  if (type.includes('sheet') || type.includes('excel')) return 'Spreadsheet';
  if (type.startsWith('text/')) return 'Text';
  return 'File';
}
