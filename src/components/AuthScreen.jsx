import { useState } from 'react';
import { Link } from 'react-router-dom';
import { Mail, Loader2, CheckCircle2, AlertTriangle, Apple } from 'lucide-react';
import { useAuth } from '@/lib/AuthContext';
import { isIOS } from '@/lib/platform';

const ACCENT = '#c8e000';

function GoogleLogo({ size = 18 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 18 18" xmlns="http://www.w3.org/2000/svg">
      <path fill="#4285F4" d="M17.64 9.2c0-.637-.057-1.251-.164-1.84H9v3.481h4.844a4.14 4.14 0 0 1-1.796 2.716v2.258h2.908c1.702-1.567 2.684-3.874 2.684-6.615Z"/>
      <path fill="#34A853" d="M9 18c2.43 0 4.467-.806 5.956-2.184l-2.908-2.259c-.806.54-1.837.86-3.048.86-2.344 0-4.328-1.584-5.036-3.711H.957v2.332A8.997 8.997 0 0 0 9 18Z"/>
      <path fill="#FBBC05" d="M3.964 10.706A5.41 5.41 0 0 1 3.682 9c0-.593.102-1.17.282-1.706V4.962H.957A8.997 8.997 0 0 0 0 9c0 1.452.348 2.827.957 4.038l3.007-2.332Z"/>
      <path fill="#EA4335" d="M9 3.58c1.321 0 2.508.454 3.44 1.345l2.582-2.58C13.463.891 11.426 0 9 0A8.997 8.997 0 0 0 .957 4.962L3.964 7.294C4.672 5.167 6.656 3.58 9 3.58Z"/>
    </svg>
  );
}

export default function AuthScreen({ missingConfig = false }) {
  const { loginWithOtp, verifyOtp, loginWithOAuth, authError } = useAuth();
  const [oauthLoading, setOauthLoading] = useState(null); // 'google' | 'apple' | null
  const [showEmail, setShowEmail] = useState(false);
  const [email, setEmail] = useState('');
  const [sending, setSending] = useState(false);
  const [sent, setSent] = useState(false);
  const [error, setError] = useState('');
  // iOS uses a 6-digit code (verifyOtp) instead of a magic link, which can't
  // hand the session back to the native app.
  const useCode = isIOS();
  const [code, setCode] = useState('');
  const [verifying, setVerifying] = useState(false);

  const handleOAuth = async (provider) => {
    setError('');
    setOauthLoading(provider);
    try {
      await loginWithOAuth(provider);
      // On web, Supabase redirects the page on success. On iOS, control hands
      // off to the in-app browser and the appUrlOpen deep-link bridge finishes
      // the flow — so clear the spinner here, otherwise it spins forever if the
      // user dismisses the browser without completing sign-in.
      setOauthLoading(null);
    } catch (err) {
      setError(err.message || `Unable to sign in with ${provider}.`);
      setOauthLoading(null);
    }
  };

  const handleEmailSubmit = async (event) => {
    event.preventDefault();
    setError('');
    setSending(true);
    try {
      await loginWithOtp(email.trim());
      setSent(true);
    } catch (err) {
      setError(err.message || 'Unable to send sign-in link.');
    } finally {
      setSending(false);
    }
  };

  const handleVerify = async (event) => {
    event.preventDefault();
    setError('');
    setVerifying(true);
    try {
      await verifyOtp(email.trim(), code.trim());
      // On success the auth listener swaps in the authenticated app; this
      // component unmounts, so no further state update is needed.
    } catch (err) {
      setError(err.message || 'Invalid or expired code.');
      setVerifying(false);
    }
  };

  return (
    <div className="min-h-screen flex items-center justify-center px-5" style={{ background: '#f6f2e8' }}>
      <div className="w-full max-w-sm rounded-2xl border p-5 shadow-sm" style={{ background: '#fffdf8', borderColor: '#e8e1d4' }}>
        <div className="flex items-center gap-3 mb-6">
          <div className="w-11 h-11 rounded-2xl flex items-center justify-center" style={{ background: 'rgba(200,224,0,0.16)' }}>
            {missingConfig ? <AlertTriangle size={20} style={{ color: '#8ea400' }} /> : <Mail size={20} style={{ color: '#8ea400' }} />}
          </div>
          <div>
            <h1 className="text-lg font-bold" style={{ color: '#141613' }}>Execute</h1>
            <p className="text-xs" style={{ color: '#91968e' }}>
              {missingConfig ? 'Backend configuration needed' : 'Sign in to continue'}
            </p>
          </div>
        </div>

        {missingConfig ? (
          <div className="space-y-3 text-sm" style={{ color: '#5d625a' }}>
            <p>Set `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` in your environment, then restart the dev server.</p>
            <p className="text-xs" style={{ color: '#91968e' }}>{authError?.message}</p>
          </div>
        ) : sent && useCode ? (
          <form onSubmit={handleVerify} className="space-y-3">
            <div className="flex items-start gap-3 rounded-xl border p-3" style={{ borderColor: '#d9e4a2', background: 'rgba(200,224,0,0.08)' }}>
              <CheckCircle2 size={18} style={{ color: '#8ea400' }} />
              <p className="text-sm" style={{ color: '#343831' }}>Enter the 6-digit code we emailed to {email.trim()}.</p>
            </div>
            <input
              type="text"
              inputMode="numeric"
              autoComplete="one-time-code"
              required
              value={code}
              onChange={event => setCode(event.target.value.replace(/\D/g, '').slice(0, 6))}
              placeholder="123456"
              className="w-full rounded-xl border px-4 py-3 text-sm text-center tracking-[0.5em] outline-none"
              style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
            />
            <button
              type="submit"
              disabled={verifying || code.length < 6}
              className="w-full rounded-xl px-4 py-3 text-sm font-bold flex items-center justify-center gap-2 disabled:opacity-60"
              style={{ background: ACCENT, color: '#141613' }}
            >
              {verifying ? <Loader2 size={16} className="animate-spin" /> : <CheckCircle2 size={16} />}
              Verify code
            </button>
            {error ? <p className="text-xs text-red-600">{error}</p> : null}
          </form>
        ) : sent ? (
          <div className="flex items-start gap-3 rounded-xl border p-3" style={{ borderColor: '#d9e4a2', background: 'rgba(200,224,0,0.08)' }}>
            <CheckCircle2 size={18} style={{ color: '#8ea400' }} />
            <p className="text-sm" style={{ color: '#343831' }}>Check your email for the sign-in link.</p>
          </div>
        ) : (
          <div className="space-y-2.5">
            <button
              type="button"
              disabled={!!oauthLoading}
              onClick={() => handleOAuth('apple')}
              className="w-full rounded-xl px-4 py-3 text-sm font-semibold flex items-center justify-center gap-2.5 disabled:opacity-60 transition-opacity"
              style={{ background: '#141613', color: '#ffffff' }}
            >
              {oauthLoading === 'apple'
                ? <Loader2 size={16} className="animate-spin" />
                : <Apple size={17} style={{ marginTop: -2 }} fill="#ffffff" />}
              Continue with Apple
            </button>

            <button
              type="button"
              disabled={!!oauthLoading}
              onClick={() => handleOAuth('google')}
              className="w-full rounded-xl px-4 py-3 text-sm font-semibold flex items-center justify-center gap-2.5 border disabled:opacity-60 transition-opacity"
              style={{ background: '#ffffff', borderColor: '#dadce0', color: '#3c4043' }}
            >
              {oauthLoading === 'google'
                ? <Loader2 size={16} className="animate-spin" />
                : <GoogleLogo size={17} />}
              Continue with Google
            </button>

            {showEmail ? (
              <form onSubmit={handleEmailSubmit} className="space-y-2 pt-3">
                <input
                  type="email"
                  required
                  value={email}
                  onChange={event => setEmail(event.target.value)}
                  placeholder="you@example.com"
                  className="w-full rounded-xl border px-4 py-3 text-sm outline-none"
                  style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
                />
                <button
                  type="submit"
                  disabled={sending}
                  className="w-full rounded-xl px-4 py-3 text-sm font-bold flex items-center justify-center gap-2 disabled:opacity-60"
                  style={{ background: ACCENT, color: '#141613' }}
                >
                  {sending ? <Loader2 size={16} className="animate-spin" /> : <Mail size={16} />}
                  {useCode ? 'Send code' : 'Send sign-in link'}
                </button>
              </form>
            ) : (
              <button
                type="button"
                onClick={() => setShowEmail(true)}
                className="w-full pt-3 text-xs font-medium"
                style={{ color: '#91968e' }}
              >
                Or sign in with email
              </button>
            )}

            {error ? <p className="text-xs text-red-600 pt-1">{error}</p> : null}
          </div>
        )}

        <div className="flex items-center justify-center gap-3 pt-5 mt-4 border-t" style={{ borderColor: '#e8e1d4' }}>
          <Link to="/privacy" className="text-[11px] font-medium underline" style={{ color: '#91968e' }}>Privacy Policy</Link>
          <span className="text-[11px]" style={{ color: '#d9d1c2' }}>·</span>
          <Link to="/terms" className="text-[11px] font-medium underline" style={{ color: '#91968e' }}>Terms</Link>
        </div>
      </div>
    </div>
  );
}
