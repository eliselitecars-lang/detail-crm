import { z } from 'zod';

// zod 4 probes `new Function` the first time a schema is built to decide
// whether to JIT-compile parsers. The production CSP forbids eval, so the
// probe raises a CSP violation on every page load. jitless skips the probe.
// This module must be the first import of main.tsx: schemas are built while
// the other modules are imported, before main.tsx's own body runs.
z.config({ jitless: true });
