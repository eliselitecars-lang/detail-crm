/**
 * Job documents (P-25) — pure helpers: accepted file types (the documents
 * bucket's allowed MIME types, 0071), size limit and the object name the
 * storage policies and documents_validate expect:
 * `<shop_id>/jobs/<job_id>/<uuid>-<safe file name>` (exactly 4 segments).
 */

/** documents bucket: 25 MiB per file. */
export const DOCUMENT_MAX_BYTES = 26_214_400;

/** Extension → MIME type the bucket accepts. */
const DOCUMENT_TYPES: Record<string, string> = {
  pdf: 'application/pdf',
  doc: 'application/msword',
  docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  xls: 'application/vnd.ms-excel',
  xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  txt: 'text/plain',
  csv: 'text/csv',
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  png: 'image/png',
  webp: 'image/webp',
  heic: 'image/heic',
};

const ALLOWED_MIME = new Set(Object.values(DOCUMENT_TYPES));

/** For <input accept> / FileDropzone: extensions and MIME types. */
export const DOCUMENT_ACCEPT: readonly string[] = [
  ...Object.keys(DOCUMENT_TYPES).map((ext) => `.${ext}`),
  ...ALLOWED_MIME,
];

export const DOCUMENT_FORMATS_TEXT =
  'PDF, Word, Excel, text / CSV or an image (JPEG, PNG, WebP, HEIC)';

function extensionOf(name: string): string | null {
  const match = /\.([a-z0-9]{1,5})$/i.exec(name.trim());
  return match?.[1]?.toLowerCase() ?? null;
}

/**
 * The content type to store: the browser's when the bucket accepts it,
 * else the one of the file's extension (browsers often report '' for HEIC
 * or Office files). null = not an accepted document.
 */
export function documentContentType(file: Pick<File, 'name' | 'type'>): string | null {
  const type = file.type.toLowerCase();
  if (ALLOWED_MIME.has(type)) return type;
  const ext = extensionOf(file.name);
  return ext ? (DOCUMENT_TYPES[ext] ?? null) : null;
}

/** Why a file can't be uploaded as a document, or null. */
export function documentProblem(file: Pick<File, 'name' | 'type' | 'size'>): string | null {
  if (!documentContentType(file)) return `Upload a ${DOCUMENT_FORMATS_TEXT}.`;
  if (file.size === 0) return 'The file is empty.';
  if (file.size > DOCUMENT_MAX_BYTES) return 'Files can be at most 25 MB.';
  return null;
}

/**
 * A storage-safe version of a file name: ASCII letters, digits, dot, dash
 * and underscore only, at most 100 characters, extension kept.
 */
export function safeFileName(name: string): string {
  const ascii = name
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[^A-Za-z0-9._-]+/g, '-')
    .replace(/-{2,}/g, '-')
    .replace(/-+\./g, '.')
    .replace(/^[-.]+|[-.]+$/g, '');
  const cleaned = ascii || 'file';
  if (cleaned.length <= 100) return cleaned;
  const ext = extensionOf(cleaned);
  const stem = cleaned.slice(0, 100 - (ext ? ext.length + 1 : 0)).replace(/[-.]+$/, '');
  return ext ? `${stem}.${ext}` : stem;
}

/** documents bucket object name for a job file. */
export function jobDocumentPath(
  shopId: string,
  jobId: string,
  id: string,
  fileName: string,
): string {
  return `${shopId}/jobs/${jobId}/${id}-${safeFileName(fileName)}`;
}

/** The name stored in documents.file_name (1..255 characters, trimmed). */
export function documentDisplayName(name: string): string {
  const trimmed = name.trim() || 'file';
  return trimmed.length <= 255 ? trimmed : trimmed.slice(0, 255);
}

/** "PDF", "Word", "Image" — a short kind label for the list. */
export function documentKindLabel(contentType: string): string {
  if (contentType === 'application/pdf') return 'PDF';
  if (contentType.includes('word')) return 'Word';
  if (contentType.includes('excel') || contentType.includes('spreadsheet')) return 'Excel';
  if (contentType === 'text/csv') return 'CSV';
  if (contentType.startsWith('text/')) return 'Text';
  if (contentType.startsWith('image/')) return 'Image';
  return 'File';
}
