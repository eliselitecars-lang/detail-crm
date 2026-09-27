import {
  CalendarClock,
  CalendarPlus,
  Car,
  ChevronRight,
  FileText,
  History,
  LogOut,
  Receipt,
  Repeat,
  Store,
} from 'lucide-react';
import type { ReactNode } from 'react';
import { Link } from 'react-router';
import { PublicLayout, type PublicShopBranding } from '@/components/layout/PublicLayout';
import {
  Badge,
  Button,
  Card,
  EmptyState,
  ErrorState,
  LoadingState,
  SectionCard,
  StatusBadge,
  buttonClasses,
} from '@/components/ui';
import { formatDate, formatInTz, formatLocalDate, formatTimeRange } from '@/lib/dates';
import { errorMessage, toAppError } from '@/lib/errors';
import { formatBps, formatCents } from '@/lib/money';
import { formatPhone } from '@/lib/phone';
import { useAuth } from '@/features/auth/authContext';
import { Banner } from '@/features/public-docs/shared/PublicPage';
import { toBranding } from '@/features/public-docs/shared/schemas';
import {
  usePortalClaim,
  usePortalOverview,
  type PortalJob,
  type PortalOverview,
  type PortalShop,
} from './api';
import { ReturnBanners } from './ReturnBanners';

const PORTAL_BRANDING: PublicShopBranding = { name: 'My appointments' };

export default function PortalPage() {
  const { user, signOut } = useAuth();
  const userId = user?.id ?? '';
  const email = user?.email ?? '';
  const claim = usePortalClaim(userId);
  const overview = usePortalOverview(userId, userId !== '' && !claim.isPending);

  const shops = overview.data?.shops ?? [];
  const branding = shops.length === 1 && shops[0] ? toBranding(shops[0]) : PORTAL_BRANDING;
  const claimRefused = claim.isError && toAppError(claim.error).kind === 'permission';

  return (
    <PublicLayout shop={branding}>
      <div className="flex flex-col gap-4 sm:gap-5">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="min-w-0">
            <h1 className="text-ink text-xl font-semibold sm:text-2xl">My account</h1>
            {email && <p className="text-muted mt-1 text-sm break-all">Signed in as {email}</p>}
          </div>
          <Button
            variant="secondary"
            leadingIcon={<LogOut className="size-4" aria-hidden="true" />}
            onClick={() => void signOut()}
          >
            Sign out
          </Button>
        </div>

        <ReturnBanners
          userId={userId}
          shopName={shops.length === 1 ? (shops[0]?.name ?? null) : null}
        />

        {claim.isError && (
          <Banner
            tone="warning"
            title={
              claimRefused
                ? 'Confirm your email to see your bookings'
                : 'We couldn’t link your bookings just now'
            }
            {...(!claimRefused
              ? {
                  action: (
                    <Button size="sm" variant="secondary" onClick={() => void claim.refetch()}>
                      Try again
                    </Button>
                  ),
                }
              : {})}
          >
            {claimRefused
              ? 'Open the confirmation link we emailed you, then come back to this page.'
              : errorMessage(claim.error)}
          </Banner>
        )}

        {claim.isPending || overview.isPending ? (
          <Card>
            <LoadingState label="Loading your appointments…" />
          </Card>
        ) : overview.isError ? (
          <Card>
            <ErrorState
              error={overview.error}
              title="Couldn’t load your account"
              onRetry={() => void overview.refetch()}
              retrying={overview.isFetching}
            />
          </Card>
        ) : overview.data.shops.length === 0 ? (
          <Card>
            <EmptyState
              icon={<CalendarClock aria-hidden="true" />}
              title="No bookings linked yet"
              description={
                <>
                  Appointments, quotes and invoices appear here automatically when a shop has them
                  under the same email as this account{email ? ` (${email})` : ''}. Make sure your
                  email is confirmed, and use this email when you book.
                </>
              }
            />
          </Card>
        ) : (
          <PortalSections data={overview.data} />
        )}

        <footer className="text-muted border-line flex flex-wrap items-center justify-between gap-2 border-t pt-4 text-sm">
          <span>Signed in to manage your appointments.</span>
          <Link
            to="/account"
            state={{ from: '/portal' }}
            className="text-primary-ink hover:underline"
          >
            Account settings
          </Link>
        </footer>
      </div>
    </PublicLayout>
  );
}

function PortalSections({ data }: { data: PortalOverview }) {
  const shopsBySlug = new Map(data.shops.map((s) => [s.slug, s]));
  const multiShop = data.shops.length > 1;
  const shopOf = (slug: string) => shopsBySlug.get(slug);
  const openInvoices = data.invoices.filter((i) => i.balance_cents > 0);
  const otherInvoices = data.invoices.filter((i) => i.balance_cents <= 0);

  return (
    <>
      <SectionCard title="Upcoming appointments" flush>
        {data.upcoming_jobs.length === 0 ? (
          <EmptyState
            compact
            icon={<CalendarClock aria-hidden="true" />}
            title="No upcoming appointments"
            {...(data.shops.some((s) => s.booking_enabled)
              ? { description: 'Book your next visit from one of your shops below.' }
              : {})}
          />
        ) : (
          <RowList label="Upcoming appointments">
            {data.upcoming_jobs.map((job) => (
              <JobRow key={job.token} job={job} shop={shopOf(job.shop_slug)} showShop={multiShop} />
            ))}
          </RowList>
        )}
      </SectionCard>

      {data.invoices.length > 0 && (
        <SectionCard title="Invoices" flush>
          <RowList label="Invoices">
            {[...openInvoices, ...otherInvoices].map((invoice) => {
              const shop = shopOf(invoice.shop_slug);
              const currency = shop?.currency ?? 'usd';
              return (
                <LinkRow
                  key={invoice.token}
                  to={`/i/${invoice.token}`}
                  icon={<Receipt aria-hidden="true" />}
                  title={`Invoice #${invoice.number}`}
                  badge={<StatusBadge kind="invoice" status={invoice.status} />}
                  meta={[
                    multiShop ? shop?.name : null,
                    invoice.issued_at && shop
                      ? `Issued ${formatDate(invoice.issued_at, shop.timezone)}`
                      : null,
                    invoice.balance_cents > 0 && invoice.due_at && shop
                      ? `Due ${formatDate(invoice.due_at, shop.timezone)}`
                      : null,
                  ]}
                  amount={
                    invoice.balance_cents > 0 ? (
                      <span className="text-money-ink">
                        {formatCents(invoice.balance_cents, { currency })} due
                      </span>
                    ) : (
                      formatCents(invoice.total_cents, { currency })
                    )
                  }
                />
              );
            })}
          </RowList>
        </SectionCard>
      )}

      {data.quotes.length > 0 && (
        <SectionCard title="Quotes" flush>
          <RowList label="Quotes">
            {data.quotes.map((quote) => {
              const shop = shopOf(quote.shop_slug);
              return (
                <LinkRow
                  key={quote.token}
                  to={`/q/${quote.token}`}
                  icon={<FileText aria-hidden="true" />}
                  title={`Quote #${quote.number}`}
                  badge={<StatusBadge kind="quote" status={quote.status} />}
                  meta={[
                    multiShop ? shop?.name : null,
                    quote.vehicle,
                    quote.valid_until ? `Valid until ${formatLocalDate(quote.valid_until)}` : null,
                  ]}
                  amount={formatCents(quote.total_cents, { currency: shop?.currency ?? 'usd' })}
                />
              );
            })}
          </RowList>
        </SectionCard>
      )}

      {data.memberships.length > 0 && (
        <SectionCard title="Memberships" flush>
          <RowList label="Memberships">
            {data.memberships.map((m, i) => {
              const shop = shopOf(m.shop_slug);
              const currency = shop?.currency ?? 'usd';
              const every =
                m.interval_count === 1 ? m.interval : `${m.interval_count} ${m.interval}s`;
              return (
                <li
                  key={`${m.shop_slug}-${m.plan_name}-${i}`}
                  className="flex items-start gap-3 py-3"
                >
                  <RowIcon>
                    <Repeat aria-hidden="true" />
                  </RowIcon>
                  <div className="min-w-0 flex-1">
                    <div className="flex flex-wrap items-center gap-2">
                      <p className="text-ink text-sm font-semibold">{m.plan_name}</p>
                      <StatusBadge kind="membership" status={m.status} />
                      {m.cancel_at_period_end && <Badge tone="warning">Ends this period</Badge>}
                    </div>
                    <p className="text-muted text-xs">
                      {[
                        multiShop ? shop?.name : null,
                        m.vehicle,
                        m.included_services.length > 0
                          ? `Includes ${m.included_services.join(', ')}`
                          : null,
                        m.discount_bps ? `${formatBps(m.discount_bps)} off other services` : null,
                        m.current_period_end && shop
                          ? `${m.cancel_at_period_end ? 'Ends' : 'Renews'} ${formatDate(m.current_period_end, shop.timezone)}`
                          : null,
                      ]
                        .filter(Boolean)
                        .join(' · ')}
                    </p>
                  </div>
                  <p className="text-ink shrink-0 text-sm font-medium tabular-nums">
                    {formatCents(m.price_cents, { currency })}
                    <span className="text-muted text-xs font-normal"> / {every}</span>
                  </p>
                </li>
              );
            })}
          </RowList>
        </SectionCard>
      )}

      {data.past_jobs.length > 0 && (
        <SectionCard title="Past appointments" flush>
          <RowList label="Past appointments">
            {data.past_jobs.map((job) => (
              <JobRow
                key={job.token}
                job={job}
                shop={shopOf(job.shop_slug)}
                showShop={multiShop}
                past
              />
            ))}
          </RowList>
        </SectionCard>
      )}

      {data.vehicles.length > 0 && (
        <SectionCard title="Vehicles" flush>
          <RowList label="Vehicles">
            {data.vehicles.map((v) => (
              <li key={v.id} className="flex items-start gap-3 py-3">
                <RowIcon>
                  <Car aria-hidden="true" />
                </RowIcon>
                <div className="min-w-0 flex-1">
                  <p className="text-ink text-sm font-semibold">
                    {[v.year, v.make, v.model, v.trim].filter(Boolean).join(' ') || 'Vehicle'}
                  </p>
                  <p className="text-muted text-xs">
                    {[
                      v.color,
                      v.license_plate,
                      v.category_name,
                      multiShop ? shopOf(v.shop_slug)?.name : null,
                    ]
                      .filter(Boolean)
                      .join(' · ')}
                  </p>
                </div>
              </li>
            ))}
          </RowList>
        </SectionCard>
      )}

      <SectionCard title={multiShop ? 'Your shops' : 'Your shop'} flush>
        <RowList label="Your shops">
          {data.shops.map((shop) => (
            <ShopRow key={shop.slug} shop={shop} />
          ))}
        </RowList>
      </SectionCard>
    </>
  );
}

function RowList({ label, children }: { label: string; children: ReactNode }) {
  return (
    <ul aria-label={label} className="divide-line divide-y px-4 sm:px-5">
      {children}
    </ul>
  );
}

function RowIcon({ children }: { children: ReactNode }) {
  return (
    <span className="bg-surface-2 text-muted flex size-9 shrink-0 items-center justify-center rounded-full [&_svg]:size-4">
      {children}
    </span>
  );
}

function LinkRow({
  to,
  icon,
  title,
  badge,
  meta,
  amount,
}: {
  to: string;
  icon: ReactNode;
  title: string;
  badge?: ReactNode;
  meta: (string | null | undefined)[];
  amount?: ReactNode;
}) {
  const metaText = meta.filter(Boolean).join(' · ');
  return (
    <li>
      <Link
        to={to}
        className="hover:bg-surface-2 focus-visible:outline-primary -mx-2 flex items-start gap-3 rounded-lg px-2 py-3 focus-visible:outline-2"
      >
        <RowIcon>{icon}</RowIcon>
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <span className="text-ink text-sm font-semibold">{title}</span>
            {badge}
          </div>
          {metaText && <p className="text-muted text-xs break-words">{metaText}</p>}
        </div>
        {amount !== undefined && (
          <span className="text-ink shrink-0 text-sm font-medium tabular-nums">{amount}</span>
        )}
        <ChevronRight className="text-subtle mt-0.5 size-4 shrink-0" aria-hidden="true" />
      </Link>
    </li>
  );
}

function JobRow({
  job,
  shop,
  showShop,
  past = false,
}: {
  job: PortalJob;
  shop: PortalShop | undefined;
  showShop: boolean;
  past?: boolean;
}) {
  const tz = shop?.timezone ?? 'UTC';
  const when = job.scheduled_start
    ? `${formatInTz(job.scheduled_start, tz, 'EEE, MMM d, yyyy')}${
        job.scheduled_end ? ` · ${formatTimeRange(job.scheduled_start, job.scheduled_end, tz)}` : ''
      }`
    : 'Time to be confirmed';
  return (
    <LinkRow
      to={`/booking/${job.token}`}
      icon={past ? <History aria-hidden="true" /> : <CalendarClock aria-hidden="true" />}
      title={when}
      badge={<StatusBadge kind="job" status={job.status} />}
      meta={[showShop ? shop?.name : null, job.services, job.vehicle, `#${job.number}`]}
      amount={formatCents(job.total_cents, { currency: shop?.currency ?? 'usd' })}
    />
  );
}

function ShopRow({ shop }: { shop: PortalShop }) {
  return (
    <li className="flex flex-wrap items-center gap-3 py-3">
      <RowIcon>
        <Store aria-hidden="true" />
      </RowIcon>
      <div className="min-w-0 flex-1">
        <p className="text-ink text-sm font-semibold">{shop.name}</p>
        <p className="text-muted text-xs">
          {[
            [shop.city, shop.region].filter(Boolean).join(', '),
            shop.phone ? formatPhone(shop.phone) : null,
          ]
            .filter(Boolean)
            .join(' · ')}
        </p>
      </div>
      <div className="flex gap-2">
        {shop.phone && (
          <a href={`tel:${shop.phone}`} className={buttonClasses({ variant: 'ghost', size: 'sm' })}>
            Call<span className="sr-only"> {shop.name}</span>
          </a>
        )}
        {shop.booking_enabled && (
          <Link
            to={`/book/${shop.slug}`}
            className={buttonClasses({ variant: 'secondary', size: 'sm' })}
          >
            <CalendarPlus className="size-4" aria-hidden="true" />
            Book<span className="sr-only"> with {shop.name}</span>
          </Link>
        )}
      </div>
    </li>
  );
}
