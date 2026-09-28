import { CheckCircle2, CircleAlert, Info, X } from 'lucide-react';
import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { cn } from '@/lib/cn';
import { errorMessage } from '@/lib/errors';
import { IconButton } from './IconButton';
import {
  ToastContext,
  type ToastApi,
  type ToastErrorAction,
  type ToastInput,
  type ToastTone,
} from './toastContext';

interface ToastItem extends ToastInput {
  id: number;
  tone: ToastTone;
}

const icons = {
  success: <CheckCircle2 className="text-success size-5" aria-hidden="true" />,
  error: <CircleAlert className="text-danger size-5" aria-hidden="true" />,
  info: <Info className="text-primary size-5" aria-hidden="true" />,
};

const MAX_TOASTS = 5;

/**
 * Toasts dismiss themselves (errors after 8 s, others after 5 s), but the
 * clock stops while the pointer is over the notifications or focus is inside
 * one — and while the tab is hidden — then resumes with the time that was
 * left (at least MIN_RESUME_MS), so a toast can be read, and its text or
 * action reached, at any pace (WCAG 2.2.1). A toast with an action stays
 * until it is used or dismissed unless it sets its own `duration`.
 */
const MIN_RESUME_MS = 2000;

interface ToastTimer {
  /** Time left when paused (or when it was started). */
  remaining: number;
  /** When the running timeout fires (null while paused). */
  deadline: number | null;
  handle: ReturnType<typeof setTimeout> | null;
}

/** (Re)starts a toast's countdown with `ms` left. */
function startTimer(timer: ToastTimer, ms: number, onDone: () => void) {
  timer.remaining = ms;
  timer.deadline = Date.now() + ms;
  timer.handle = setTimeout(onDone, ms);
}

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<ToastItem[]>([]);
  const seq = useRef(0);
  const timers = useRef(new Map<number, ToastTimer>());
  /** Ids on screen, oldest first (mirrors `toasts`, readable outside a state updater). */
  const visible = useRef<number[]>([]);
  /** Adds an action to recognised errors (see ToastApi.setErrorAction). */
  const errorAction = useRef<ToastErrorAction | null>(null);
  /** Why the clocks are stopped: pointer over / focus inside the region, tab hidden. */
  const pausedBy = useRef(new Set<'hover' | 'focus' | 'hidden'>());
  const dismissRef = useRef<(id: number) => void>(() => undefined);
  const regionRef = useRef<HTMLDivElement>(null);

  const clearTimer = useCallback((id: number) => {
    const timer = timers.current.get(id);
    if (timer?.handle) clearTimeout(timer.handle);
    timers.current.delete(id);
  }, []);

  const pause = useCallback((reason: 'hover' | 'focus' | 'hidden') => {
    const wasRunning = pausedBy.current.size === 0;
    pausedBy.current.add(reason);
    if (!wasRunning) return;
    const now = Date.now();
    for (const timer of timers.current.values()) {
      if (timer.handle) clearTimeout(timer.handle);
      if (timer.deadline !== null) timer.remaining = Math.max(timer.deadline - now, 0);
      timer.handle = null;
      timer.deadline = null;
    }
  }, []);

  const resume = useCallback((reason: 'hover' | 'focus' | 'hidden') => {
    if (!pausedBy.current.delete(reason) || pausedBy.current.size > 0) return;
    for (const [id, timer] of timers.current) {
      startTimer(timer, Math.max(timer.remaining, MIN_RESUME_MS), () => dismissRef.current(id));
    }
  }, []);

  const dismiss = useCallback(
    (id: number) => {
      clearTimer(id);
      visible.current = visible.current.filter((v) => v !== id);
      setToasts((list) => list.filter((t) => t.id !== id));
    },
    [clearTimer],
  );
  useEffect(() => {
    dismissRef.current = dismiss;
  }, [dismiss]);

  // Nothing may fire after the provider unmounts (tests, route teardown).
  useEffect(() => {
    const pending = timers.current;
    return () => {
      for (const timer of pending.values()) if (timer.handle) clearTimeout(timer.handle);
      pending.clear();
    };
  }, []);

  // A focused toast that goes away (dismissed, action used) may not fire blur:
  // once focus is no longer inside the notifications, the clocks run again.
  useEffect(() => {
    if (!pausedBy.current.has('focus')) return;
    const region = regionRef.current;
    if (!region || !region.contains(document.activeElement)) resume('focus');
  }, [toasts, resume]);

  // A hidden tab keeps its toasts until the person comes back.
  useEffect(() => {
    const onVisibility = () => {
      if (document.visibilityState === 'hidden') pause('hidden');
      else resume('hidden');
    };
    document.addEventListener('visibilitychange', onVisibility);
    return () => document.removeEventListener('visibilitychange', onVisibility);
  }, [pause, resume]);

  const show = useCallback(
    (input: ToastInput) => {
      seq.current += 1;
      const id = seq.current;
      const tone = input.tone ?? 'info';
      // At most MAX_TOASTS on screen: the oldest are dropped with their timers.
      const kept = [...visible.current, id];
      for (const dropped of kept.splice(0, Math.max(0, kept.length - MAX_TOASTS))) {
        clearTimer(dropped);
      }
      visible.current = kept;
      setToasts((list) => [...list.slice(-(MAX_TOASTS - 1)), { ...input, id, tone }]);
      const duration = input.duration ?? (input.action ? 0 : tone === 'error' ? 8000 : 5000);
      if (duration > 0) {
        const timer: ToastTimer = { remaining: duration, deadline: null, handle: null };
        timers.current.set(id, timer);
        if (pausedBy.current.size === 0) startTimer(timer, duration, () => dismissRef.current(id));
      }
      return id;
    },
    [clearTimer],
  );

  const api = useMemo<ToastApi>(
    () => ({
      show,
      dismiss,
      success: (title, description) =>
        show({ title, tone: 'success', ...(description !== undefined ? { description } : {}) }),
      info: (title, description) =>
        show({ title, tone: 'info', ...(description !== undefined ? { description } : {}) }),
      error: (titleOrError, description) => {
        const action =
          typeof titleOrError === 'string' ? undefined : errorAction.current?.(titleOrError);
        return show({
          title: typeof titleOrError === 'string' ? titleOrError : errorMessage(titleOrError),
          tone: 'error',
          ...(description !== undefined ? { description } : {}),
          ...(action ? { action } : {}),
        });
      },
      setErrorAction: (action) => {
        errorAction.current = action;
        return () => {
          if (errorAction.current === action) errorAction.current = null;
        };
      },
    }),
    [show, dismiss],
  );

  return (
    <ToastContext value={api}>
      {children}
      <section
        aria-label="Notifications"
        className="pointer-events-none fixed inset-x-0 bottom-0 z-[60] flex flex-col items-center gap-2 p-4 sm:items-end"
      >
        <div
          aria-live="polite"
          aria-atomic="false"
          ref={regionRef}
          className="flex w-full flex-col items-center gap-2 sm:items-end"
          onPointerEnter={() => pause('hover')}
          onPointerLeave={() => resume('hover')}
          onFocus={() => pause('focus')}
          onBlur={(event) => {
            // Still inside another toast (Tab between them): stay paused.
            if (event.currentTarget.contains(event.relatedTarget)) return;
            resume('focus');
          }}
        >
          {toasts.map((toast) => (
            <div
              key={toast.id}
              role={toast.tone === 'error' ? 'alert' : 'status'}
              className={cn(
                'rounded-card border-line bg-surface shadow-pop pointer-events-auto flex w-full max-w-sm items-start gap-3 border p-3',
              )}
            >
              <span className="mt-0.5 shrink-0">{icons[toast.tone]}</span>
              <div className="min-w-0 flex-1">
                <p className="text-ink text-sm font-medium">{toast.title}</p>
                {toast.description && (
                  <p className="text-muted mt-0.5 text-sm">{toast.description}</p>
                )}
                {toast.action && (
                  <button
                    type="button"
                    className="text-primary-ink mt-1.5 text-sm font-medium hover:underline"
                    onClick={() => {
                      toast.action?.onClick();
                      dismiss(toast.id);
                    }}
                  >
                    {toast.action.label}
                  </button>
                )}
              </div>
              <IconButton
                size="sm"
                label="Dismiss notification"
                icon={<X />}
                onClick={() => dismiss(toast.id)}
              />
            </div>
          ))}
        </div>
      </section>
    </ToastContext>
  );
}
