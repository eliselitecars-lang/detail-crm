import { Check } from 'lucide-react';
import type { ReactNode } from 'react';
import { Badge } from '@/components/ui';
import {
  featureLabel,
  formatPlanAmount,
  planIntervalLabel,
  planMembersLabel,
  type BillingPlan,
} from '../model';

/** One plan: name, price and interval, team size and feature keys — all from the server. */
export function PlanCard({
  plan,
  current = false,
  action,
}: {
  plan: BillingPlan;
  current?: boolean;
  action?: ReactNode;
}) {
  return (
    <article
      aria-label={plan.name}
      className="rounded-card border-line bg-surface flex h-full min-w-0 flex-col gap-3 border p-4"
    >
      <div className="flex flex-wrap items-start justify-between gap-2">
        <h3 className="text-ink min-w-0 text-base font-semibold break-words">{plan.name}</h3>
        {current && <Badge tone="info">Current plan</Badge>}
      </div>
      <p className="text-ink">
        <span className="tabular text-2xl font-semibold tracking-tight">
          {formatPlanAmount(plan.amount_cents, plan.currency)}
        </span>{' '}
        <span className="text-muted text-sm">{planIntervalLabel(plan)}</span>
      </p>
      {plan.description && <p className="text-muted text-sm break-words">{plan.description}</p>}
      <ul className="text-ink flex flex-col gap-1.5 text-sm">
        <li className="flex items-start gap-2">
          <Check className="text-success mt-0.5 size-4 shrink-0" aria-hidden="true" />
          {planMembersLabel(plan.max_members)}
        </li>
        {plan.features.map((feature) => (
          <li key={feature} className="flex items-start gap-2 break-words">
            <Check className="text-success mt-0.5 size-4 shrink-0" aria-hidden="true" />
            {featureLabel(feature)}
          </li>
        ))}
      </ul>
      {action && <div className="mt-auto pt-1">{action}</div>}
    </article>
  );
}
