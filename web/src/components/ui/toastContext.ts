import { createContext, use } from 'react';

export type ToastTone = 'success' | 'error' | 'info';

export interface ToastInput {
  title: string;
  description?: string;
  tone?: ToastTone;
  /**
   * ms before auto-dismiss; errors default to 8000, others 5000, and a toast
   * with an `action` stays (0) until used or dismissed. 0 = sticky. The clock
   * pauses while the toast is hovered, focused or the tab is hidden.
   */
  duration?: number;
  action?: { label: string; onClick: () => void };
}

/**
 * Gives an error toast an action for errors it recognises (e.g. the app shell
 * adds "Go to Billing" to subscription refusals for owners). Returns
 * undefined for everything else.
 */
export type ToastErrorAction = (error: unknown) => ToastInput['action'] | undefined;

export interface ToastApi {
  show: (toast: ToastInput) => number;
  success: (title: string, description?: string) => number;
  /**
   * Accepts a message or any thrown value (mapped via lib/errors). A thrown
   * value may get an action from the registered ToastErrorAction.
   */
  error: (titleOrError: unknown, description?: string) => number;
  info: (title: string, description?: string) => number;
  dismiss: (id: number) => void;
  /**
   * Registers the error action (one at a time; the latest wins). Returns the
   * function that removes it again (only if it is still the registered one).
   */
  setErrorAction: (action: ToastErrorAction) => () => void;
}

export const ToastContext = createContext<ToastApi | null>(null);

export function useToast(): ToastApi {
  const ctx = use(ToastContext);
  if (!ctx) throw new Error('useToast must be used inside <ToastProvider>');
  return ctx;
}
