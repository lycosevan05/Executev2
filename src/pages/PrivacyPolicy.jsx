/**
 * PrivacyPolicy — in-app privacy policy for Execute by Execute Labs.
 * Styled to match the rest of the app (Billing-style sticky header + back button).
 */

import { useNavigate } from 'react-router-dom';
import { ChevronLeft } from 'lucide-react';

const ACCENT_DARK = '#8ea400';
const EFFECTIVE_DATE = 'June 3, 2026';
const CONTACT_EMAIL = 'privacy@executelabs.app';

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

export default function PrivacyPolicy() {
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
            <h1 className="text-lg font-bold tracking-tight" style={{ color: '#141613' }}>Privacy Policy</h1>
            <p className="text-xs" style={{ color: '#91968e' }}>Execute by Execute Labs</p>
          </div>
        </div>
      </div>

      <div className="px-5 pb-32 pt-5 space-y-4" style={{ paddingBottom: 'calc(8rem + env(safe-area-inset-bottom))' }}>
        <p className="text-xs px-1" style={{ color: '#91968e' }}>Effective date: {EFFECTIVE_DATE}</p>

        <Section title="Overview">
          <p>
            Execute is a fitness and performance application operated by Execute Labs ("Execute," "we," "us," or "our").
            This Privacy Policy explains what information we collect, how we use it, who we share it with, and the choices you
            have. By creating an account and using Execute, you agree to the practices described here.
          </p>
        </Section>

        <Section title="Information we collect">
          <p>We collect only the information needed to provide and improve the app:</p>
          <ul className="list-disc pl-5 space-y-1">
            <li><strong>Account information.</strong> Your email address, and basic profile details such as a display name. You create an account using an email one-time passcode (OTP) or by signing in with Apple or Google through our authentication provider, Supabase.</li>
            <li><strong>Fitness and health-related data you enter.</strong> Information you choose to log, including workouts, exercises, sets and reps, nutrition and meals, calorie and macro targets, goals, recovery and readiness check-ins, body measurements, and related notes.</li>
            <li><strong>Subscription and purchase status.</strong> Whether you hold an active Premium subscription, your plan, renewal status, and billing state. This is processed through Apple In-App Purchase (via RevenueCat) on iOS and through Stripe on the web. We do not collect or store full payment card numbers.</li>
            <li><strong>Usage and device information.</strong> Limited technical data such as app version, platform, and basic interaction signals used to operate the service and diagnose issues.</li>
          </ul>
          <p>We do not knowingly collect data beyond what you provide or what is required to run the app.</p>
        </Section>

        <Section title="How we use your information">
          <ul className="list-disc pl-5 space-y-1">
            <li>To create and secure your account and authenticate sign-in.</li>
            <li>To store and display the workout, nutrition, goal, and recovery data you enter.</li>
            <li>To generate personalized plans and recommendations, including AI-assisted plan and meal generation based on the inputs you provide.</li>
            <li>To manage your Premium subscription, entitlements, and renewals.</li>
            <li>To operate, maintain, troubleshoot, and improve the app.</li>
            <li>To communicate with you about your account or important service changes.</li>
          </ul>
        </Section>

        <Section title="AI features">
          <p>
            Premium features use AI to generate workout plans, meal guidance, and insights. To do this, the relevant inputs you
            provide (such as goals, preferences, equipment, and logged data) are sent to our AI processing systems to produce a
            response. We do not use your data to identify you to third parties for advertising.
          </p>
        </Section>

        <Section title="Third parties we share data with">
          <p>We share data only with service providers that help us operate Execute, and only as needed:</p>
          <ul className="list-disc pl-5 space-y-1">
            <li><strong>Supabase</strong> — hosts our database and handles authentication and storage of your account and logged data.</li>
            <li><strong>RevenueCat</strong> — manages in-app subscription entitlements on iOS.</li>
            <li><strong>Apple</strong> — processes In-App Purchases and manages billing for iOS subscriptions.</li>
            <li><strong>Stripe</strong> — processes subscription payments on the web.</li>
          </ul>
          <p>
            These providers process data on our behalf under their own terms and privacy policies. We do not sell your personal
            information.
          </p>
        </Section>

        <Section title="Data retention and account deletion">
          <p>
            We retain your data for as long as your account is active. You can delete your account at any time from within the app
            (Profile → Delete Account). Deleting your account permanently removes your cloud data, including workouts, nutrition
            logs, goals, and profile information. Some records may persist briefly in backups or be retained where required by law,
            and subscription/transaction records held by Apple or Stripe are governed by those providers.
          </p>
        </Section>

        <Section title="Data security">
          <p>
            We use industry-standard safeguards to protect your information in transit and at rest. No method of transmission or
            storage is completely secure, but we work to protect your data and limit access to it.
          </p>
        </Section>

        <Section title="Children's privacy">
          <p>
            Execute is not directed to children under 13 (or the minimum age required in your jurisdiction). We do not knowingly
            collect personal information from children. If you believe a child has provided us information, please contact us and we
            will delete it.
          </p>
        </Section>

        <Section title="Your choices">
          <p>
            You can review and edit much of your data directly in the app, change your subscription status, and delete your account.
            For other requests regarding your personal information, contact us using the details below.
          </p>
        </Section>

        <Section title="Changes to this policy">
          <p>
            We may update this Privacy Policy from time to time. When we do, we will revise the effective date above. Continued use
            of the app after an update means you accept the revised policy.
          </p>
        </Section>

        <Section title="Contact">
          <p>
            For privacy questions or requests, contact Execute Labs at{' '}
            <a href={`mailto:${CONTACT_EMAIL}`} className="font-semibold underline" style={{ color: ACCENT_DARK }}>{CONTACT_EMAIL}</a>.
            This is our designated privacy contact address.
          </p>
        </Section>
      </div>
    </div>
  );
}
