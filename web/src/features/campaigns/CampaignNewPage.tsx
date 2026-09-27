import { PageHeader } from '@/components/ui';
import { CampaignEditor } from './components/CampaignEditor';

export default function CampaignNewPage() {
  return (
    <>
      <PageHeader
        title="New campaign"
        description="Write the message, choose who gets it, then launch."
        back={{ to: '/app/campaigns', label: 'Campaigns' }}
      />
      <CampaignEditor />
    </>
  );
}
