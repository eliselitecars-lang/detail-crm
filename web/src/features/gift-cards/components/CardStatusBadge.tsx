import { Badge, type BadgeTone } from '@/components/ui';
import { STATUS_LABELS, type GiftCardStatus } from '../api';

const TONES: Record<GiftCardStatus, BadgeTone> = {
  active: 'success',
  depleted: 'neutral',
  void: 'danger',
  expired: 'warning',
};

export function CardStatusBadge({ status }: { status: GiftCardStatus }) {
  return <Badge tone={TONES[status]}>{STATUS_LABELS[status]}</Badge>;
}
