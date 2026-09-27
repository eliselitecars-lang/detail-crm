import { createContext, use } from 'react';

export type ToastTone = 'success' | 'error' | 'info';

export interface ToastInput {
  title: string;
  description?: string;
  tone?: ToastTone;
  /** ms before auto-dismiss; errors default to 8000, others 5000. 0 = sticky. */
  duration?: number;
  action?: { label: string; onClick: () => void };
}

export interface ToastApi {
  show: (toast: ToastInput) => number;
  success: (title: string, description?: string) => number;
  /** Accepts a message or any thrown value (mapped via lib/errors). */
  error: (titleOrError: unknown, description?: string) => number;
  info: (title: string, description?: string) => number;
  dismiss: (id: number) => void;
}

export const ToastContext = createContext<ToastApi | null>(null);

export function useToast(): ToastApi {
  const ctx = use(ToastContext);
  if (!ctx) throw new Error('useToast must be used inside <ToastProvider>');
  return ctx;
}
