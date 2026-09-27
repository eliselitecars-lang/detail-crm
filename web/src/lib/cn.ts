import { clsx, type ClassValue } from 'clsx';
import { extendTailwindMerge } from 'tailwind-merge';

/**
 * tailwind-merge that knows this app's design tokens (src/index.css
 * `@theme inline`): `rounded-card` / `rounded-control` are border radii.
 * Colours (`bg-surface`, `text-ink`…) and shadows (`shadow-card`,
 * `shadow-pop`) are already recognised by the default config.
 */
const twMerge = extendTailwindMerge({
  extend: { theme: { radius: ['card', 'control'] } },
});

/**
 * Joins class names (clsx) and resolves Tailwind conflicts so the LAST class
 * wins: `cn('px-2 bg-surface', className)` lets `className="px-4 bg-primary"`
 * override the defaults instead of both applying.
 */
export function cn(...inputs: ClassValue[]): string {
  return twMerge(clsx(inputs));
}
