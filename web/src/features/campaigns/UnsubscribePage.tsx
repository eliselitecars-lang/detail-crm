import { CircleAlert, MailCheck, MailX } from 'lucide-react';
import { useEffect, useRef, type ReactNode } from 'react';
import { useParams } from 'react-router';
import { Button, Card, ErrorState, LoadingState } from '@/components/ui';
import { toAppError } from '@/lib/errors';
import { shopAssetUrl } from '@/lib/supabase';
import { useDocumentTitle } from '@/lib/useDocumentTitle';
import { useUnsubscribe, useUnsubscribeInfo, type UnsubscribeInfo } from './api';
import { isUnsubscribeToken, UNSUBSCRIBE_STILL_SENT, unsubscribedText } from './model';

/**
 * Public /u/:token — the unsubscribe link in every campaign and follow-up
 * email (and where the messaging function's List-Unsubscribe GET redirects).
 * Nothing happens until the visitor presses the button: link scanners and
 * prefetchers open links, and must not unsubscribe anyone.
 *
 * Since 0126 the button is a marketing-only opt-out (public_unsubscribe,
 * scope 'marketing'): campaigns and marketing follow-ups stop; booking
 * confirmations, reminders, quotes, invoices and receipts keep coming, and
 * the page says so before and after the click. An address already opted out
 * of every email (scope 'all': an unsubscribe from before 0126, or an
 * opt-out the shop recorded) is told exactly that. The shop cannot opt an
 * address back in (customers_comms_guard), and this page offers no way back
 * (the database's public_resubscribe / public_unsubscribe_all have no UI
 * yet), so it promises none.
 */
export default function UnsubscribePage() {
  const { token } = useParams();
  useDocumentTitle('Unsubscribe');
  return (
    <div className="bg-canvas flex min-h-dvh flex-col items-center justify-center px-4 py-10">
      <main className="w-full max-w-md">
        <Card padded className="shadow-pop">
          {isUnsubscribeToken(token) ? <UnsubscribeFlow token={token} /> : <InvalidLink />}
        </Card>
      </main>
    </div>
  );
}

function UnsubscribeFlow({ token }: { token: string }) {
  const info = useUnsubscribeInfo(token);

  if (info.isPending) return <LoadingState label="Checking your link…" />;
  if (info.isError) {
    return toAppError(info.error).kind === 'not_found' ? (
      <InvalidLink />
    ) : (
      <ErrorState
        error={info.error}
        title="We couldn’t open this link"
        onRetry={() => void info.refetch()}
        retrying={info.isFetching}
        compact
      />
    );
  }
  return <UnsubscribeForm token={token} info={info.data} />;
}

function Unsubscribed({
  shopName,
  scope,
  focus,
}: {
  shopName: string;
  scope: UnsubscribeInfo['scope'];
  focus: boolean;
}) {
  return (
    <Outcome
      icon={<MailCheck aria-hidden="true" />}
      tone="success"
      title="You’re unsubscribed"
      body={unsubscribedText(shopName, scope)}
      focus={focus}
    />
  );
}

function UnsubscribeForm({ token, info }: { token: string; info: UnsubscribeInfo }) {
  const unsubscribe = useUnsubscribe();
  const logo = shopAssetUrl(info.shop_logo_path);

  if (unsubscribe.isSuccess) {
    return unsubscribe.data ? (
      <Unsubscribed shopName={info.shop_name} scope={info.scope ?? 'marketing'} focus />
    ) : (
      <InvalidLink focus />
    );
  }
  // Already opted out: an earlier visit ('marketing'), or an opt-out of every
  // email ('all': before 0126, or recorded by the shop). Unknown scope: 'all'
  // (never claim that emails still arrive when they may not).
  if (info.unsubscribed) {
    return <Unsubscribed shopName={info.shop_name} scope={info.scope ?? 'all'} focus={false} />;
  }

  if (unsubscribe.isError) {
    return (
      <ErrorState
        error={unsubscribe.error}
        title="We couldn’t unsubscribe you"
        onRetry={() => unsubscribe.mutate(token)}
        retrying={unsubscribe.isPending}
        compact
      />
    );
  }

  return (
    <div className="flex flex-col gap-4">
      {logo && (
        <img
          src={logo}
          alt={`${info.shop_name} logo`}
          className="h-12 w-auto max-w-[12rem] self-start object-contain"
        />
      )}
      <div>
        <h1 className="text-ink text-lg font-semibold tracking-tight">
          Unsubscribe from {info.shop_name} marketing emails
        </h1>
        <p className="text-muted mt-1 text-sm">
          Stop marketing emails from {info.shop_name} — campaigns, promotions and service follow-ups
          — to the address this email was sent to.
        </p>
        {/* 0126: the link is a marketing-only opt-out; say what still arrives
            before the click. */}
        <p className="text-muted mt-2 text-sm">
          You’ll still get {UNSUBSCRIBE_STILL_SENT} from {info.shop_name}.
        </p>
      </div>
      <Button
        fullWidth
        leadingIcon={<MailX aria-hidden="true" />}
        loading={unsubscribe.isPending}
        onClick={() => unsubscribe.mutate(token)}
      >
        Unsubscribe
      </Button>
      {unsubscribe.isPending && (
        <p role="status" className="sr-only">
          Unsubscribing…
        </p>
      )}
    </div>
  );
}

function InvalidLink({ focus = false }: { focus?: boolean }) {
  return (
    <Outcome
      focus={focus}
      icon={<CircleAlert aria-hidden="true" />}
      tone="danger"
      title="This unsubscribe link isn’t valid"
      body="Open the unsubscribe link from the email again, making sure the whole link was copied. You can also reply to the email and ask the business to stop emailing you."
    />
  );
}

function Outcome({
  icon,
  tone,
  title,
  body,
  focus = false,
}: {
  icon: ReactNode;
  tone: 'success' | 'danger';
  title: string;
  body: string;
  /** Move focus to the result (it replaced the button the visitor pressed). */
  focus?: boolean;
}) {
  const heading = useRef<HTMLHeadingElement>(null);
  useEffect(() => {
    if (focus) heading.current?.focus();
  }, [focus]);
  return (
    <div role="status" className="flex flex-col items-center gap-3 py-4 text-center">
      <div
        className={
          tone === 'success'
            ? 'bg-success-soft text-success flex size-11 items-center justify-center rounded-full [&_svg]:size-5'
            : 'bg-danger-soft text-danger flex size-11 items-center justify-center rounded-full [&_svg]:size-5'
        }
      >
        {icon}
      </div>
      <h1
        ref={heading}
        tabIndex={-1}
        className="text-ink text-lg font-semibold tracking-tight outline-none"
      >
        {title}
      </h1>
      <p className="text-muted max-w-sm text-sm">{body}</p>
    </div>
  );
}
