import { useEffect } from 'react';
import { useNavigate } from 'react-router';
import { useToast } from '@/components/ui';
import { isSubscriptionError } from '@/lib/errors';
import { BILLING_PATH, GO_TO_BILLING } from './model';

/**
 * App shell: every `toast.error(error)` of a subscription refusal (PT402 /
 * HTTP 402) gets a "Go to Billing" action for the shop owner; everyone else
 * sees the server's message only.
 */
export function useBillingErrorToasts(role: string) {
  const toast = useToast();
  const navigate = useNavigate();
  useEffect(() => {
    if (role !== 'owner') return undefined;
    return toast.setErrorAction((error) =>
      isSubscriptionError(error)
        ? { label: GO_TO_BILLING, onClick: () => void navigate(BILLING_PATH) }
        : undefined,
    );
  }, [toast, navigate, role]);
}
