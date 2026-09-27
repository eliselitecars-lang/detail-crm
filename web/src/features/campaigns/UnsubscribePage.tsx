import { CircleAlert, MailCheck, MailX } from 'lucide-react';
import { useEffect, useRef, type ReactNode } from 'react';
import { useParams } from 'react-router';
import { Button, Card, ErrorState } from '@/components/ui';
import { useUnsubscribe } from './api';
import { isUnsubscribeToken } from './model';

/**
 * Public /u/:token — the unsubscribe link in every campaign email (and where
 * the messaging function's List-Unsubscribe GET redirects). Nothing happens
 * until the visitor presses the button: link scanners and prefetchers open
 * links, and must not unsubscribe anyone.
 */
export default function UnsubscribePage() {
  const { token } = useParams();
  useEffect(() => {
    document.title = 'Unsubscribe';
  }, []);
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
  const unsubscribe = useUnsubscribe();

  if (unsubscribe.isSuccess) {
    return unsubscribe.data ? (
      <Outcome
        icon={<MailCheck aria-hidden="true" />}
        tone="success"
        title="You’re unsubscribed"
        body="You won’t get any more emails from this business at this address. If you change your mind, contact the business and ask to be added back."
        focus
      />
    ) : (
      <InvalidLink focus />
    );
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
      <div>
        <h1 className="text-ink text-lg font-semibold tracking-tight">Unsubscribe from emails</h1>
        <p className="text-muted mt-1 text-sm">
          Stop receiving emails from this business at the address this email was sent to.
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
