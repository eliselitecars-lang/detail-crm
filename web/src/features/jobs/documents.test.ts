import { describe, expect, it } from 'vitest';
import {
  DOCUMENT_MAX_BYTES,
  documentContentType,
  documentDisplayName,
  documentKindLabel,
  documentProblem,
  jobDocumentPath,
  safeFileName,
} from './documents';

describe('job documents', () => {
  it('accepts what the documents bucket accepts, by type or extension', () => {
    expect(documentContentType({ name: 'quote.pdf', type: 'application/pdf' })).toBe(
      'application/pdf',
    );
    // browsers often send no type for Office files and HEIC photos
    expect(documentContentType({ name: 'Spec Sheet.DOCX', type: '' })).toBe(
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    );
    expect(documentContentType({ name: 'IMG_1.heic', type: '' })).toBe('image/heic');
    expect(documentContentType({ name: 'movie.mp4', type: 'video/mp4' })).toBeNull();
    expect(documentContentType({ name: 'script.exe', type: '' })).toBeNull();
  });

  it('refuses empty, oversized and unsupported files', () => {
    expect(documentProblem({ name: 'a.pdf', type: 'application/pdf', size: 10 })).toBeNull();
    expect(documentProblem({ name: 'a.pdf', type: 'application/pdf', size: 0 })).toMatch(/empty/);
    expect(
      documentProblem({ name: 'a.pdf', type: 'application/pdf', size: DOCUMENT_MAX_BYTES + 1 }),
    ).toMatch(/25 MB/);
    expect(documentProblem({ name: 'a.zip', type: 'application/zip', size: 10 })).toMatch(/PDF/);
  });

  it('builds the 4-segment object name the storage policies expect', () => {
    expect(jobDocumentPath('shop-1', 'job-1', 'u-1', 'Warranty card (2026).pdf')).toBe(
      'shop-1/jobs/job-1/u-1-Warranty-card-2026.pdf',
    );
    const path = jobDocumentPath('s', 'j', 'u', '../../etc/passwd');
    expect(path.split('/')).toHaveLength(4);
    expect(path).not.toContain('..');
    expect(safeFileName('Épreuve café.pdf')).toBe('Epreuve-cafe.pdf');
    expect(safeFileName('???')).toBe('file');
    const long = safeFileName(`${'a'.repeat(300)}.xlsx`);
    expect(long.length).toBeLessThanOrEqual(100);
    expect(long.endsWith('.xlsx')).toBe(true);
  });

  it('keeps the original name for display and labels the kind', () => {
    expect(documentDisplayName('  Café invoice.pdf ')).toBe('Café invoice.pdf');
    expect(documentDisplayName('x'.repeat(300))).toHaveLength(255);
    expect(documentKindLabel('application/pdf')).toBe('PDF');
    expect(documentKindLabel('application/msword')).toBe('Word');
    expect(documentKindLabel('application/vnd.ms-excel')).toBe('Excel');
    expect(documentKindLabel('text/csv')).toBe('CSV');
    expect(documentKindLabel('image/png')).toBe('Image');
  });
});
