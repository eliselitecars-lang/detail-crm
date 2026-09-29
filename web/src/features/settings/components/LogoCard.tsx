import { ImageUp, Trash2 } from 'lucide-react';
import { useId, useRef, useState, type ChangeEvent } from 'react';
import { Button, ConfirmDialog, SectionCard, useToast } from '@/components/ui';
import { shopAssetUrl } from '@/lib/supabase';
import { logoFileProblem, useSaveLogo, type ShopSettings } from '../api';

/** Logo upload to shop-assets/<shop_id>/logo.<ext> (public bucket, 5 MB, PNG/JPG/WebP). */
export function LogoCard({ shop, canEdit }: { shop: ShopSettings; canEdit: boolean }) {
  const inputId = useId();
  const inputRef = useRef<HTMLInputElement>(null);
  const toast = useToast();
  const save = useSaveLogo();
  const [problem, setProblem] = useState<string | null>(null);
  // The stored file is deleted and every customer-facing page loses the logo:
  // ask first, like a service image.
  const [confirmRemove, setConfirmRemove] = useState(false);
  // Same path after re-upload → bust the browser cache with the row version.
  const url = shop.logo_path
    ? `${shopAssetUrl(shop.logo_path) ?? ''}?v=${encodeURIComponent(shop.updated_at)}`
    : null;

  const onFile = (event: ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    event.target.value = '';
    if (!file) return;
    const issue = logoFileProblem(file);
    setProblem(issue);
    if (issue) return;
    save.mutate(
      { file, previousPath: shop.logo_path },
      {
        onSuccess: () => toast.success('Logo updated'),
        onError: (error) => toast.error(error),
      },
    );
  };

  const remove = async () => {
    try {
      await save.mutateAsync({ file: null, previousPath: shop.logo_path });
      toast.success('Logo removed');
      setConfirmRemove(false);
    } catch (error) {
      toast.error(error);
    }
  };

  return (
    <SectionCard
      title="Logo"
      description="Shown on your booking page, quotes, invoices and customer emails. PNG, JPG or WebP, up to 5 MB."
    >
      <div className="flex flex-wrap items-center gap-4">
        <div className="border-line bg-surface-2 rounded-card flex size-20 shrink-0 items-center justify-center overflow-hidden border">
          {url ? (
            <img src={url} alt={`${shop.name} logo`} className="size-full object-contain" />
          ) : (
            <span className="text-muted px-2 text-center text-xs">No logo</span>
          )}
        </div>
        {canEdit && (
          <div className="flex flex-wrap gap-2">
            <input
              ref={inputRef}
              id={inputId}
              type="file"
              accept="image/png,image/jpeg,image/webp"
              className="sr-only"
              aria-describedby={problem ? `${inputId}-error` : undefined}
              onChange={onFile}
              tabIndex={-1}
            />
            <Button
              variant="secondary"
              leadingIcon={<ImageUp className="size-4" aria-hidden="true" />}
              loading={save.isPending}
              onClick={() => inputRef.current?.click()}
            >
              {shop.logo_path ? 'Replace logo' : 'Upload logo'}
            </Button>
            {shop.logo_path && (
              <Button
                variant="ghost"
                leadingIcon={<Trash2 className="size-4" aria-hidden="true" />}
                disabled={save.isPending}
                onClick={() => setConfirmRemove(true)}
              >
                Remove
              </Button>
            )}
          </div>
        )}
      </div>
      {problem && (
        <p
          id={`${inputId}-error`}
          role="alert"
          className="text-danger-ink mt-2 text-xs font-medium"
        >
          {problem}
        </p>
      )}
      <ConfirmDialog
        open={confirmRemove}
        onClose={() => setConfirmRemove(false)}
        title="Remove your logo?"
        description="The logo file is deleted and disappears from your booking page, quotes, invoices and customer emails. This can’t be undone; upload the file again to bring it back."
        confirmLabel="Remove logo"
        tone="danger"
        loading={save.isPending}
        onConfirm={remove}
      />
    </SectionCard>
  );
}
