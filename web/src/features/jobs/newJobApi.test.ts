import { beforeEach, describe, expect, it, vi } from 'vitest';
import { builders, resetSupabaseMock, setTableResult } from '@/test/supabaseMock';
import {
  createJobStaged,
  CreateJobError,
  EMPTY_PROGRESS,
  escapeLike,
  type CreateJobInput,
} from './newJobApi';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

const INPUT: CreateJobInput = {
  job: {
    customer_id: 'cust-1',
    vehicle_id: 'veh-1',
    status: 'scheduled',
    scheduled_start: '2026-09-28T14:00:00.000Z',
    scheduled_end: '2026-09-28T16:00:00.000Z',
    location_type: 'shop',
    resource_id: null,
    notes: null,
    internal_notes: null,
    discount_kind: 'none',
    discount_value: 0,
    deposit_required_cents: 0,
  },
  lines: [
    {
      service_id: 'svc-1',
      vehicle_id: 'veh-1',
      name: 'Full detail',
      description: null,
      quantity: 1,
      unit_price_cents: 25000,
      discount_cents: 0,
      taxable: true,
      duration_minutes: 120,
    },
  ],
  assigneeIds: ['m-1'],
};

beforeEach(() => resetSupabaseMock());

describe('createJobStaged', () => {
  it('creates the job, then its lines, then assignments', async () => {
    setTableResult('jobs', { data: { id: 'job-1' } });
    const progress = await createJobStaged('shop-1', 875, INPUT, EMPTY_PROGRESS);
    expect(progress).toEqual({
      jobId: 'job-1',
      soldBySaved: true,
      linesSaved: true,
      assignmentsSaved: true,
    });
    const jobInsert = builders.jobs?.[0]?.insert.mock.calls[0]?.[0] as Record<string, unknown>;
    expect(jobInsert).toMatchObject({ shop_id: 'shop-1', customer_id: 'cust-1', source: 'staff' });
    // never sends totals — the server computes them
    expect(jobInsert).not.toHaveProperty('total_cents');
    expect(jobInsert).not.toHaveProperty('subtotal_cents');
    const lineInsert = builders.job_line_items?.[0]?.insert.mock.calls[0]?.[0];
    expect(lineInsert).toEqual([
      expect.objectContaining({ job_id: 'job-1', shop_id: 'shop-1', sort: 1, name: 'Full detail' }),
    ]);
    expect(builders.job_assignments?.[0]?.upsert).toHaveBeenCalledWith(
      [{ shop_id: 'shop-1', job_id: 'job-1', member_id: 'm-1' }],
      { onConflict: 'shop_id,job_id,member_id', ignoreDuplicates: true },
    );
  });

  it('keeps the created job on a partial failure and retries only what is left', async () => {
    setTableResult('jobs', { data: { id: 'job-1' } });
    setTableResult('job_line_items', {
      error: { message: 'a line item vehicle must belong to the customer', code: '23514' },
    });
    let failure: unknown;
    try {
      await createJobStaged('shop-1', 0, INPUT, EMPTY_PROGRESS);
    } catch (error) {
      failure = error;
    }
    expect(failure).toBeInstanceOf(CreateJobError);
    const progress = (failure as CreateJobError).progress;
    expect(progress).toEqual({
      jobId: 'job-1',
      soldBySaved: true,
      linesSaved: false,
      assignmentsSaved: false,
    });
    expect((failure as Error).message).toMatch(/job was created, but its services/);

    setTableResult('job_line_items', { data: null });
    const done = await createJobStaged('shop-1', 0, INPUT, progress);
    expect(done).toEqual({
      jobId: 'job-1',
      soldBySaved: true,
      linesSaved: true,
      assignmentsSaved: true,
    });
    // the job itself was inserted exactly once
    expect(builders.jobs).toHaveLength(1);
    expect(builders.job_line_items).toHaveLength(2);
  });

  it('keeps the seller the form chose, and applies “Nobody” after the insert', async () => {
    setTableResult('jobs', { data: { id: 'job-1' } });
    await createJobStaged(
      'shop-1',
      0,
      { ...INPUT, job: { ...INPUT.job, sold_by_member_id: 'm-1' } },
      EMPTY_PROGRESS,
    );
    // a named seller goes in the insert; nothing to undo
    expect(builders.jobs?.[0]?.insert.mock.calls[0]?.[0]).toMatchObject({
      sold_by_member_id: 'm-1',
    });
    expect(builders.jobs).toHaveLength(1);

    resetSupabaseMock();
    setTableResult('jobs', { data: { id: 'job-1' } });
    const progress = await createJobStaged(
      'shop-1',
      0,
      { ...INPUT, job: { ...INPUT.job, sold_by_member_id: null } },
      EMPTY_PROGRESS,
    );
    expect(progress.soldBySaved).toBe(true);
    // the server defaults a null seller to the creator: cleared right after
    const clear = builders.jobs?.[1];
    expect(clear?.update).toHaveBeenCalledWith({ sold_by_member_id: null });
    expect(clear?.eq).toHaveBeenCalledWith('id', 'job-1');
  });

  it('retries a failed “Nobody” without creating the job again', async () => {
    const input = { ...INPUT, job: { ...INPUT.job, sold_by_member_id: null } };
    const created = { ...EMPTY_PROGRESS, jobId: 'job-1' };
    setTableResult('jobs', { error: { message: 'permission denied', code: '42501' } });
    let failure: unknown;
    try {
      await createJobStaged('shop-1', 0, input, created);
    } catch (error) {
      failure = error;
    }
    expect(failure).toBeInstanceOf(CreateJobError);
    expect((failure as CreateJobError).progress).toEqual(created);
    expect((failure as Error).message).toMatch(/created, but “Sold by: Nobody”/);
    expect(builders.job_line_items).toBeUndefined();

    setTableResult('jobs', { data: null });
    const done = await createJobStaged('shop-1', 0, input, created);
    expect(done).toEqual({
      jobId: 'job-1',
      soldBySaved: true,
      linesSaved: true,
      assignmentsSaved: true,
    });
    // only the two clears: the job was never inserted again
    expect(builders.jobs?.every((b) => b.insert.mock.calls.length === 0)).toBe(true);
  });

  it('reports a failed job insert without progress', async () => {
    setTableResult('jobs', { error: { message: 'permission denied', code: '42501' } });
    await expect(createJobStaged('shop-1', 0, INPUT, EMPTY_PROGRESS)).rejects.toMatchObject({
      progress: EMPTY_PROGRESS,
    });
    expect(builders.job_line_items).toBeUndefined();
  });
});

describe('escapeLike', () => {
  it('escapes LIKE wildcards', () => {
    expect(escapeLike('50%_off\\')).toBe('50\\%\\_off\\\\');
  });
});
