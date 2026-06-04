/**
 * Terms — in-app Terms of Use / EULA for Execute by Execute Labs.
 * Styled to match the rest of the app (Billing-style sticky header + back button).
 */

import { useNavigate } from 'react-router-dom';
import { ChevronLeft } from 'lucide-react';

const ACCENT_DARK = '#8ea400';
const EFFECTIVE_DATE = 'June 3, 2026';
const CONTACT_EMAIL = 'support@executelabs.app';
const GOVERNING_LAW = 'British Columbia, Canada';

function Section({ title, children }) {
  return (
    <div className="rounded-3xl border p-5" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
      <h2 className="text-sm font-bold mb-2" style={{ color: '#141613' }}>{title}</h2>
      <div className="space-y-2 text-sm leading-relaxed" style={{ color: '#5d635d' }}>
        {children}
      </div>
    </div>
  );
}

export default function Terms() {
  const navigate = useNavigate();

  return (
    <div className="min-h-screen" style={{ background: '#f6f2e8' }}>
      {/* Header */}
      <div className="sticky top-0 z-40 px-5 pb-4"
        style={{ paddingTop: 'max(3rem, calc(env(safe-area-inset-top) + 1rem))', background: 'rgba(251,248,241,0.95)', backdropFilter: 'blur(24px)', borderBottom: '1px solid #e8e1d4' }}>
        <div className="flex items-center gap-3">
          <button onClick={() => navigate(-1)}
            className="w-8 h-8 rounded-xl flex items-center justify-center border"
            style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
            <ChevronLeft size={14} style={{ color: '#5d635d' }} />
          </button>
          <div>
            <h1 className="text-lg font-bold tracking-tight" style={{ color: '#141613' }}>Terms of Use</h1>
            <p className="text-xs" style={{ color: '#91968e' }}>Execute by Execute Labs</p>
          </div>
        </div>
      </div>

      <div className="px-5 pb-32 pt-5 space-y-4" style={{ paddingBottom: 'calc(8rem + env(safe-area-inset-bottom))' }}>
        <p className="text-xs px-1" style={{ color: '#91968e' }}>Effective date: {EFFECTIVE_DATE}</p>

        <Section title="Agreement to terms">
          <p>
            These Terms of Use ("Terms") form a binding agreement between you and Execute Labs ("Execute," "we," "us," or "our")
            governing your use of the Execute application and related services (the "App"). By creating an account or using the App,
            you agree to these Terms. If you do not agree, do not use the App.
          </p>
        </Section>

        <Section title="License to use the app">
          <p>
            Subject to these Terms, we grant you a limited, non-exclusive, non-transferable, revocable license to download and use
            the App for your personal, non-commercial use on devices you own or control. You may not copy, modify, distribute, sell,
            reverse engineer, or create derivative works from the App except as permitted by law.
          </p>
        </Section>

        <Section title="Accounts">
          <p>
            You must create an account to use the App, using an email one-time passcode or sign-in with Apple or Google. You are
            responsible for maintaining the confidentiality of your account and for all activity under it. You must provide accurate
            information and promptly update it as needed.
          </p>
        </Section>

        <Section title="Subscriptions and billing">
          <ul className="list-disc pl-5 space-y-1">
            <li><strong>Premium subscription.</strong> Execute offers an auto-renewable Premium subscription. Core manual tracking features are free; Premium unlocks AI-powered plans, guidance, and insights.</li>
            <li><strong>Auto-renewal.</strong> Subscriptions automatically renew at the end of each billing period unless canceled at least 24 hours before the end of the current period. Your account is charged for renewal within 24 hours before the end of the current period.</li>
            <li><strong>Billing on iOS.</strong> On iOS, payment is charged to your Apple App Store account at confirmation of purchase. Subscriptions are managed by Apple and subject to Apple's standard End User License Agreement for licensed applications, available at <a href="https://www.apple.com/legal/internet-services/itunes/dev/stdeula/" className="font-semibold underline" style={{ color: ACCENT_DARK }}>https://www.apple.com/legal/internet-services/itunes/dev/stdeula/</a>.</li>
            <li><strong>Billing on web.</strong> On the web, subscriptions are processed by Stripe and charged to the payment method you provide.</li>
            <li><strong>Cancellation.</strong> You can cancel anytime. On iOS, manage or cancel your subscription in your Apple account settings (Settings → Apple ID → Subscriptions). On the web, manage your subscription through the billing portal in the App.</li>
            <li><strong>Refunds.</strong> Except where required by law, payments are non-refundable. Refunds, if any, are handled per the policies of the applicable store (Apple) or payment processor (Stripe).</li>
            <li><strong>Price changes.</strong> We may change subscription pricing; changes apply to future billing periods and, where required, with notice and your consent.</li>
          </ul>
        </Section>

        <Section title="Acceptable use">
          <p>You agree not to:</p>
          <ul className="list-disc pl-5 space-y-1">
            <li>Use the App for any unlawful, harmful, or fraudulent purpose.</li>
            <li>Attempt to gain unauthorized access to the App, other accounts, or our systems.</li>
            <li>Interfere with or disrupt the App or its infrastructure.</li>
            <li>Upload content that infringes the rights of others or violates applicable law.</li>
            <li>Misuse AI features to generate unlawful, abusive, or harmful content.</li>
          </ul>
        </Section>

        <Section title="Not medical advice">
          <p>
            Execute is a fitness and performance tool, not a medical device or healthcare provider. Content, plans, and AI-generated
            recommendations are for informational and general fitness purposes only and are not medical, nutritional, or professional
            advice. Always consult a qualified healthcare professional before beginning any exercise or nutrition program, especially
            if you have a medical condition, are pregnant, or are taking medication. You use the App at your own risk.
          </p>
        </Section>

        <Section title="Disclaimers">
          <p>
            The App is provided "as is" and "as available" without warranties of any kind, whether express or implied, including
            warranties of merchantability, fitness for a particular purpose, and non-infringement. We do not warrant that the App will
            be uninterrupted, error-free, or that results will meet your expectations.
          </p>
        </Section>

        <Section title="Limitation of liability">
          <p>
            To the maximum extent permitted by law, Execute Labs and its providers will not be liable for any indirect, incidental,
            special, consequential, or punitive damages, or any loss of data, profits, or revenue, arising from or related to your use
            of the App. Our total liability for any claim relating to the App will not exceed the amount you paid us in the twelve
            months before the event giving rise to the claim.
          </p>
        </Section>

        <Section title="Termination">
          <p>
            You may stop using the App and delete your account at any time from within the App. We may suspend or terminate your access
            if you violate these Terms or if we discontinue the App. Upon termination, your license ends, though provisions that by
            their nature should survive (such as disclaimers and limitations of liability) will continue to apply.
          </p>
        </Section>

        <Section title="Governing law">
          <p>
            These Terms are governed by the laws of {GOVERNING_LAW}, without regard to its conflict-of-laws principles. Any disputes
            will be resolved in the courts located in that jurisdiction, unless otherwise required by applicable law.
          </p>
        </Section>

        <Section title="Changes to these terms">
          <p>
            We may update these Terms from time to time. When we do, we will revise the effective date above. Continued use of the App
            after an update means you accept the revised Terms.
          </p>
        </Section>

        <Section title="Contact">
          <p>
            Questions about these Terms? Contact Execute Labs at{' '}
            <a href={`mailto:${CONTACT_EMAIL}`} className="font-semibold underline" style={{ color: ACCENT_DARK }}>{CONTACT_EMAIL}</a>.
          </p>
        </Section>
      </div>
    </div>
  );
}
