import { useQueryClient } from '@tanstack/react-query';
import { useEffect, useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router';
import { Banner } from '@/features/public-docs/shared/PublicPage';
import { portalKeys } from './api';
import {
  MEMBERSHIP_REFRESH_MS,
  RETURN_PARAMS,
  returnNotice,
  type ReturnNotice,
} from './returnNotice';

/**
 * Banners for coming back from Stripe Checkout (card-saving and membership
 * links return to /portal?card=… / ?membership=…). The values are read once;
 * the two parameters are then removed from the URL (replace) so a refresh
 * does not repeat the banner. After a membership sign-up the overview is
 * re-read once, a few seconds later, when the webhook has usually run.
 */
export function ReturnBanners({ userId, shopName }: { userId: string; shopName: string | null }) {
  const [params] = useSearchParams();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const [initial] = useState(() => ({
    card: params.get('card'),
    membership: params.get('membership'),
  }));

  useEffect(() => {
    if (!RETURN_PARAMS.some((name) => params.has(name))) return;
    const next = new URLSearchParams(params);
    for (const name of RETURN_PARAMS) next.delete(name);
    const search = next.toString();
    void navigate({ search: search ? `?${search}` : '' }, { replace: true });
  }, [params, navigate]);

  useEffect(() => {
    if (initial.membership !== 'active' || userId === '') return;
    const timer = setTimeout(() => {
      void queryClient.invalidateQueries({ queryKey: portalKeys.overview(userId) });
      void queryClient.invalidateQueries({ queryKey: portalKeys.memberships(userId) });
    }, MEMBERSHIP_REFRESH_MS);
    return () => clearTimeout(timer);
  }, [initial.membership, userId, queryClient]);

  const notices = [
    returnNotice('card', initial.card, shopName),
    returnNotice('membership', initial.membership, shopName),
  ].filter((notice): notice is ReturnNotice => notice !== null);
  if (notices.length === 0) return null;
  return (
    <>
      {notices.map((notice) => (
        <Banner key={notice.title} tone={notice.tone} title={notice.title} />
      ))}
    </>
  );
}
