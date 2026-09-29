import { CircleAlert, MailCheck, MailX } from 'lucide-react';
import { useEffect, useRef, type ReactNode } from 'react';
import { useParams } from 'react-router';
import { Button, Card, ErrorState, LoadingState } from '@/components/ui';
import { toAppError } from '@/lib/errors';
import { shopAssetUrl } from '@/lib/supabase';
import { useDocumentTitle } from '@/lib/useDocumentTitle';
import { useUnsubscribe, useUnsubscribeInfo, type UnsubscribeInfo } from './api';
import { isUnsubscribeToken } from './model';

/**
 * Public /u/:token — the unsubscribe link in every campaign and follow-up
 * email (and where the messaging function's List-Unsubscribe GET redirects).
 * Nothing happens until the visitor presses the button: link scanners and
 * prefetchers open links, and must not unsubscribe anyone. The opt-out stops
 * every email to the address, transactional included, and nobody can clear
 * it (customers_comms_guard), so the page never promises a way back.
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

function Unsubscribed({ shopName, focus }: { shopName: string; focus: boolean }) {
  return (
    <Outcome
      icon={<MailCheck aria-hidden="true" />}
      tone="success"
      title="You’re unsubscribed"
      body={`You won’t get any more emails from ${shopName} at this address — including receipts, invoices and appointment reminders. This can’t be undone for this address; if you want emails from ${shopName} again, give them a different email address.`}
      focus={focus}
    />
  );
}

function UnsubscribeForm({ token, info }: { token: string; info: UnsubscribeInfo }) {
  const unsubscribe = useUnsubscribe();
  const logo = shopAssetUrl(info.shop_logo_path);

  if (unsubscribe.isSuccess) {
    return unsubscribe.data ? (
      <Unsubscribed shopName={info.shop_name} focus />
    ) : (
      <InvalidLink focus />
    );
  }
  // Already opted out (an earlier visit, or a reply of STOP / a complaint).
  if (info.unsubscribed) return <Unsubscribed shopName={info.shop_name} focus={false} />;

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
          Unsubscribe from {info.shop_name} emails
        </h1>
        <p className="text-muted mt-1 text-sm">
          Stop receiving emails from {info.shop_name} at the address this email was sent to.
        </p>
        {/* 0033: an email opt-out blocks every email to the address, and no
            one — the shop included — can clear it, so say so before the click. */}
        <p className="text-muted mt-2 text-sm">
          This stops all of their emails, including receipts, invoices and appointment reminders,
          and can’t be undone for this address.
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
