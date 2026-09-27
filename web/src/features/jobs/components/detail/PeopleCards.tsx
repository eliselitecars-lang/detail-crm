import { Car, Mail, MapPin, MessageSquare, Phone, User } from 'lucide-react';
import { Link } from 'react-router';
import { Badge, KeyValueList, SectionCard } from '@/components/ui';
import { formatPhone, phoneHref } from '@/lib/phone';
import { useCan } from '@/features/shop/useCan';
import type { JobDetail } from '../../api';
import { customerName, formatAddress, mapsUrl, vehicleLabel } from '../../model';

const linkClass = 'text-primary-ink inline-flex items-center gap-1.5 text-sm hover:underline';

export function CustomerCard({ job }: { job: JobDetail }) {
  const canOpen = useCan('customers.viewAssigned');
  const c = job.customer;
  if (!c) {
    return (
      <SectionCard title="Customer" level={3}>
        <p className="text-muted text-sm">This customer is not visible to you.</p>
      </SectionCard>
    );
  }
  const name = customerName(c);
  const call = phoneHref(c.phone, 'tel');
  const text = phoneHref(c.phone, 'sms');
  const address = formatAddress({
    line1: c.address_line1,
    line2: c.address_line2,
    city: c.city,
    region: c.region,
    postalCode: c.postal_code,
  });
  return (
    <SectionCard title="Customer" level={3}>
      <div className="flex flex-col gap-2">
        <p className="text-ink flex items-center gap-2 font-semibold">
          <User className="text-muted size-4" aria-hidden="true" />
          {canOpen ? (
            <Link to={`/app/customers/${c.id}`} className="hover:underline">
              {name}
            </Link>
          ) : (
            name
          )}
        </p>
        {c.company && name !== c.company && <p className="text-muted text-sm">{c.company}</p>}
        {c.phone && (
          <div className="flex flex-wrap items-center gap-x-4 gap-y-1">
            <span className="text-ink text-sm tabular-nums">{formatPhone(c.phone)}</span>
            {call && (
              <a href={call} className={linkClass} aria-label={`Call ${name}`}>
                <Phone className="size-4" aria-hidden="true" />
                Call
              </a>
            )}
            {text && (
              <a href={text} className={linkClass} aria-label={`Text ${name}`}>
                <MessageSquare className="size-4" aria-hidden="true" />
                Text
              </a>
            )}
            {c.sms_opted_out_at && <Badge tone="warning">Opted out of texts</Badge>}
          </div>
        )}
        {c.email && (
          <a href={`mailto:${c.email}`} className={linkClass}>
            <Mail className="size-4" aria-hidden="true" />
            {c.email}
          </a>
        )}
        {address && job.location_type === 'shop' && (
          <p className="text-muted text-sm">{address}</p>
        )}
      </div>
    </SectionCard>
  );
}

export function VehicleCard({ job }: { job: JobDetail }) {
  const v = job.vehicle;
  return (
    <SectionCard title="Vehicle" level={3}>
      {v ? (
        <div className="flex flex-col gap-2">
          <p className="text-ink flex items-center gap-2 font-semibold">
            <Car className="text-muted size-4" aria-hidden="true" />
            {vehicleLabel(v, true)}
          </p>
          <KeyValueList
            items={[
              ...(v.license_plate ? [{ key: 'plate', label: 'Plate', value: v.license_plate }] : []),
              ...(v.vin ? [{ key: 'vin', label: 'VIN', value: <span className="font-mono text-xs">{v.vin}</span> }] : []),
            ]}
          />
        </div>
      ) : (
        <p className="text-muted text-sm">No vehicle on this job.</p>
      )}
    </SectionCard>
  );
}

/** Service location line with a maps link for mobile jobs. */
export function LocationLine({ job }: { job: JobDetail }) {
  if (job.location_type === 'shop') {
    return <span>At the shop</span>;
  }
  const address = formatAddress({
    line1: job.service_address_line1,
    line2: job.service_address_line2,
    city: job.service_city,
    region: job.service_region,
    postalCode: job.service_postal_code,
  });
  if (!address) return <span>Mobile — no address yet</span>;
  return (
    <a href={mapsUrl(address)} target="_blank" rel="noreferrer" className={linkClass}>
      <MapPin className="size-4" aria-hidden="true" />
      {address}
      <span className="sr-only"> (opens maps in a new tab)</span>
    </a>
  );
}
