import { ArrowDown, ArrowUp, Layers, Pencil, Plus, Trash2 } from 'lucide-react';
import { useState } from 'react';
import {
  Badge,
  Button,
  ConfirmDialog,
  Dialog,
  FormField,
  IconButton,
  Input,
  SectionCard,
  Textarea,
  useToast,
} from '@/components/ui';
import { formatCents } from '@/lib/money';
import {
  MAX_QUOTE_OPTIONS,
  STARTER_OPTION_NAMES,
  useQuoteOptionMutations,
  type QuoteOptionRow,
  type QuoteRow,
} from '../api';

export interface QuoteOptionsCardProps {
  quote: QuoteRow;
  options: readonly QuoteOptionRow[];
  /** The option the quote counts (the customer's choice, else the first). */
  effectiveOptionId: string | null;
  editable: boolean;
  currency: string;
}

const NAME_MAX = 80;
const DESCRIPTION_MAX = 2000;

type Editing = { kind: 'none' } | { kind: 'new' } | { kind: 'edit'; option: QuoteOptionRow };

/**
 * Proposal options (good / better / best): up to 4 alternatives the customer
 * chooses between. Each option's total is the server's (shared lines + its
 * own lines, with the quote's discount and tax).
 */
export function QuoteOptionsCard({
  quote,
  options,
  effectiveOptionId,
  editable,
  currency,
}: QuoteOptionsCardProps) {
  const toast = useToast();
  const mutations = useQuoteOptionMutations(quote.id, options);
  const [editing, setEditing] = useState<Editing>({ kind: 'none' });
  const [removing, setRemoving] = useState<QuoteOptionRow | null>(null);
  const answered = quote.status === 'approved' || quote.status === 'converted';

  const startOptions = async () => {
    try {
      await mutations.add.mutateAsync(STARTER_OPTION_NAMES.map((name) => ({ name })));
      toast.success('Options added', 'Rename them and add each option’s lines.');
    } catch (error) {
      toast.error(error);
    }
  };

  const move = async (id: string, direction: -1 | 1) => {
    try {
      await mutations.move.mutateAsync({ id, direction });
    } catch (error) {
      toast.error(error);
    }
  };

  if (options.length === 0) {
    if (!editable) return null;
    return (
      <SectionCard
        title={
          <span className="inline-flex items-center gap-2">
            <Layers className="text-muted size-4" aria-hidden="true" />
            Proposal options
          </span>
        }
        description="Offer two to four alternatives (for example a basic and a premium package). The customer approves the one they want."
        actions={
          <Button
            size="sm"
            variant="secondary"
            loading={mutations.add.isPending}
            leadingIcon={<Plus className="size-4" aria-hidden="true" />}
            onClick={() => void startOptions()}
          >
            Offer options
          </Button>
        }
      >
        <p className="text-muted text-sm">Lines you already added stay shared by every option.</p>
      </SectionCard>
    );
  }

  return (
    <SectionCard
      title={
        <span className="inline-flex items-center gap-2">
          <Layers className="text-muted size-4" aria-hidden="true" />
          Proposal options
        </span>
      }
      description={
        answered
          ? 'The customer chose one option; only its lines carry over to the job.'
          : 'The customer approves one option. Shared lines are part of every option.'
      }
      flush
      actions={
        editable && options.length < MAX_QUOTE_OPTIONS ? (
          <Button
            size="sm"
            variant="secondary"
            leadingIcon={<Plus className="size-4" aria-hidden="true" />}
            onClick={() => setEditing({ kind: 'new' })}
          >
            Add option
          </Button>
        ) : undefined
      }
    >
      <ul className="divide-line divide-y" aria-label="Proposal options">
        {options.map((option, index) => {
          const counted = option.id === effectiveOptionId;
          return (
            <li key={option.id} className="flex flex-wrap items-start gap-3 px-4 py-3">
              <div className="min-w-0 flex-1">
                <div className="flex flex-wrap items-center gap-2">
                  <span className="text-ink text-sm font-medium break-words">{option.name}</span>
                  {counted && (
                    <Badge tone={quote.selected_option_id ? 'success' : 'neutral'}>
                      {quote.selected_option_id ? 'Chosen' : 'Shown in totals'}
                    </Badge>
                  )}
                </div>
                {option.description && (
                  <p className="text-muted mt-0.5 text-xs break-words whitespace-pre-line">
                    {option.description}
                  </p>
                )}
              </div>
              <div className="flex shrink-0 flex-col items-end gap-1">
                <span className="text-ink text-sm font-medium tabular-nums">
                  {formatCents(option.total_cents, { currency })}
                </span>
                {editable && (
                  <div className="flex gap-1">
                    <IconButton
                      size="sm"
                      variant="ghost"
                      label={`Move ${option.name} up`}
                      icon={<ArrowUp className="size-4" />}
                      disabled={index === 0 || mutations.move.isPending}
                      onClick={() => void move(option.id, -1)}
                    />
                    <IconButton
                      size="sm"
                      variant="ghost"
                      label={`Move ${option.name} down`}
                      icon={<ArrowDown className="size-4" />}
                      disabled={index === options.length - 1 || mutations.move.isPending}
                      onClick={() => void move(option.id, 1)}
                    />
                    <IconButton
                      size="sm"
                      variant="ghost"
                      label={`Rename ${option.name}`}
                      icon={<Pencil className="size-4" />}
                      onClick={() => setEditing({ kind: 'edit', option })}
                    />
                    <IconButton
                      size="sm"
                      variant="ghost"
                      label={`Remove ${option.name}`}
                      icon={<Trash2 className="size-4" />}
                      onClick={() => setRemoving(option)}
                    />
                  </div>
                )}
              </div>
            </li>
          );
        })}
      </ul>
      <OptionDialog
        editing={editing}
        onClose={() => setEditing({ kind: 'none' })}
        onSave={async (name, description) => {
          if (editing.kind === 'edit') {
            await mutations.update.mutateAsync({
              id: editing.option.id,
              patch: { name, description },
            });
            toast.success('Option saved');
          } else {
            await mutations.add.mutateAsync([{ name, description }]);
            toast.success('Option added');
          }
        }}
      />
      <ConfirmDialog
        open={removing !== null}
        onClose={() => setRemoving(null)}
        loading={mutations.remove.isPending}
        tone="danger"
        title={removing ? `Remove ${removing.name}?` : 'Remove option?'}
        description={
          options.length === 1
            ? 'Its lines are removed too, and the quote goes back to a single set of lines.'
            : 'Its lines are removed too. Shared lines stay.'
        }
        confirmLabel="Remove option"
        onConfirm={async () => {
          if (!removing) return;
          try {
            await mutations.remove.mutateAsync(removing.id);
            toast.success('Option removed');
            setRemoving(null);
          } catch (error) {
            toast.error(error);
          }
        }}
      />
    </SectionCard>
  );
}

function OptionDialog({
  editing,
  onClose,
  onSave,
}: {
  editing: Editing;
  onClose: () => void;
  onSave: (name: string, description: string | null) => Promise<void>;
}) {
  return (
    <Dialog
      open={editing.kind !== 'none'}
      onClose={onClose}
      size="sm"
      title={editing.kind === 'edit' ? 'Edit option' : 'Add option'}
      description="The name and description are shown to the customer."
    >
      {editing.kind !== 'none' && (
        <OptionForm
          key={editing.kind === 'edit' ? editing.option.id : 'new'}
          initialName={editing.kind === 'edit' ? editing.option.name : ''}
          initialDescription={editing.kind === 'edit' ? (editing.option.description ?? '') : ''}
          onClose={onClose}
          onSave={onSave}
        />
      )}
    </Dialog>
  );
}

function OptionForm({
  initialName,
  initialDescription,
  onClose,
  onSave,
}: {
  initialName: string;
  initialDescription: string;
  onClose: () => void;
  onSave: (name: string, description: string | null) => Promise<void>;
}) {
  const toast = useToast();
  const [name, setName] = useState(initialName);
  const [description, setDescription] = useState(initialDescription);
  const [submitted, setSubmitted] = useState(false);
  const [busy, setBusy] = useState(false);
  const nameError =
    name.trim() === ''
      ? 'Enter a name.'
      : name.trim().length > NAME_MAX
        ? `Use ${NAME_MAX} characters or fewer.`
        : undefined;
  const descriptionError =
    description.length > DESCRIPTION_MAX ? 'Use 2,000 characters or fewer.' : undefined;

  const submit = async () => {
    setSubmitted(true);
    if (nameError || descriptionError) return;
    setBusy(true);
    try {
      await onSave(name.trim(), description.trim() || null);
      onClose();
    } catch (error) {
      toast.error(error);
    } finally {
      setBusy(false);
    }
  };

  return (
    <form
      noValidate
      className="flex flex-col gap-4"
      onSubmit={(event) => {
        event.preventDefault();
        void submit();
      }}
    >
      <FormField label="Name" required error={submitted ? nameError : undefined}>
        <Input
          value={name}
          maxLength={NAME_MAX + 20}
          autoComplete="off"
          onChange={(event) => setName(event.target.value)}
        />
      </FormField>
      <FormField label="Description" error={descriptionError}>
        <Textarea
          rows={3}
          value={description}
          onChange={(event) => setDescription(event.target.value)}
        />
      </FormField>
      <div className="flex justify-end gap-2">
        <Button variant="secondary" onClick={onClose} disabled={busy}>
          Cancel
        </Button>
        <Button type="submit" loading={busy}>
          Save option
        </Button>
      </div>
    </form>
  );
}
