import { Badge } from '@/components/ui';
import type { CampaignStatus } from '../model';

const LABELS: Record<CampaignStatus, { label: string; tone: 'neutral' | 'info' | 'success' }> = {
  draft: { label: 'Draft', tone: 'neutral' },
  launched: { label: 'Launched', tone: 'success' },
  cancelled: { label: 'Cancelled', tone: 'neutral' },
};

export function CampaignStatusBadge({ status }: { status: CampaignStatus }) {
  const { label, tone } = LABELS[status];
  return (
    <Badge tone={tone} dot>
      {label}
    </Badge>
  );
}
