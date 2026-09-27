import { Crown } from 'lucide-react';
import { useState } from 'react';
import { Button, Dialog, FormField, Input, SectionCard, Select, useToast } from '@/components/ui';
import { errorMessage } from '@/lib/errors';
import { ROLE_LABELS } from '@/features/shop/permissions';
import { useShop } from '@/features/shop/shopContext';
import { useTransferOwnership } from '../api';
import type { TeamMember } from '../model';

/** Owner only: hand the shop to another active member (strong confirmation). */
export function TransferOwnershipCard({ members }: { members: readonly TeamMember[] }) {
  const { shop } = useShop();
  const toast = useToast();
  const transfer = useTransferOwnership();
  const [open, setOpen] = useState(false);
  const [targetId, setTargetId] = useState('');
  const [confirmText, setConfirmText] = useState('');
  const candidates = members.filter((m) => m.active && m.role !== 'owner');
  const target = candidates.find((m) => m.member_id === targetId) ?? null;
  const confirmed = confirmText.trim() === shop.name.trim();

  const close = () => {
    if (transfer.isPending) return;
    setOpen(false);
    setTargetId('');
    setConfirmText('');
    transfer.reset();
  };

  const submit = async () => {
    if (!target || !confirmed) return;
    try {
      await transfer.mutateAsync(target.member_id);
      toast.success(`${target.display_name} now owns ${shop.name}`, 'You are now an admin.');
      setOpen(false);
    } catch {
      // shown via transfer.error
    }
  };

  return (
    <SectionCard
      title="Transfer ownership"
      description="Make another active team member the owner. You become an admin and can’t undo this yourself."
    >
      <Button
        variant="danger"
        leadingIcon={<Crown />}
        disabled={candidates.length === 0}
        onClick={() => setOpen(true)}
      >
        Transfer ownership…
      </Button>
      {candidates.length === 0 && (
        <p className="text-muted mt-2 text-sm">
          Invite someone first — there’s nobody to transfer to.
        </p>
      )}
      <Dialog
        open={open}
        onClose={close}
        role="alertdialog"
        dismissible={!transfer.isPending}
        title="Transfer ownership"
        description="The new owner controls billing, payouts, team roles and can delete the shop."
        footer={
          <>
            <Button variant="secondary" onClick={close} disabled={transfer.isPending}>
              Cancel
            </Button>
            <Button
              variant="danger"
              loading={transfer.isPending}
              disabled={!target || !confirmed}
              onClick={() => void submit()}
            >
              Transfer ownership
            </Button>
          </>
        }
      >
        <div className="flex flex-col gap-4">
          {transfer.error && (
            <p role="alert" className="text-danger-ink text-sm">
              {errorMessage(transfer.error)}
            </p>
          )}
          <FormField label="New owner" required>
            <Select
              value={targetId}
              placeholder="Choose a team member"
              onChange={(e) => setTargetId(e.target.value)}
              options={candidates.map((m) => ({
                value: m.member_id,
                label: `${m.display_name} (${ROLE_LABELS[m.role]})`,
              }))}
            />
          </FormField>
          <FormField
            label={`Type the shop name “${shop.name}” to confirm`}
            required
            error={confirmText !== '' && !confirmed ? 'The name doesn’t match.' : undefined}
          >
            <Input
              value={confirmText}
              autoComplete="off"
              onChange={(e) => setConfirmText(e.target.value)}
            />
          </FormField>
        </div>
      </Dialog>
    </SectionCard>
  );
}
