import { Settings2 } from 'lucide-react';
import { Logo } from '@/components/layout/Logo';
import { Card } from '@/components/ui';
import { missingEnvVars } from '@/lib/env';

/** Shown instead of the app when the public Supabase env vars are missing. */
export function SetupScreen() {
  const missing = missingEnvVars();
  return (
    <div className="bg-canvas flex min-h-dvh items-center justify-center px-4 py-10">
      <main className="w-full max-w-lg">
        <div className="mb-6 flex justify-center">
          <Logo />
        </div>
        <Card padded className="shadow-pop">
          <div className="flex items-start gap-3">
            <span className="bg-primary-soft text-primary flex size-10 shrink-0 items-center justify-center rounded-full">
              <Settings2 className="size-5" aria-hidden="true" />
            </span>
            <div>
              <h1 className="text-ink text-lg font-semibold">Finish setting up Detail CRM</h1>
              <p className="text-muted mt-1 text-sm">
                This app needs your Supabase project’s public URL and anon key before it can start.
              </p>
            </div>
          </div>
          <div className="text-ink mt-5 flex flex-col gap-4 text-sm">
            <div>
              <p className="font-medium">Missing or invalid</p>
              <ul className="mt-1.5 flex flex-wrap gap-2">
                {missing.map((name) => (
                  <li key={name}>
                    <code className="bg-surface-2 rounded px-1.5 py-0.5 text-xs">{name}</code>
                  </li>
                ))}
              </ul>
            </div>
            <ol className="text-muted list-decimal space-y-1.5 pl-5">
              <li>
                Copy <code className="text-ink">web/.env.example</code> to{' '}
                <code className="text-ink">web/.env.local</code>.
              </li>
              <li>
                Fill in the values from Supabase → Project Settings → API (the <em>anon</em> public
                key only).
              </li>
              <li>Restart the dev server, or rebuild for production.</li>
            </ol>
          </div>
        </Card>
      </main>
    </div>
  );
}
