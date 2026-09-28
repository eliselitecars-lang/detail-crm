/**
 * CSV import / export (P-5): import_customers / import_services (dry run and
 * commit, in chunks), import_batches history, and exports (customers and
 * vehicles through paged selects, jobs through export_jobs). Managers and up.
 */
import type { PostgrestError } from '@supabase/supabase-js';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { useShop } from '@/features/shop/shopContext';
import type { Json } from '@/lib/database.types';
import { unwrap, type Row } from '@/lib/db';
import { errorMessage } from '@/lib/errors';
import { shopKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { settingsKeys } from '../api';
import { chunk, IMPORT_CHUNK_SIZE, type BuiltRow, type ImportKind } from '../importing';
import { unwrapList } from './shared';

export type ImportBatch = Pick<
  Row<'import_batches'>,
  | 'id'
  | 'kind'
  | 'status'
  | 'file_name'
  | 'row_count'
  | 'created_count'
  | 'updated_count'
  | 'skipped_count'
  | 'error_count'
  | 'created_at'
>;

export const importKeys = {
  batches: (shopId: string) => [...settingsKeys.all(shopId), 'import-batches'] as const,
};

export function useImportBatches() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: importKeys.batches(shopId),
    queryFn: async (): Promise<ImportBatch[]> =>
      unwrapList(
        await supabase
          .from('import_batches')
          .select(
            'id, kind, status, file_name, row_count, created_count, updated_count, skipped_count, error_count, created_at',
          )
          .eq('shop_id', shopId)
          .order('created_at', { ascending: false })
          .limit(10),
      ),
  });
}

const resultRowSchema = z.object({
  row: z.number().int(),
  action: z.enum(['create', 'update', 'skip', 'error']),
  message: z.string().nullable().optional(),
  vehicle_action: z.enum(['create', 'match', 'none']).nullable().optional(),
});

const resultSchema = z.object({
  batch_id: z.string().nullable(),
  dry_run: z.boolean(),
  counts: z.object({
    created: z.number().int(),
    updated: z.number().int(),
    skipped: z.number().int(),
    errors: z.number().int(),
  }),
  rows: z.array(resultRowSchema),
});

export interface ImportRowResult {
  /** 1-based data row in the file. */
  line: number;
  action: 'create' | 'update' | 'skip' | 'error';
  vehicleAction: 'create' | 'match' | 'none' | null;
  message: string | null;
}

export interface ImportRunResult {
  dryRun: boolean;
  batchId: string | null;
  counts: { created: number; updated: number; skipped: number; errors: number };
  rows: ImportRowResult[];
}

export interface ImportRunInput {
  kind: ImportKind;
  rows: readonly BuiltRow[];
  dryRun: boolean;
  fileName: string;
  onProgress?: (done: number, total: number) => void;
  /**
   * Continues an interrupted commit (see ImportInterruptedError): the rows
   * before `from` are already saved in `batchId` and are not sent again.
   */
  resume?: { batchId: string; from: number; previous: ImportRunResult };
}

/**
 * A commit that stopped part-way. Each chunk is its own transaction, so the
 * chunks before the failure are saved: `savedRows` rows of `totalRows` (read
 * back from the import_batches row when possible, so a chunk whose response
 * was lost still counts). Sending the whole file again would create the
 * customers that have no email or phone a second time; resume from
 * `savedRows` instead.
 */
export class ImportInterruptedError extends Error {
  readonly partial: ImportRunResult & { batchId: string };
  readonly savedRows: number;
  readonly totalRows: number;
  readonly reason: unknown;

  constructor(
    partial: ImportRunResult & { batchId: string },
    savedRows: number,
    totalRows: number,
    reason: unknown,
  ) {
    super(errorMessage(reason));
    this.name = 'ImportInterruptedError';
    this.partial = partial;
    this.savedRows = savedRows;
    this.totalRows = totalRows;
    this.reason = reason;
  }
}

const batchCountsSchema = z.object({
  row_count: z.number().int(),
  created_count: z.number().int(),
  updated_count: z.number().int(),
  skipped_count: z.number().int(),
  error_count: z.number().int(),
});

/** The interruption, with the saved row count and totals taken from the batch row. */
async function interruption(
  shopId: string,
  total: ImportRunResult & { batchId: string },
  confirmedRows: number,
  totalRows: number,
  reason: unknown,
): Promise<ImportInterruptedError> {
  let savedRows = confirmedRows;
  let counts = total.counts;
  try {
    const { data, error } = await supabase
      .from('import_batches')
      .select('row_count, created_count, updated_count, skipped_count, error_count')
      .eq('shop_id', shopId)
      .eq('id', total.batchId)
      .limit(1);
    const batch = error ? undefined : batchCountsSchema.safeParse(data?.[0]);
    if (
      batch?.success &&
      batch.data.row_count >= confirmedRows &&
      batch.data.row_count <= totalRows
    ) {
      savedRows = batch.data.row_count;
      counts = {
        created: batch.data.created_count,
        updated: batch.data.updated_count,
        skipped: batch.data.skipped_count,
        errors: batch.data.error_count,
      };
    }
  } catch {
    // unreadable: fall back to the chunks this browser saw succeed
  }
  return new ImportInterruptedError({ ...total, counts }, savedRows, totalRows, reason);
}

/**
 * Sends the rows in chunks of 500. A commit continues one import_batches row
 * (the first chunk's batch_id), so the history shows one import per file.
 * A commit that fails after its first chunk throws ImportInterruptedError.
 */
export function useRunImport() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({ kind, rows, dryRun, fileName, onProgress, resume }: ImportRunInput) => {
      const fn = kind === 'customers' ? 'import_customers' : 'import_services';
      const from = resume && !dryRun ? Math.min(Math.max(resume.from, 0), rows.length) : 0;
      const total: ImportRunResult =
        resume && !dryRun
          ? {
              dryRun,
              batchId: resume.batchId,
              counts: { ...resume.previous.counts },
              rows: [...resume.previous.rows],
            }
          : {
              dryRun,
              batchId: null,
              counts: { created: 0, updated: 0, skipped: 0, errors: 0 },
              rows: [],
            };
      const parts = chunk(rows.slice(from), IMPORT_CHUNK_SIZE);
      let done = from;
      onProgress?.(done, rows.length);
      for (const part of parts) {
        let result: z.infer<typeof resultSchema>;
        try {
          const raw = unwrap(
            await supabase.rpc(fn, {
              p_shop_id: shopId,
              p_rows: part.map((r) => r.payload) as Json,
              p_dry_run: dryRun,
              p_file_name: fileName.slice(0, 255),
              ...(total.batchId ? { p_batch_id: total.batchId } : {}),
            }),
          );
          result = resultSchema.parse(raw);
        } catch (error) {
          if (dryRun || !total.batchId) throw error;
          throw await interruption(
            shopId,
            { ...total, batchId: total.batchId },
            done,
            rows.length,
            error,
          );
        }
        if (!dryRun && result.batch_id) total.batchId = result.batch_id;
        total.counts.created += result.counts.created;
        total.counts.updated += result.counts.updated;
        total.counts.skipped += result.counts.skipped;
        total.counts.errors += result.counts.errors;
        for (const r of result.rows) {
          total.rows.push({
            line: part[r.row - 1]?.line ?? r.row,
            action: r.action,
            vehicleAction: r.vehicle_action ?? null,
            message: r.message ?? null,
          });
        }
        done += part.length;
        onProgress?.(done, rows.length);
      }
      return total;
    },
    onSettled: (_data, _error, input) => {
      if (input.dryRun) return undefined;
      return Promise.all([
        queryClient.invalidateQueries({ queryKey: importKeys.batches(shopId) }),
        queryClient.invalidateQueries({ queryKey: shopKey(shopId, 'customers') }),
        queryClient.invalidateQueries({ queryKey: shopKey(shopId, 'vehicles') }),
        queryClient.invalidateQueries({ queryKey: shopKey(shopId, 'catalog') }),
      ]);
    },
  });
}

// ---------------------------------------------------------------------------
// Exports
// ---------------------------------------------------------------------------

const PAGE = 1000;

/** Reads every page of a select (1000 rows each) until a short page. */
async function readAll<T>(
  page: (
    from: number,
    to: number,
  ) => PromiseLike<{ data: T[] | null; error: PostgrestError | null }>,
  onProgress?: (count: number) => void,
): Promise<T[]> {
  const rows: T[] = [];
  for (let from = 0; ; from += PAGE) {
    const data = unwrap(await page(from, from + PAGE - 1)) ?? [];
    rows.push(...data);
    onProgress?.(rows.length);
    if (data.length < PAGE) return rows;
  }
}

export type ExportCustomer = Pick<
  Row<'customers'>,
  | 'id'
  | 'first_name'
  | 'last_name'
  | 'company'
  | 'email'
  | 'phone'
  | 'address_line1'
  | 'address_line2'
  | 'city'
  | 'region'
  | 'postal_code'
  | 'country'
  | 'tags'
  | 'lifecycle'
  | 'source'
  | 'sms_opt_in'
  | 'email_opt_in'
  | 'notes'
  | 'custom_data'
  | 'created_at'
>;

export async function fetchExportCustomers(
  shopId: string,
  onProgress?: (count: number) => void,
): Promise<ExportCustomer[]> {
  return readAll(
    (from, to) =>
      supabase
        .from('customers')
        .select(
          'id, first_name, last_name, company, email, phone, address_line1, address_line2, city, region, postal_code, country, tags, lifecycle, source, sms_opt_in, email_opt_in, notes, custom_data, created_at',
        )
        .eq('shop_id', shopId)
        .is('archived_at', null)
        .order('created_at')
        .order('id')
        .range(from, to),
    onProgress,
  );
}

const exportVehicleSchema = z.object({
  year: z.number().nullable(),
  make: z.string().nullable(),
  model: z.string().nullable(),
  trim: z.string().nullable(),
  color: z.string().nullable(),
  license_plate: z.string().nullable(),
  vin: z.string().nullable(),
  category: z.object({ name: z.string() }).nullable(),
  customer: z
    .object({
      first_name: z.string().nullable(),
      last_name: z.string().nullable(),
      company: z.string().nullable(),
      email: z.string().nullable(),
      phone: z.string().nullable(),
    })
    .nullable(),
});
export type ExportVehicle = z.infer<typeof exportVehicleSchema>;

export async function fetchExportVehicles(
  shopId: string,
  onProgress?: (count: number) => void,
): Promise<ExportVehicle[]> {
  const rows = await readAll<unknown>(
    (from, to) =>
      supabase
        .from('vehicles')
        .select(
          'year, make, model, trim, color, license_plate, vin, category:vehicle_categories(name), customer:customers(first_name, last_name, company, email, phone)',
        )
        .eq('shop_id', shopId)
        .is('archived_at', null)
        .order('created_at')
        .order('id')
        .range(from, to),
    onProgress,
  );
  return z.array(exportVehicleSchema).parse(rows);
}

export type ExportJob = NonNullable<ReturnType<typeof parseJobs>>[number];

function parseJobs(rows: unknown) {
  return z
    .array(
      z.object({
        number: z.number(),
        status: z.string(),
        source: z.string(),
        location_type: z.string(),
        scheduled_local: z.string().nullable(),
        completed_local: z.string().nullable(),
        customer_name: z.string().nullable(),
        customer_email: z.string().nullable(),
        customer_phone: z.string().nullable(),
        vehicle: z.string().nullable(),
        services: z.string().nullable(),
        service_address: z.string().nullable(),
        total_cents: z.number(),
        paid_cents: z.number(),
        balance_cents: z.number(),
      }),
    )
    .parse(rows);
}

/** export_jobs(shop, from, to): jobs whose shop-local date falls in [from, to] (at most 3 years). */
export async function fetchExportJobs(shopId: string, from: string, to: string) {
  return parseJobs(
    unwrap(await supabase.rpc('export_jobs', { p_shop_id: shopId, p_from: from, p_to: to })),
  );
}
