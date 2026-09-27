/**
 * New-job flow data: customer search/create, vehicles, and the staged job
 * creation (job → line items → assignments). Each stage is one statement,
 * so a failure leaves earlier stages saved; the caller keeps the created job
 * id and retries only what is left — the job is never inserted twice.
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { unwrap, unwrapRequired, type InsertRow, type Row } from '@/lib/db';
import { AppError } from '@/lib/errors';
import { shopKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { useShop } from '@/features/shop/shopContext';
import { jobKeys, type LineDraft } from './api';
import { unwrapList } from './db';

export type CustomerOption = Pick<
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
>;

const CUSTOMER_COLUMNS =
  'id, first_name, last_name, company, email, phone, address_line1, address_line2, city, region, postal_code';

/** LIKE-escape user input for ilike patterns. */
export function escapeLike(value: string): string {
  return value.replace(/[\\%_]/g, (c) => `\\${c}`);
}

export function useCustomerSearch(query: string) {
  const { shopId } = useShop();
  const q = query.trim().toLowerCase();
  return useQuery({
    queryKey: jobKeys.customerSearch(shopId, q),
    queryFn: async (): Promise<CustomerOption[]> => {
      let request = supabase
        .from('customers')
        .select(CUSTOMER_COLUMNS)
        .eq('shop_id', shopId)
        .is('archived_at', null);
      if (q) request = request.ilike('search_text', `%${escapeLike(q)}%`);
      return unwrapList(await request.order('updated_at', { ascending: false }).limit(20));
    },
  });
}

export function useCustomer(customerId: string | null) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: jobKeys.customer(shopId, customerId ?? ''),
    enabled: customerId !== null,
    queryFn: async (): Promise<CustomerOption> =>
      unwrapRequired(
        await supabase
          .from('customers')
          .select(CUSTOMER_COLUMNS)
          .eq('shop_id', shopId)
          .eq('id', customerId ?? '')
          .maybeSingle(),
        'customer',
      ),
  });
}

export type NewCustomer = Pick<
  InsertRow<'customers'>,
  'first_name' | 'last_name' | 'company' | 'email' | 'phone'
>;

export function useCreateCustomer() {
  const queryClient = useQueryClient();
  const { shopId } = useShop();
  return useMutation({
    mutationFn: async (values: NewCustomer): Promise<CustomerOption> =>
      unwrapRequired(
        await supabase
          .from('customers')
          .insert({ ...values, shop_id: shopId, source: 'staff' })
          .select(CUSTOMER_COLUMNS)
          .single(),
        'customer',
      ),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: shopKey(shopId, 'customers') }),
  });
}

export type VehicleOption = Pick<
  Row<'vehicles'>,
  'id' | 'year' | 'make' | 'model' | 'trim' | 'color' | 'vin' | 'license_plate' | 'category_id'
>;

const VEHICLE_COLUMNS = 'id, year, make, model, trim, color, vin, license_plate, category_id';

export function useCustomerVehicles(customerId: string | null) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: jobKeys.vehicles(shopId, customerId ?? ''),
    enabled: customerId !== null,
    queryFn: async (): Promise<VehicleOption[]> =>
      unwrapList(
        await supabase
          .from('vehicles')
          .select(VEHICLE_COLUMNS)
          .eq('shop_id', shopId)
          .eq('customer_id', customerId ?? '')
          .is('archived_at', null)
          .order('created_at', { ascending: false }),
      ),
  });
}

export type NewVehicle = Pick<
  InsertRow<'vehicles'>,
  'year' | 'make' | 'model' | 'trim' | 'color' | 'vin' | 'license_plate' | 'category_id'
>;

export function useCreateVehicle(customerId: string | null) {
  const queryClient = useQueryClient();
  const { shopId } = useShop();
  return useMutation({
    mutationFn: async (values: NewVehicle): Promise<VehicleOption> => {
      if (!customerId) throw new AppError('Choose a customer first.', { kind: 'validation' });
      return unwrapRequired(
        await supabase
          .from('vehicles')
          .insert({ ...values, shop_id: shopId, customer_id: customerId })
          .select(VEHICLE_COLUMNS)
          .single(),
        'vehicle',
      );
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: shopKey(shopId, 'vehicles') }),
  });
}

export type NewJobFields = Pick<
  InsertRow<'jobs'>,
  | 'customer_id'
  | 'vehicle_id'
  | 'status'
  | 'scheduled_start'
  | 'scheduled_end'
  | 'location_type'
  | 'service_address_line1'
  | 'service_address_line2'
  | 'service_city'
  | 'service_region'
  | 'service_postal_code'
  | 'resource_id'
  | 'notes'
  | 'internal_notes'
  | 'discount_kind'
  | 'discount_value'
  | 'deposit_required_cents'
>;

export interface CreateJobInput {
  job: NewJobFields;
  lines: LineDraft[];
  assigneeIds: string[];
}

/** Progress of a (possibly partially failed) creation; pass it back to retry. */
export interface CreateJobProgress {
  jobId: string | null;
  linesSaved: boolean;
  assignmentsSaved: boolean;
}

export const EMPTY_PROGRESS: CreateJobProgress = {
  jobId: null,
  linesSaved: false,
  assignmentsSaved: false,
};

export class CreateJobError extends AppError {
  readonly progress: CreateJobProgress;
  constructor(message: string, progress: CreateJobProgress, cause: unknown) {
    super(message, { cause });
    this.name = 'CreateJobError';
    this.progress = progress;
  }
}

function causeMessage(error: unknown): string {
  return error instanceof Error ? error.message : 'Please try again.';
}

export async function createJobStaged(
  shopId: string,
  taxRateBps: number,
  input: CreateJobInput,
  previous: CreateJobProgress,
): Promise<CreateJobProgress> {
  const progress = { ...previous };
  let jobId = progress.jobId;
  if (!jobId) {
    try {
      const { id } = unwrapRequired(
        await supabase
          .from('jobs')
          .insert({
            ...input.job,
            shop_id: shopId,
            number: 0, // assigned by jobs_integrity
            tax_rate_bps: taxRateBps, // the shop's current rate; the server owns the math
            source: 'staff',
          })
          .select('id')
          .single(),
        'job',
      ) ?? { id: null };
      if (!id) throw new AppError('The job was not returned by the server.');
      jobId = id;
      progress.jobId = id;
    } catch (error) {
      throw new CreateJobError(
        `The job couldn’t be created: ${causeMessage(error)}`,
        progress,
        error,
      );
    }
  }
  if (!progress.linesSaved) {
    try {
      if (input.lines.length > 0) {
        unwrap(
          await supabase.from('job_line_items').insert(
            input.lines.map((line, i) => ({
              ...line,
              shop_id: shopId,
              job_id: jobId,
              sort: i + 1,
            })),
          ),
        );
      }
      progress.linesSaved = true;
    } catch (error) {
      throw new CreateJobError(
        `The job was created, but its services couldn’t be saved: ${causeMessage(error)}`,
        progress,
        error,
      );
    }
  }
  if (!progress.assignmentsSaved) {
    try {
      if (input.assigneeIds.length > 0) {
        unwrap(
          await supabase.from('job_assignments').upsert(
            input.assigneeIds.map((memberId) => ({
              shop_id: shopId,
              job_id: jobId,
              member_id: memberId,
            })),
            { onConflict: 'shop_id,job_id,member_id', ignoreDuplicates: true },
          ),
        );
      }
      progress.assignmentsSaved = true;
    } catch (error) {
      throw new CreateJobError(
        `The job was created, but the team assignments couldn’t be saved: ${causeMessage(error)}`,
        progress,
        error,
      );
    }
  }
  return progress;
}

export function useCreateJob() {
  const queryClient = useQueryClient();
  const { shopId, shop } = useShop();
  return useMutation({
    mutationFn: ({ input, progress }: { input: CreateJobInput; progress: CreateJobProgress }) =>
      createJobStaged(shopId, shop.tax_rate_bps, input, progress),
    onSettled: () => queryClient.invalidateQueries({ queryKey: jobKeys.all(shopId) }),
  });
}
