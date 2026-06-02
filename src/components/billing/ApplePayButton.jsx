/**
 * ApplePayButton — Renders a Stripe Payment Request Button that shows
 * Apple Pay on Safari/iOS, Google Pay on Android/Chrome, or falls back
 * to the standard Stripe hosted checkout.
 *
 * Usage: drop this anywhere you currently show the upgrade CTA.
 * It needs to be wrapped in a <Elements> provider (done in Billing.jsx).
 */

import { useEffect, useState } from 'react';
import { useStripe, PaymentRequestButtonElement } from '@stripe/react-stripe-js';
import { Loader2, Sparkles } from 'lucide-react';
import { getPlatform } from '@/lib/platform';

const ACCENT = '#c8e000';

export default function ApplePayButton({ priceAmountCents = 1499, onFallback, disabled }) {
  const stripe = useStripe();
  const [paymentRequest, setPaymentRequest] = useState(null);
  const [canShow, setCanShow] = useState(false);
  const [checking, setChecking] = useState(true);

  // On iOS (native app) Apple requires StoreKit IAP for digital subscriptions.
  // The native StoreKit flow is rendered by Billing.jsx instead, so this
  // Stripe-based component must not render.
  const isIOSNative = getPlatform() === 'ios';

  useEffect(() => {
    if (isIOSNative) return;
    if (!stripe) return;

    const pr = stripe.paymentRequest({
      country: 'US',
      currency: 'usd',
      total: {
        label: 'Execute Premium',
        amount: priceAmountCents,
      },
      requestPayerName: true,
      requestPayerEmail: true,
    });

    pr.canMakePayment().then((result) => {
      if (result) {
        setPaymentRequest(pr);
        setCanShow(true);
      } else {
        setCanShow(false);
      }
      setChecking(false);
    });

    // When the user completes Apple/Google Pay, redirect to Stripe checkout
    // (The payment token is handled server-side via webhook)
    pr.on('paymentmethod', async (ev) => {
      ev.complete('success');
      onFallback?.();
    });
  }, [stripe, isIOSNative]);

  if (isIOSNative) return null;

  if (checking) {
    return (
      <div className="flex items-center justify-center py-4">
        <Loader2 size={16} className="animate-spin" style={{ color: '#91968e' }} />
      </div>
    );
  }

  // Apple Pay / Google Pay available — show the native button
  if (canShow && paymentRequest) {
    return (
      <div className="space-y-3">
        <PaymentRequestButtonElement
          options={{
            paymentRequest,
            style: {
              paymentRequestButton: {
                type: 'subscribe',
                theme: 'dark',
                height: '52px',
              },
            },
          }}
        />
        <div className="flex items-center gap-2">
          <div className="flex-1 h-px" style={{ background: '#e8e1d4' }} />
          <span className="text-[10px] font-semibold" style={{ color: '#b8b4ac' }}>or pay with card</span>
          <div className="flex-1 h-px" style={{ background: '#e8e1d4' }} />
        </div>
        <button
          onClick={onFallback}
          disabled={disabled}
          className="w-full py-3.5 rounded-2xl text-sm font-semibold flex items-center justify-center gap-2 border"
          style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#5d635d' }}
        >
          <Sparkles size={14} style={{ color: ACCENT }} />
          Pay with card — $14.99/mo
        </button>
      </div>
    );
  }

  // Fallback: standard checkout button
  return (
    <button
      onClick={onFallback}
      disabled={disabled}
      className="w-full py-3.5 rounded-2xl text-sm font-black flex items-center justify-center gap-2"
      style={{ background: disabled ? 'rgba(200,224,0,0.5)' : ACCENT, color: '#141613' }}
    >
      {disabled ? <Loader2 size={14} className="animate-spin" /> : <Sparkles size={14} />}
      {disabled ? 'Starting checkout…' : 'Upgrade to Premium — $14.99/month'}
    </button>
  );
}