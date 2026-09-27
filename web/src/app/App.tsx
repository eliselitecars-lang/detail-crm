import { QueryClientProvider } from '@tanstack/react-query';
import { lazy, Suspense, useState } from 'react';
import { RouterProvider } from 'react-router';
import { ToastProvider } from '@/components/ui';
import { AuthProvider } from '@/features/auth/AuthProvider';
import { isSupabaseConfigured, supabase } from '@/lib/supabase';
import { createQueryClient } from './queryClient';
import { createAppRouter } from './router';
import { SetupScreen } from './SetupScreen';
import { ThemeProvider } from './ThemeProvider';

const ReactQueryDevtools = import.meta.env.DEV
  ? lazy(() =>
      import('@tanstack/react-query-devtools').then((m) => ({ default: m.ReactQueryDevtools })),
    )
  : null;

function ConfiguredApp() {
  const [queryClient] = useState(() =>
    createQueryClient({
      // A rejected JWT means the stored session is dead: drop it locally so
      // RequireAuth sends the user to sign in again.
      onSessionExpired: () => void supabase.auth.signOut({ scope: 'local' }),
    }),
  );
  const [router] = useState(createAppRouter);
  return (
    <QueryClientProvider client={queryClient}>
      <ToastProvider>
        <AuthProvider>
          <RouterProvider router={router} />
        </AuthProvider>
      </ToastProvider>
      {ReactQueryDevtools && (
        <Suspense fallback={null}>
          <ReactQueryDevtools buttonPosition="bottom-left" />
        </Suspense>
      )}
    </QueryClientProvider>
  );
}

export function App() {
  return (
    <ThemeProvider>{isSupabaseConfigured ? <ConfiguredApp /> : <SetupScreen />}</ThemeProvider>
  );
}
