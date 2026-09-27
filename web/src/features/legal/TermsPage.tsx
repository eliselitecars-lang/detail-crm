import { LegalDocument } from './components/LegalDocument';
import { termsOfService } from './content';
import { LEGAL_OPERATOR, type LegalOperator } from './operator';

/** Public /terms (no sign-in). `operator` defaults to this build's VITE_LEGAL_* values. */
export default function TermsPage({ operator = LEGAL_OPERATOR }: { operator?: LegalOperator }) {
  const { intro, sections } = termsOfService(operator);
  return (
    <LegalDocument title="Terms of Service" intro={intro} sections={sections} seeAlso="privacy" />
  );
}
