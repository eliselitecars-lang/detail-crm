import { Tags } from 'lucide-react';
import { useEffect } from 'react';
import { Link } from 'react-router';
import { Logo } from '@/components/layout/Logo';
import { PublicLayout } from '@/components/layout/PublicLayout';
import { Card, EmptyState, ErrorState, LoadingState } from '@/components/ui';
import { useBillingPlans } from './api';
import { PlanCard } from './components/PlanCard';

const ctaClass =
  'rounded-control bg-primary text-primary-fg hover:bg-primary-hover focus-visible:outline-primary inline-flex h-10 items-center justify-center px-4 text-sm font-medium focus-visible:outline-2 focus-visible:outline-offset-2';

/**
 * Public /pricing — the platform's plans (not a shop's), from
 * public_billing_plans() (anon; [] while billing is off). No plan, price or
 * trial is written here: without plans the page says pricing is coming soon.
 */
export default function PricingPage() {
  const plans = useBillingPlans();
  useEffect(() => {
    document.title = 'Pricing · Detail CRM';
  }, []);

  return (
    <PublicLayout
      shop={null}
      width="wide"
      brand={
        <Link to="/" className="rounded-control flex w-fit" aria-label="Detail CRM home">
          <Logo />
        </Link>
      }
    >
      <div className="flex min-w-0 flex-col gap-6">
        <header className="flex flex-col gap-2">
          <h1 className="text-ink text-2xl font-semibold tracking-tight">Pricing</h1>
          <p className="text-muted text-sm sm:text-base">
            Detail CRM runs online booking, scheduling, quotes, invoices, payments and messages for
            detailing, coating, tint and PPF shops. Each shop has its own subscription.
          </p>
        </header>

        {plans.isPending ? (
          <Card>
            <LoadingState label="Loading plans…" />
          </Card>
        ) : plans.isError ? (
          <Card>
            <ErrorState
              title="Couldn’t load the plans"
              error={plans.error}
              onRetry={() => void plans.refetch()}
              retrying={plans.isRefetching}
            />
          </Card>
        ) : plans.data.length === 0 ? (
          <Card>
            <EmptyState
              icon={<Tags aria-hidden="true" />}
              title="Pricing coming soon"
              description="Plans aren’t published yet. You can create your shop and start using it now."
              action={
                <Link to="/signup" className={ctaClass}>
                  Create your shop
                </Link>
              }
            />
          </Card>
        ) : (
          <>
            <ul aria-label="Plans" className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
              {plans.data.map((plan) => (
                <li key={plan.id}>
                  <PlanCard plan={plan} />
                </li>
              ))}
            </ul>
            <p className="text-muted text-sm">
              Any taxes that apply are shown at checkout. The shop owner chooses a plan in Settings
              → Billing after creating the shop, and can change or cancel it there at any time.
            </p>
            <div className="flex flex-wrap items-center gap-x-4 gap-y-2">
              <Link to="/signup" className={ctaClass}>
                Create your shop
              </Link>
              <Link to="/login" className="text-primary-ink text-sm font-medium hover:underline">
                Sign in
              </Link>
            </div>
          </>
        )}
      </div>
    </PublicLayout>
  );
}
