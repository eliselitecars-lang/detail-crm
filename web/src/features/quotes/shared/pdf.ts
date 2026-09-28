/**
 * Quote / invoice PDFs from the `pdf` edge function (P-34). The server
 * renders exactly what the /q and /i pages show; nothing is computed here.
 *
 *   * public: GET /functions/v1/pdf?action=quote|invoice&token=<link token>
 *     opens the PDF in the browser (a plain link, no session needed);
 *   * staff: POST staff_document {shop_id, kind, id} with the user's JWT
 *     (drafts included, marked DRAFT) → downloaded as a file.
 */
import { useMutation } from '@tanstack/react-query';
import { downloadBlob } from '@/lib/download';
import { functionsUrl } from '@/lib/env';
import { useShop } from '@/features/shop/shopContext';
import { invokeEdgeBlob } from './edge';
import type { PublicDocKind } from './format';

/** The public PDF link of a document (null when Supabase isn't configured). */
export function publicPdfUrl(kind: PublicDocKind, token: string): string | null {
  const params = new URLSearchParams({ action: kind, token });
  return functionsUrl(`/functions/v1/pdf?${params.toString()}`);
}

/** "quote-1001.pdf" / "invoice-2040.pdf" (the server's own file names). */
export function pdfFileName(kind: PublicDocKind, number: number): string {
  return `${kind}-${number}.pdf`;
}

export interface StaffPdfInput {
  kind: PublicDocKind;
  id: string;
  number: number;
}

/** Downloads a quote / invoice PDF as staff (manager+, or a collector for invoices). */
export function useStaffPdf() {
  const { shopId } = useShop();
  return useMutation({
    mutationFn: async ({ kind, id, number }: StaffPdfInput) => {
      const blob = await invokeEdgeBlob('pdf', 'staff_document', { shop_id: shopId, kind, id });
      downloadBlob(blob, pdfFileName(kind, number));
    },
  });
}
