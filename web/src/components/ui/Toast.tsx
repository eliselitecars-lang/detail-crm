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

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<ToastItem[]>([]);
  const seq = useRef(0);
  const timers = useRef(new Map<number, ReturnType<typeof setTimeout>>());
  /** Ids on screen, oldest first (mirrors `toasts`, readable outside a state updater). */
  const visible = useRef<number[]>([]);
  /** Adds an action to recognised errors (see ToastApi.setErrorAction). */
  const errorAction = useRef<ToastErrorAction | null>(null);

  const clearTimer = useCallback((id: number) => {
    const timer = timers.current.get(id);
    if (timer !== undefined) clearTimeout(timer);
    timers.current.delete(id);
  }, []);

  const dismiss = useCallback(
    (id: number) => {
      clearTimer(id);
      visible.current = visible.current.filter((v) => v !== id);
      setToasts((list) => list.filter((t) => t.id !== id));
    },
    [clearTimer],
  );

  // Nothing may fire after the provider unmounts (tests, route teardown).
  useEffect(() => {
    const pending = timers.current;
    return () => {
      for (const timer of pending.values()) clearTimeout(timer);
      pending.clear();
    };
  }, []);

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
      const duration = input.duration ?? (tone === 'error' ? 8000 : 5000);
      if (duration > 0) {
        timers.current.set(
          id,
          setTimeout(() => dismiss(id), duration),
        );
      }
      return id;
    },
    [clearTimer, dismiss],
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
          className="flex w-full flex-col items-center gap-2 sm:items-end"
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
