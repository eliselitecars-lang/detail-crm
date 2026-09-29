import { useToast } from '@/components/ui';
import { errorMessage, isCheckoutOpenError } from '@/lib/errors';
import { cancelOpenPaymentsSummary } from '@/features/invoices/api';
import { useCan } from '@/features/shop/useCan';
import { useReleaseJobPayments } from '../../api';

/**
 * The error toast for a job edit. Lowering a job's price or deposit while
 * one of its card payment pages (deposit / pay link) is still open is
 * refused (0118: 55000 HINT checkout_open, "cancel the open payments first,
 * or wait until then"). For those refusals the toast offers exactly that:
 * payments.cancel_open_payments for the job, after which the change can be
 * saved again. A payment the bank is already processing is never cancelled;
 * the toast then says so. Every other error is a plain error toast.
 */
export function useJobEditError(jobId: string): (error: unknown) => void {
  const toast = useToast();
  const release = useReleaseJobPayments(jobId);
  const canRelease = useCan('jobs.manage');

  const releaseOpenPayments = async () => {
    try {
      const result = await release.mutateAsync();
      if (result.in_progress > 0 || result.succeeded > 0) {
        const summary = cancelOpenPaymentsSummary(result);
        toast.error(summary.title, summary.description);
        return;
      }
      toast.success('Open payment pages closed', 'Save your change again.');
    } catch (error) {
      toast.error(error);
    }
  };

  return (error: unknown) => {
    if (!canRelease || !isCheckoutOpenError(error)) {
      toast.error(error);
      return;
    }
    toast.show({
      tone: 'error',
      title: 'A card payment page for this job is still open',
      description: errorMessage(error),
      action: { label: 'Cancel open payments', onClick: () => void releaseOpenPayments() },
    });
  };
}
