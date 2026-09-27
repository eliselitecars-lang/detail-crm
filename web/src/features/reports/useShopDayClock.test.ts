import { act, renderHook } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { shopToday } from '@/lib/dates';
import { useShopDayClock } from './useShopDayClock';

describe('useShopDayClock', () => {
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout', 'Date'] });
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  it('rolls "today" over at midnight in the shop time zone', () => {
    // 23:30 in Chicago on Mar 3 (05:30 UTC Mar 4).
    vi.setSystemTime(new Date('2026-03-04T05:30:00Z'));
    const { result } = renderHook(() => useShopDayClock('America/Chicago'));
    expect(shopToday('America/Chicago', result.current.now)).toBe('2026-03-03');

    act(() => {
      vi.advanceTimersByTime(29 * 60 * 1000);
    });
    expect(shopToday('America/Chicago', result.current.now)).toBe('2026-03-03');

    act(() => {
      vi.advanceTimersByTime(2 * 60 * 1000);
    });
    expect(shopToday('America/Chicago', result.current.now)).toBe('2026-03-04');
  });

  it('catches up when the tab becomes visible after sleeping', () => {
    vi.setSystemTime(new Date('2026-03-04T05:30:00Z'));
    const { result } = renderHook(() => useShopDayClock('America/Chicago'));
    // The machine slept: the clock jumped but no timer fired.
    vi.setSystemTime(new Date('2026-03-05T15:00:00Z'));
    act(() => {
      document.dispatchEvent(new Event('visibilitychange'));
    });
    expect(shopToday('America/Chicago', result.current.now)).toBe('2026-03-05');
  });

  it('refresh() picks up a new day and keeps the same instant otherwise', () => {
    vi.setSystemTime(new Date('2026-03-04T12:00:00Z'));
    const { result } = renderHook(() => useShopDayClock('UTC'));
    const first = result.current.now;
    vi.setSystemTime(new Date('2026-03-04T13:00:00Z'));
    act(() => result.current.refresh());
    expect(result.current.now).toBe(first);
    vi.setSystemTime(new Date('2026-03-05T00:00:05Z'));
    act(() => result.current.refresh());
    expect(shopToday('UTC', result.current.now)).toBe('2026-03-05');
  });
});
