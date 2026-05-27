import { useEffect, useState } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { Trash2, AlertTriangle, Loader2 } from 'lucide-react';
import { backend } from '@/api/backendClient';

const LOCALSTORAGE_KEYS = [
  'execute_backend_personalization_migrated_v2',
  'evanlog_backend_personalization_migrated_v2', // legacy
  'execute_checklist_migrated_to_dailylog',
  'evanlog_checklist_migrated_to_dailylog', // legacy
  'execute_health_context',
  'evanlog_health_context', // legacy
  'execute_plan_profile',
  'evanlog_plan_profile', // legacy
  'execute_my_week_plan',
  'evanlog_my_week_plan', // legacy
  'execute_custom_checklist_items',
  'evanlog_custom_checklist_items', // legacy
  'execute_refine_chat',
  'evanlog_refine_chat', // legacy
  'execute_vitals_layout',
  'evanlog_vitals_layout', // legacy
  'execute_today_workout',
  'evanlog_today_workout', // legacy
  'execute_custom_trackers',
  'evanlog_custom_trackers', // legacy
];

export default function ResetAppDataButton() {
  const [showConfirm, setShowConfirm] = useState(false);
  const [resetting, setResetting] = useState(false);
  const [done, setDone] = useState(false);

  useEffect(() => {
    window.dispatchEvent(new CustomEvent('execute:blocking-overlay', { detail: { open: showConfirm } }));
    return () => window.dispatchEvent(new CustomEvent('execute:blocking-overlay', { detail: { open: false } }));
  }, [showConfirm]);

  const handleReset = async () => {
    setResetting(true);
    try {
      // Use the backend function which correctly deletes all user-scoped records
      await backend.functions.invoke('deleteUserData', {});

      // Clear localStorage migration flags
      LOCALSTORAGE_KEYS.forEach(key => localStorage.removeItem(key));

      // Also clear sessionStorage (appCache persists there)
      sessionStorage.clear();

      setDone(true);
      setShowConfirm(false);
      setTimeout(() => window.location.reload(), 1200);
    } catch {
      setResetting(false);
    }
  };

  if (done) {
    return (
      <div className="p-4 rounded-2xl border text-center text-sm font-semibold"
        style={{ background: 'rgba(200,224,0,0.08)', borderColor: 'rgba(200,224,0,0.3)', color: '#8ea400' }}>
        ✓ App reset — reloading…
      </div>
    );
  }

  return (
    <>
      <button
        onClick={() => setShowConfirm(true)}
        className="w-full flex items-center justify-center gap-2 py-3.5 rounded-2xl text-sm font-semibold border"
        style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#b05a3a' }}>
        <Trash2 size={14} />
        Reset App Data
      </button>

      {/* Confirmation modal */}
      <AnimatePresence>
        {showConfirm && (
          <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}
            className="fixed inset-0 z-50 flex items-end"
            style={{ background: 'rgba(20,22,19,0.4)' }}
            onClick={() => !resetting && setShowConfirm(false)}>
            <motion.div initial={{ y: '100%' }} animate={{ y: 0 }} exit={{ y: '100%' }}
              transition={{ type: 'spring', damping: 25, stiffness: 300 }}
              className="w-full max-w-md mx-auto rounded-t-3xl border-t border-l border-r p-6"
              style={{ background: '#fbf8f1', borderColor: '#e8e1d4', paddingBottom: 'calc(1.5rem + env(safe-area-inset-bottom))' }}
              onClick={e => e.stopPropagation()}>
              <div className="w-12 h-1 rounded-full mx-auto mb-5" style={{ background: '#d9d1c2' }} />
              <div className="flex items-center gap-3 mb-3">
                <div className="w-10 h-10 rounded-xl flex items-center justify-center flex-shrink-0"
                  style={{ background: 'rgba(176,90,58,0.1)' }}>
                  <AlertTriangle size={18} style={{ color: '#b05a3a' }} />
                </div>
                <div>
                  <p className="text-base font-bold" style={{ color: '#141613' }}>Reset all app data?</p>
                  <p className="text-xs" style={{ color: '#91968e' }}>This cannot be undone.</p>
                </div>
              </div>
              <p className="text-sm leading-relaxed mb-6" style={{ color: '#5d635d' }}>
                This will permanently delete all your plans, logs, workouts, meals, goals, and profile data — returning the app to a fresh install state.
              </p>
              <div className="flex flex-col gap-2">
                <button onClick={handleReset} disabled={resetting}
                  className="w-full flex items-center justify-center gap-2 py-3.5 rounded-2xl text-sm font-bold"
                  style={{ background: '#b05a3a', color: '#ffffff', opacity: resetting ? 0.7 : 1 }}>
                  {resetting ? <><Loader2 size={14} className="animate-spin" /> Resetting…</> : 'Yes, Reset Everything'}
                </button>
                <button onClick={() => setShowConfirm(false)} disabled={resetting}
                  className="w-full py-3.5 rounded-2xl text-sm font-semibold border"
                  style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#5d635d' }}>
                  Cancel
                </button>
              </div>
            </motion.div>
          </motion.div>
        )}
      </AnimatePresence>
    </>
  );
}