import { LegalDocument } from './components/LegalDocument';
import { privacyPolicy } from './content';
import { LEGAL_OPERATOR, type LegalOperator } from './operator';

/** Public /privacy (no sign-in). `operator` defaults to this build's VITE_LEGAL_* values. */
export default function PrivacyPage({ operator = LEGAL_OPERATOR }: { operator?: LegalOperator }) {
  const { intro, sections } = privacyPolicy(operator);
  return <LegalDocument title="Privacy Policy" intro={intro} sections={sections} seeAlso="terms" />;
}
