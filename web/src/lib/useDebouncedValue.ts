import { useEffect, useState } from 'react';

/**
 * `value`, updated only after it has stopped changing for `delayMs`
 * (e.g. a server preview of text being typed). Objects are compared by
 * their JSON, so a fresh object with the same content does not restart
 * the timer.
 */
export function useDebouncedValue<T>(value: T, delayMs: number): T {
  const [debounced, setDebounced] = useState(value);
  const key = JSON.stringify(value);
  useEffect(() => {
    const timer = setTimeout(() => setDebounced(JSON.parse(key) as T), delayMs);
    return () => clearTimeout(timer);
  }, [key, delayMs]);
  return debounced;
}
