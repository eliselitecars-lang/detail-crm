import { onlineManager } from '@tanstack/react-query';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { AppError } from '@/lib/errors';
import { createQueryClient, shouldRetryQuery } from './queryClient';

const networkError = () => new TypeError('Failed to fetch');

describe('createQueryClient offline behaviour', () => {
  afterEach(() => onlineManager.setOnline(true));

  it('runs a mutation while offline so it fails now instead of pausing and firing later', async () => {
    onlineManager.setOnline(false);
    const client = createQueryClient();
    const mutationFn = vi.fn(() => Promise.reject(networkError()));
    const mutation = client.getMutationCache().build(client, { mutationFn });
    await expect(mutation.execute(undefined)).rejects.toThrow('Failed to fetch');
    expect(mutationFn).toHaveBeenCalledTimes(1);
    expect(mutation.state.status).toBe('error');
    expect(mutation.state.isPaused).toBe(false);

    // Coming back online must not replay the abandoned write.
    onlineManager.setOnline(true);
    await client.resumePausedMutations();
    expect(mutationFn).toHaveBeenCalledTimes(1);
  });

  it('fails a query at once while offline (error state, not an endless "Loading…")', async () => {
    onlineManager.setOnline(false);
    const client = createQueryClient();
    const queryFn = vi.fn(() => Promise.reject(networkError()));
    await expect(client.fetchQuery({ queryKey: ['offline'], queryFn })).rejects.toThrow(
      'Failed to fetch',
    );
    expect(queryFn).toHaveBeenCalledTimes(1);
    expect(client.getQueryState(['offline'])).toMatchObject({
      status: 'error',
      fetchStatus: 'idle',
    });
  });
});

describe('shouldRetryQuery', () => {
  afterEach(() => onlineManager.setOnline(true));

  it('retries a network failure twice while online', () => {
    expect(shouldRetryQuery(0, networkError())).toBe(true);
    expect(shouldRetryQuery(1, networkError())).toBe(true);
    expect(shouldRetryQuery(2, networkError())).toBe(false);
  });

  it('does not retry a network failure while offline', () => {
    onlineManager.setOnline(false);
    expect(shouldRetryQuery(0, networkError())).toBe(false);
    // Other transient errors keep their retries.
    expect(shouldRetryQuery(0, new AppError('boom', { kind: 'server' }))).toBe(true);
  });

  it('never retries permanent errors', () => {
    expect(shouldRetryQuery(0, new AppError('no', { kind: 'permission' }))).toBe(false);
  });
});
