import { Button } from '@/components/ui';

export interface FormActionsProps {
  dirty: boolean;
  saving: boolean;
  onDiscard: () => void;
  saveLabel?: string;
}

/**
 * Save / discard row at the end of a settings form. Sticky at the bottom of
 * the viewport so long forms can be saved without scrolling back.
 */
export function FormActions({
  dirty,
  saving,
  onDiscard,
  saveLabel = 'Save changes',
}: FormActionsProps) {
  return (
    <div className="border-line bg-surface/95 rounded-card shadow-card sticky bottom-3 z-10 flex flex-wrap items-center justify-end gap-2 border px-3 py-2.5 backdrop-blur sm:px-4 sm:py-3">
      <p className="text-muted sr-only mr-auto text-sm sm:not-sr-only" aria-live="polite">
        {dirty ? 'You have unsaved changes.' : 'All changes saved.'}
      </p>
      <Button variant="secondary" disabled={!dirty || saving} onClick={onDiscard}>
        Discard
      </Button>
      <Button type="submit" loading={saving} disabled={!dirty}>
        {saveLabel}
      </Button>
    </div>
  );
}
