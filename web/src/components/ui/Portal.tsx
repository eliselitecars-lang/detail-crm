import type { ReactNode } from 'react';
import { createPortal } from 'react-dom';

/** Renders children into document.body (overlays escape overflow/stacking). */
export function Portal({ children }: { children: ReactNode }) {
  if (typeof document === 'undefined') return null;
  return createPortal(children, document.body);
}
