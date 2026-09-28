import { useState } from 'react';
import {
  Button,
  Checkbox,
  Dialog,
  FormField,
  RadioGroup,
  Textarea,
  useToast,
  type RadioOption,
} from '@/components/ui';
import type { JobDetail } from '../../api';
import type { JobPhoto } from '../../fieldApi';
import { PHOTO_KIND_LABELS, type JobPhotoKind } from '../../model';
import { usePublishJobReport, type JobReport, type PublishResult } from '../../reportApi';

const KINDS: JobPhotoKind[] = ['before', 'after', 'inspection', 'other'];
const MESSAGE_MAX = 2000;

type SendChoice = 'both' | 'sms' | 'email' | 'none';

export interface ShareReportDialogProps {
  job: JobDetail;
  /** The live report being updated (null = first publish). */
  report: JobReport | null;
  photos: readonly JobPhoto[];
  onClose: () => void;
  onPublished: (result: PublishResult) => void;
}

/**
 * Publish (or update) the customer-facing job report and optionally send
 * its link by text / email (template "job_report"). Publishing again keeps
 * the same link.
 */
export function ShareReportDialog({
  job,
  report,
  photos,
  onClose,
  onPublished,
}: ShareReportDialogProps) {
  const toast = useToast();
  const publish = usePublishJobReport(job.id);
  const customer = job.customer;
  const canText = Boolean(customer?.phone) && !customer?.sms_opted_out_at;
  const canEmail = Boolean(customer?.email) && !customer?.email_opted_out_at;
  const [kinds, setKinds] = useState<JobPhotoKind[]>(
    report ? [...report.photo_kinds] : ['before', 'after'],
  );
  const [includeInspections, setIncludeInspections] = useState(report?.include_inspections ?? true);
  const [message, setMessage] = useState(report?.message ?? '');
  const [send, setSend] = useState<SendChoice>(
    canText && canEmail ? 'both' : canText ? 'sms' : canEmail ? 'email' : 'none',
  );

  const visibleCount = photos.filter((p) => p.customer_visible && kinds.includes(p.kind)).length;
  const sendOptions: RadioOption<SendChoice>[] = [
    ...(canText && canEmail ? [{ value: 'both' as const, label: 'Text and email' }] : []),
    ...(canText ? [{ value: 'sms' as const, label: 'Text message' }] : []),
    ...(canEmail ? [{ value: 'email' as const, label: 'Email' }] : []),
    { value: 'none', label: 'Don’t send — I’ll copy the link' },
  ];

  const save = async () => {
    try {
      const result = await publish.mutateAsync({
        includeInspections,
        photoKinds: kinds,
        message,
        send: send === 'none' ? null : send,
      });
      if (send !== 'none' && result.url === null) {
        toast.info(
          'Report published',
          'The link couldn’t be sent because this app’s web address isn’t set up yet. Copy the link to share it.',
        );
      } else if (send !== 'none' && !result.queued) {
        toast.info(
          'Report published, but no message was sent',
          'The customer may have opted out, or the job report message is turned off in Settings → Templates.',
        );
      } else {
        toast.success(send === 'none' ? 'Report published' : 'Report published and sent');
      }
      onPublished(result);
      onClose();
    } catch (error) {
      toast.error(error);
    }
  };

  return (
    <Dialog
      open
      onClose={onClose}
      title={report ? 'Update the customer report' : 'Share a job report'}
      description="The customer gets a private link to their before / after photos, inspection and shared files — never prices, notes or your team’s details."
      size="md"
      dismissible={!publish.isPending}
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={publish.isPending}>
            Cancel
          </Button>
          <Button loading={publish.isPending} onClick={() => void save()}>
            {send === 'none'
              ? report
                ? 'Update report'
                : 'Publish report'
              : report
                ? 'Update and send'
                : 'Publish and send'}
          </Button>
        </>
      }
    >
      <div className="flex flex-col gap-4">
        <fieldset className="flex flex-col gap-2">
          <legend className="text-ink mb-1 text-sm font-medium">Photos to include</legend>
          <div className="flex flex-wrap gap-x-5 gap-y-2">
            {KINDS.map((k) => (
              <Checkbox
                key={k}
                label={PHOTO_KIND_LABELS[k]}
                checked={kinds.includes(k)}
                onChange={(e) =>
                  setKinds((list) =>
                    e.target.checked ? [...list, k] : list.filter((x) => x !== k),
                  )
                }
              />
            ))}
          </div>
          <p className="text-muted text-xs" role="status">
            {visibleCount === 1
              ? '1 photo or video of these kinds is marked “Customer sees”.'
              : `${visibleCount} photos and videos of these kinds are marked “Customer sees”.`}{' '}
            Only those appear on the report.
          </p>
        </fieldset>
        <Checkbox
          label="Include inspections"
          description="The damage diagram, mileage and fuel level. The customer can sign an unsigned pre-service inspection from the report."
          checked={includeInspections}
          onChange={(e) => setIncludeInspections(e.target.checked)}
        />
        <FormField label="Message" help="Optional. Shown at the top of the report.">
          <Textarea
            rows={3}
            maxLength={MESSAGE_MAX}
            value={message}
            onChange={(e) => setMessage(e.target.value)}
          />
        </FormField>
        <RadioGroup<SendChoice>
          label="Send the link"
          value={send}
          onChange={setSend}
          options={sendOptions}
        />
        {!canText && !canEmail && (
          <p className="text-muted text-xs">
            This customer has no phone or email we can message. Copy the link after publishing.
          </p>
        )}
      </div>
    </Dialog>
  );
}
