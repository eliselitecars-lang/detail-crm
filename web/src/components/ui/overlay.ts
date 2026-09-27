import { useEffect, useRef, type RefObject } from 'react';

const FOCUSABLE =
  'a[href], area[href], button:not([disabled]), input:not([disabled]):not([type="hidden"]), select:not([disabled]), textarea:not([disabled]), iframe, [tabindex]:not([tabindex="-1"]), [contenteditable="true"]';

export function focusableWithin(root: HTMLElement): HTMLElement[] {
  return Array.from(root.querySelectorAll<HTMLElement>(FOCUSABLE)).filter(
    (el) => !el.hasAttribute('inert') && el.getAttribute('aria-hidden') !== 'true',
  );
}

let scrollLocks = 0;
let savedOverflow = '';

/** Locks body scroll while `active` (ref-counted for nested overlays). */
export function useScrollLock(active: boolean) {
  useEffect(() => {
    if (!active) return;
    if (scrollLocks === 0) {
      savedOverflow = document.body.style.overflow;
      document.body.style.overflow = 'hidden';
    }
    scrollLocks += 1;
    return () => {
      scrollLocks -= 1;
      if (scrollLocks === 0) document.body.style.overflow = savedOverflow;
    };
  }, [active]);
}

/**
 * Modal focus management: moves focus into `container` when active (to
 * `initialFocus`, else the first focusable, else the container), keeps Tab /
 * Shift+Tab inside, and restores focus to the previously focused element.
 */
export function useFocusTrap(
  container: RefObject<HTMLElement | null>,
  active: boolean,
  initialFocus?: RefObject<HTMLElement | null>,
) {
  const initialRef = useRef(initialFocus);
  useEffect(() => {
    initialRef.current = initialFocus;
  });

  useEffect(() => {
    if (!active) return;
    const root = container.current;
    if (!root) return;
    const previouslyFocused =
      document.activeElement instanceof HTMLElement ? document.activeElement : null;

    const target = initialRef.current?.current ?? focusableWithin(root)[0] ?? root;
    target.focus({ preventScroll: true });

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key !== 'Tab') return;
      const items = focusableWithin(root);
      if (items.length === 0) {
        event.preventDefault();
        root.focus();
        return;
      }
      const first = items[0];
      const last = items[items.length - 1];
      const current = document.activeElement;
      if (event.shiftKey && (current === first || current === root)) {
        event.preventDefault();
        last?.focus();
      } else if (!event.shiftKey && current === last) {
        event.preventDefault();
        first?.focus();
      }
    };
    root.addEventListener('keydown', onKeyDown);
    return () => {
      root.removeEventListener('keydown', onKeyDown);
      if (previouslyFocused?.isConnected) previouslyFocused.focus({ preventScroll: true });
    };
  }, [active, container]);
}

/** Calls `handler` on pointerdown outside every given element while active. */
export function useOutsideClick(
  refs: readonly RefObject<HTMLElement | null>[],
  handler: () => void,
  active: boolean,
) {
  const handlerRef = useRef(handler);
  useEffect(() => {
    handlerRef.current = handler;
  });
  useEffect(() => {
    if (!active) return;
    const onPointerDown = (event: PointerEvent) => {
      const target = event.target as Node | null;
      if (target && refs.some((r) => r.current?.contains(target))) return;
      handlerRef.current();
    };
    document.addEventListener('pointerdown', onPointerDown);
    return () => document.removeEventListener('pointerdown', onPointerDown);
    // refs are stable RefObjects
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [active]);
}

const escapeStack: { current: () => void }[] = [];

/**
 * Escape closes the TOP-most open overlay only (nested dialogs, a menu inside
 * a drawer…). Listens on document so it works wherever focus is.
 */
export function useEscapeKey(active: boolean, onEscape: () => void) {
  const handlerRef = useRef(onEscape);
  useEffect(() => {
    handlerRef.current = onEscape;
  });
  useEffect(() => {
    if (!active) return;
    const entry = { current: () => handlerRef.current() };
    escapeStack.push(entry);
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key !== 'Escape' || escapeStack[escapeStack.length - 1] !== entry) return;
      event.preventDefault();
      event.stopPropagation();
      entry.current();
    };
    document.addEventListener('keydown', onKeyDown);
    return () => {
      document.removeEventListener('keydown', onKeyDown);
      const index = escapeStack.indexOf(entry);
      if (index >= 0) escapeStack.splice(index, 1);
    };
  }, [active]);
}
