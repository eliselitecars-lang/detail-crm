import type { ComponentType } from 'react';

/**
 * Route-level code splitting. Use in feature routes:
 *   { path: 'jobs', lazy: lazyPage(() => import('./JobsPage')) }
 * The page module must `export default` its component.
 */
export function lazyPage(
  loader: () => Promise<{ default: ComponentType }>,
): () => Promise<{ Component: ComponentType }> {
  return async () => {
    const module = await loader();
    return { Component: module.default };
  };
}
