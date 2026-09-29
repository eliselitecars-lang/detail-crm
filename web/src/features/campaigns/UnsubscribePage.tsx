import { CircleAlert, MailCheck, MailPlus, MailX } from 'lucide-react';
import { useEffect, useRef, useState, type ReactNode } from 'react';
import { useParams } from 'react-router';
import { Button, Card, ConfirmDialog, ErrorState, LoadingState } from '@/components/ui';
import { AppError, toAppError } from '@/lib/errors';
import { shopAssetUrl } from '@/lib/supabase';
import { useDocumentTitle } from '@/lib/useDocumentTitle';
import { useEmailChoice, useUnsubscribeInfo, type EmailChoice, type UnsubscribeInfo } from './api';
import {
  emailChoiceErrorMessage,
  isUnsubscribeToken,
  MARKETING_EMAILS_ARE,
  UNSUBSCRIBE_STILL_SENT,
  unsubscribedText,
} from './model';

/**
 * Public /u/:token — the unsubscribe link in every campaign and follow-up
 * email (and where the messaging function's List-Unsubscribe GET redirects).
 * Nothing happens until the visitor presses a button: link scanners and
 * prefetchers open links, and must not change anyone's choices.
 *
 * The visitor's email choices for this shop (0126, api.ts):
 *   * Unsubscribe — marketing only (public_unsubscribe): campaigns and
 *     marketing follow-ups stop; booking confirmations, reminders, quotes,
 *     invoices and receipts keep coming. The page says so before the click.
 *   * Stop all emails (public_unsubscribe_all), after a confirmation that
 *     spells out what else stops — offered once marketing is off.
 *   * Resubscribe (public_resubscribe) — lifts the opt-out whatever its scope
 *     (marketing, or all emails) and turns marketing email back on; offered
 *     only while a current customer of the shop has the address
 *     (can_resubscribe), else the page says to give the shop another address.
 * After every change the page reads its state from the server again, so it
 * only ever shows what the server confirmed. The shop cannot opt an address
 * back in (customers_comms_guard); the customer can, here or in the portal.
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

/** The last change made on this page and the server's answer (true = done). */
interface LastChange {
  choice: EmailChoice;
  done: boolean;
}

function UnsubscribeFlow({ token }: { token: string }) {
  const info = useUnsubscribeInfo(token);
  const [last, setLast] = useState<LastChange | null>(null);

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
  // The token is no longer known to the server (unsubscribe / stop all
  // answered false).
  if (last && !last.done && last.choice !== 'resubscribe') return <InvalidLink focus />;

  const data = info.data;
  return data.unsubscribed ? (
    <UnsubscribedView
      token={token}
      info={data}
      last={last}
      // Unknown scope (an older server): never claim that emails still arrive.
      scope={data.scope ?? 'all'}
      onChange={setLast}
    />
  ) : (
    <SubscribedView token={token} info={data} last={last} onChange={setLast} />
  );
}

/** The address gets this shop's marketing email: offer the marketing-only unsubscribe. */
function SubscribedView({
  token,
  info,
  last,
  onChange,
}: {
  token: string;
  info: UnsubscribeInfo;
  last: LastChange | null;
  onChange: (change: LastChange) => void;
}) {
  const unsubscribe = useEmailChoice(token, 'unsubscribe');
  const logo = shopAssetUrl(info.shop_logo_path);
  const resubscribed = last?.choice === 'resubscribe' && last.done;
  const run = async () => {
    try {
      onChange({ choice: 'unsubscribe', done: await unsubscribe.mutateAsync() });
    } catch {
      // Shown below (unsubscribe.error).
    }
  };

  if (unsubscribe.isError) {
    return (
      <ErrorState
        error={new AppError(emailChoiceErrorMessage(unsubscribe.error))}
        title="We couldn’t unsubscribe you"
        onRetry={() => void run()}
        retrying={unsubscribe.isPending}
        compact
      />
    );
  }

  return (
    <div className="flex flex-col gap-4">
      {resubscribed && (
        <FocusedNotice title="You’re subscribed again">
          {info.shop_name} can send marketing emails to this address again, as well as{' '}
          {UNSUBSCRIBE_STILL_SENT}.
        </FocusedNotice>
      )}
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
          Stop marketing emails from {info.shop_name} — {MARKETING_EMAILS_ARE} — to the address this
          email was sent to.
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
        onClick={() => void run()}
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

/** The address opted out ('marketing' or 'all'): say what that means and offer the other choices. */
function UnsubscribedView({
  token,
  info,
  scope,
  last,
  onChange,
}: {
  token: string;
  info: UnsubscribeInfo;
  scope: 'marketing' | 'all';
  last: LastChange | null;
  onChange: (change: LastChange) => void;
}) {
  const resubscribe = useEmailChoice(token, 'resubscribe');
  const stopAll = useEmailChoice(token, 'unsubscribe_all');
  const [confirming, setConfirming] = useState(false);
  const shop = info.shop_name;
  const refused = last?.choice === 'resubscribe' && !last.done;

  const runResubscribe = async () => {
    try {
      onChange({ choice: 'resubscribe', done: await resubscribe.mutateAsync() });
    } catch {
      // Shown below (resubscribe.error).
    }
  };
  const runStopAll = async () => {
    try {
      const done = await stopAll.mutateAsync();
      setConfirming(false);
      onChange({ choice: 'unsubscribe_all', done });
    } catch {
      // Shown in the dialog (stopAll.error).
    }
  };

  const error = resubscribe.isError ? resubscribe.error : null;

  return (
    <div className="flex flex-col gap-4">
      <Outcome
        // A change made on this page lands here: move focus to its result.
        focus={last !== null}
        focusKey={last}
        icon={<MailCheck aria-hidden="true" />}
        tone="success"
        title={scope === 'all' ? 'You’re unsubscribed from all emails' : 'You’re unsubscribed'}
        body={unsubscribedText(shop, scope, info.can_resubscribe)}
      />
      {refused && (
        <p
          role="alert"
          className="bg-danger-soft text-danger-ink rounded-control px-3 py-2 text-sm"
        >
          We couldn’t resubscribe this address: {shop} no longer has a customer record with it.
        </p>
      )}
      {error !== null && (
        <p
          role="alert"
          className="bg-danger-soft text-danger-ink rounded-control px-3 py-2 text-sm"
        >
          {emailChoiceErrorMessage(error)}
        </p>
      )}
      <div className="flex flex-col gap-2">
        {info.can_resubscribe && (
          <>
            <Button
              fullWidth
              variant="secondary"
              leadingIcon={<MailPlus aria-hidden="true" />}
              loading={resubscribe.isPending}
              disabled={stopAll.isPending}
              onClick={() => void runResubscribe()}
            >
              {scope === 'all'
                ? `Resubscribe to all ${shop} emails`
                : 'Resubscribe to marketing emails'}
            </Button>
            {scope === 'all' && (
              <p className="text-muted text-center text-xs">
                Turns {UNSUBSCRIBE_STILL_SENT} back on, and marketing emails too — you can
                unsubscribe from those again here.
              </p>
            )}
          </>
        )}
        {scope === 'marketing' && (
          <Button
            fullWidth
            variant="secondary"
            leadingIcon={<MailX aria-hidden="true" />}
            disabled={resubscribe.isPending}
            onClick={() => {
              stopAll.reset();
              setConfirming(true);
            }}
          >
            Stop all emails from {shop}
          </Button>
        )}
      </div>
      <ConfirmDialog
        open={confirming}
        onClose={() => setConfirming(false)}
        onConfirm={runStopAll}
        loading={stopAll.isPending}
        tone="danger"
        title={`Stop all emails from ${shop}?`}
        description={`You’ll also stop getting ${UNSUBSCRIBE_STILL_SENT} from ${shop} at this address, not just marketing emails.${
          info.can_resubscribe ? ' You can turn them back on from this page.' : ''
        }`}
        confirmLabel="Stop all emails"
      >
        {stopAll.isError && (
          <p
            role="alert"
            className="bg-danger-soft text-danger-ink rounded-control px-3 py-2 text-sm"
          >
            {emailChoiceErrorMessage(stopAll.error)}
          </p>
        )}
      </ConfirmDialog>
    </div>
  );
}

/** A result that replaced the button the visitor pressed: focus moves to its heading. */
function FocusedNotice({ title, children }: { title: string; children: ReactNode }) {
  const heading = useRef<HTMLHeadingElement>(null);
  useEffect(() => {
    heading.current?.focus();
  }, []);
  return (
    <div role="status" className="bg-success-soft text-success-ink rounded-card px-4 py-3 text-sm">
      <h2 ref={heading} tabIndex={-1} className="font-semibold outline-none">
        {title}
      </h2>
      <p className="mt-1">{children}</p>
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
  focusKey,
}: {
  icon: ReactNode;
  tone: 'success' | 'danger';
  title: string;
  body: string;
  /** Move focus to the result (it replaced the button the visitor pressed). */
  focus?: boolean;
  /** A new value (another change on the page) moves focus to the result again. */
  focusKey?: unknown;
}) {
  const heading = useRef<HTMLHeadingElement>(null);
  useEffect(() => {
    if (focus) heading.current?.focus();
  }, [focus, title, focusKey]);
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
