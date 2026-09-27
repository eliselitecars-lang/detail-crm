import type { ToastApi } from '@/components/ui';
import type { InviteResult } from './edge';

/** Feedback after send/resend: the email may fail while the invite still exists. */
export function announceInvite(toast: ToastApi, result: InviteResult, resent: boolean): void {
  if (result.email_sent) {
    toast.success(
      resent ? (result.reissued ? 'New invite sent' : 'Invite re-sent') : 'Invite sent',
      `We emailed ${result.invite.email} a link to join.`,
    );
    return;
  }
  toast.show({
    tone: 'error',
    title: 'The invite was created, but the email didn’t go out',
    description: 'Copy the link and share it yourself, or try resending later.',
    duration: 0,
    action: {
      label: 'Copy link',
      onClick: () => void navigator.clipboard?.writeText(result.invite_url),
    },
  });
}
