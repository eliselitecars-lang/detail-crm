import { useEffect, useState } from 'react';
import { shopToday, startOfNextShopDayUtc } from '@/lib/dates';

/** Longest single timer (browsers clamp setTimeout delays above ~24.8 days). */
const MAX_TIMEOUT_MS = 2 ** 31 - 1;

/**
 * "Now" for date presets that rolls over at midnight in the shop's time zone,
 * so "Today" / "This week" / "This month" follow the calendar while the page
 * stays open. Also re-checks when the tab becomes visible again (background
 * timers can be throttled or frozen) and on `refresh()` (e.g. picking a preset).
 */
export function useShopDayClock(timeZone: string): { now: Date; refresh: () => void } {
  const [now, setNow] = useState(() => new Date());

  useEffect(() => {
    const today = shopToday(timeZone, now);
    const rollIfNewDay = () => {
      const fresh = new Date();
      if (shopToday(timeZone, fresh) !== today) setNow(fresh);
    };
    const untilMidnight = Date.parse(startOfNextShopDayUtc(now, timeZone)) - Date.now();
    // +1s so the new day has definitely started in the shop's zone.
    const timer = setTimeout(
      () => setNow(new Date()),
      Math.min(Math.max(untilMidnight, 0) + 1000, MAX_TIMEOUT_MS),
    );
    const onVisible = () => {
      if (document.visibilityState === 'visible') rollIfNewDay();
    };
    document.addEventListener('visibilitychange', onVisible);
    window.addEventListener('focus', rollIfNewDay);
    return () => {
      clearTimeout(timer);
      document.removeEventListener('visibilitychange', onVisible);
      window.removeEventListener('focus', rollIfNewDay);
    };
  }, [now, timeZone]);

  const refresh = () => {
    const fresh = new Date();
    if (shopToday(timeZone, fresh) !== shopToday(timeZone, now)) setNow(fresh);
  };
  return { now, refresh };
}
