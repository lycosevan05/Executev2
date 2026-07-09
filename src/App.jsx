import { Toaster } from "@/components/ui/toaster"
import { QueryClientProvider } from '@tanstack/react-query'
import { queryClientInstance } from '@/lib/query-client'
import { BrowserRouter as Router, Route, Routes, Navigate, useNavigate, useLocation } from 'react-router-dom';
import { Component, useEffect, useRef, useState } from 'react';
import PageNotFound from './lib/PageNotFound';
import { AuthProvider, useAuth } from '@/lib/AuthContext';
import UserNotRegisteredError from '@/components/UserNotRegisteredError';
import AuthScreen from '@/components/AuthScreen';
import AppShell from './components/layout/AppShell';
import { backend } from '@/api/backendClient';
import { runMigrationIfNeeded, userScopedFilter, prewarmUserEmail, loadActivePlan, getTodayISODate } from '@/lib/personalizationSync';
import { useSubscription } from '@/hooks/useSubscription';
import { useCacheHydrated } from '@/hooks/useCacheHydrated';
import { appCache } from '@/lib/appCache';
import { isGenerating } from '@/lib/planGenerationState';

// Page imports
import Home from './pages/Home';
import Track from './pages/Track';
import Plan from './pages/Plan';
import Insights from './pages/Insights';
import Goals from './pages/Goals';
import Profile from './pages/Profile';
import Meals from './pages/Meals';
import Workouts from './pages/Workouts';
import Recovery from './pages/Recovery';
import Nutrition from './pages/Nutrition';
import Onboarding from './pages/Onboarding';
import LogFood from './pages/LogFood';
import MyWeek from './pages/MyWeek';
import WorkoutSession from './pages/WorkoutSession';
import TrackingHistoryPage from './pages/TrackingHistoryPage';
import PersonalizeQuestionnaire from './pages/PersonalizeQuestionnaire';
import Billing from './pages/Billing';
import Progress from './pages/Progress';
import PrivacyPolicy from './pages/PrivacyPolicy';
import Terms from './pages/Terms';


// Auto-resume: if user has an in-progress workout and isn't already on the session screen, redirect them
function sameValue(a, b) {
  return Boolean(a) && Boolean(b) && String(a) === String(b);
}

function newestFirst(a, b) {
  const aDate = a?.generated_at || a?.completed_at || a?.started_at || a?.updated_date || a?.created_date || '';
  const bDate = b?.generated_at || b?.completed_at || b?.started_at || b?.updated_date || b?.created_date || '';
  return String(bDate).localeCompare(String(aDate));
}

function chooseBestLinkedWorkoutPlan(plans = [], workoutLog = null) {
  const safePlans = Array.isArray(plans) ? plans.filter(Boolean).sort(newestFirst) : [];
  if (!safePlans.length) return null;

  if (workoutLog?.workout_plan_id) {
    const exact = safePlans.find(plan => sameValue(plan.id, workoutLog.workout_plan_id));
    if (exact) return exact;
  }

  if (workoutLog?.source_plan_id && workoutLog?.generation_batch_id) {
    const linked = safePlans.find(plan =>
      sameValue(plan.source_plan_id, workoutLog.source_plan_id) &&
      sameValue(plan.generation_batch_id, workoutLog.generation_batch_id)
    );
    if (linked) return linked;
  }

  if (workoutLog?.source_plan_id) {
    const sourceLinked = safePlans.find(plan => sameValue(plan.source_plan_id, workoutLog.source_plan_id));
    if (sourceLinked) return sourceLinked;
  }

  const canonical =
    safePlans.find(plan => plan.source === 'plan_questionnaire_overview') ||
    safePlans.find(plan => plan.plan_payload?.source === 'plan_questionnaire_overview') ||
    safePlans.find(plan => plan.source === 'plan_questionnaire_initial') ||
    safePlans.find(plan => plan.plan_payload?.source === 'plan_questionnaire_initial');
  if (canonical) return canonical;

  return safePlans.find(plan => Array.isArray(plan.exercises) && plan.exercises.length > 0) || safePlans[0] || null;
}

// Auto-resume: if user has an in-progress workout and isn't already on the session screen, redirect them
function useAutoResumeWorkout(isAuthenticated) {
  const navigate = useNavigate();
  const location = useLocation();
  const checked = useRef(false);

  useEffect(() => {
    if (!isAuthenticated || checked.current) return;
    if (location.pathname === '/workout-session') return;

    checked.current = true;

    const today = getTodayISODate();

    async function resumeWorkout() {
      const filter = await userScopedFilter({ date: today, status: 'in_progress' });
      const logs = await backend.entities.WorkoutLog
        .filter(filter)
        .catch(() => []);

      if (!logs.length) return;

      const sortedLogs = Array.isArray(logs) ? logs.filter(Boolean).sort(newestFirst) : [];
      const log = sortedLogs[0];
      // Only auto-resume if the workout was actually started by the user
      if (!log || !log.started_at) return;

      let planCandidates = [];

      if (log.workout_plan_id) {
        const exactPlans = await backend.entities.WorkoutPlan
          .filter({ id: log.workout_plan_id })
          .catch(() => []);
        planCandidates = planCandidates.concat(exactPlans);
      }

      if (log.source_plan_id && log.generation_batch_id) {
        const linkedPlans = await backend.entities.WorkoutPlan
          .filter({
            date: today,
            source_plan_id: log.source_plan_id,
            generation_batch_id: log.generation_batch_id,
          })
          .catch(() => []);
        planCandidates = planCandidates.concat(linkedPlans);
      }

      if (log.source_plan_id) {
        const sourceLinkedPlans = await backend.entities.WorkoutPlan
          .filter({
            date: today,
            source_plan_id: log.source_plan_id,
          })
          .catch(() => []);
        planCandidates = planCandidates.concat(sourceLinkedPlans);
      }

      const datePlans = await backend.entities.WorkoutPlan
        .filter({ date: today })
        .catch(() => []);

      planCandidates = planCandidates.concat(datePlans);

      const richPlan = chooseBestLinkedWorkoutPlan(planCandidates, log);
      const workout = richPlan || {
        name: log.workout_name || 'Workout',
        exercises: [],
        date: today,
        source_plan_id: log.source_plan_id || '',
        generation_batch_id: log.generation_batch_id || '',
        weekly_plan_id: log.weekly_plan_id || '',
      };

      navigate('/workout-session', {
        state: {
          workout,
          logId: log.id,
          startedAt: log.started_at,
          sourcePlanId: workout.source_plan_id || log.source_plan_id || '',
          generationBatchId: workout.generation_batch_id || log.generation_batch_id || '',
          weeklyPlanId: workout.weekly_plan_id || log.weekly_plan_id || '',
          resuming: true,
        },
        replace: true,
      });
    }

    resumeWorkout().catch(() => {});
  }, [isAuthenticated, location.pathname, navigate]);
}

// Detect native mobile app context (Supabase TestFlight / App Store wrapper)
function useIsMobileApp() {
  return typeof window !== 'undefined' && (
    window.navigator.standalone === true ||
    window.matchMedia('(display-mode: standalone)').matches ||
    /SupabaseApp|Execute/i.test(window.navigator.userAgent)
  );
}

// Lightweight full-area loading shown while the plan guard confirms plan existence.
function PlanGuardSkeleton() {
  return (
    <div className="flex items-center justify-center py-24" style={{ minHeight: '60vh' }}>
      <div className="w-5 h-5 border-2 rounded-full animate-spin" style={{ borderColor: '#e8e1d4', borderTopColor: '#c8e000' }} />
    </div>
  );
}

// Plan-exists invariant guard (paid-only flow). Wraps Home + Nutrition.
//
// A premium user must NEVER reach Home/Nutrition with no plan, because those
// screens resolve calorie/macro targets that would be empty. On a CONFIRMED
// no-plan negative we redirect to plain /plan (the Plan page owns the Retry vs.
// build-questionnaire decision — see plan §1).
//
// Crucially we must distinguish a TRUE no-plan negative from a not-yet-loaded
// cache: a bare appCache miss OR a bare loadActivePlan() null are BOTH ambiguous
// (loadActivePlan collapses network-error and authoritative-empty into null).
// So: cache hit = fast-path allow; cache miss = do our own AIPlan query and
// redirect ONLY on a successful empty result; fail-open (render) on any throw.
function PlanGuard({ children }) {
  const { isPremium, loading: subLoading } = useSubscription();
  const cacheReady = useCacheHydrated();
  const location = useLocation();

  const syncDecide = () => {
    if (subLoading || !cacheReady) return 'checking';
    // Not premium: paid-only gating doesn't apply here (questionnaire is
    // premium-gated downstream). Don't block the screen.
    if (!isPremium) return 'allow';
    // A generation in flight — never bounce a user mid-build.
    if (isGenerating()) return 'allow';
    // Fast-path POSITIVE: cache already holds a plan.
    const cachedPlan = appCache.get('ai-plan:daily') || appCache.get('plan-page')?.activePlan;
    return cachedPlan ? 'allow' : 'confirm';
  };

  const [decision, setDecision] = useState(syncDecide);

  useEffect(() => {
    let cancelled = false;
    const d = syncDecide();
    if (d !== 'confirm') {
      setDecision(d);
      return;
    }
    // Cache miss — require a CONFIRMED read before deciding. Do NOT trust null.
    setDecision('checking');
    (async () => {
      try {
        const filter = await userScopedFilter({ plan_type: 'daily', status: 'active' });
        const records = await backend.entities.AIPlan.filter(filter, '-generated_at');
        if (cancelled) return;
        const hasPlan = Array.isArray(records) && records.filter(Boolean).length > 0;
        setDecision(hasPlan ? 'allow' : 'redirect');
      } catch {
        // Query threw (network/429) — UNKNOWN, NOT a negative. Fail-open.
        if (!cancelled) setDecision('allow');
      }
    })();
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isPremium, subLoading, cacheReady, location.pathname]);

  if (decision === 'redirect') return <Navigate to="/plan" replace />;
  if (decision === 'allow') return children;
  return <PlanGuardSkeleton />;
}

const AuthenticatedApp = () => {
  const { isAuthenticated, isLoadingAuth, isLoadingPublicSettings, authError } = useAuth();
  const isMobileApp = useIsMobileApp();
  const location = useLocation();
  useAutoResumeWorkout(isAuthenticated);

  // Run one-time migration of localStorage data → Supabase entities
  // Also pre-warm critical caches on boot so first navigation is instant
  useEffect(() => {
    if (isAuthenticated) {
      // Fire and forget — these run in parallel and populate caches for all pages
      prewarmUserEmail().catch(() => {});
      loadActivePlan('daily').catch(() => {});
      runMigrationIfNeeded().catch(() => {});
    }
  }, [isAuthenticated]);

  // Public legal pages are reachable without authentication so links on the
  // sign-in screen (and the App Store metadata) always resolve. This check must
  // run AFTER all hooks above so render never calls fewer hooks (Rules of Hooks).
  if (location.pathname === '/privacy') return <PrivacyPolicy />;
  if (location.pathname === '/terms') return <Terms />;

  if (isLoadingPublicSettings || isLoadingAuth) {
    return (
      <div className="fixed inset-0 flex items-center justify-center" style={{ background: '#f6f2e8' }}>
        <div className="flex flex-col items-center gap-4">
          <div className="w-10 h-10 rounded-2xl flex items-center justify-center" style={{ background: 'rgba(200,224,0,0.1)', border: '1px solid rgba(200,224,0,0.25)' }}>
            <div className="w-5 h-5 border-2 rounded-full animate-spin" style={{ borderColor: '#e8e1d4', borderTopColor: '#c8e000' }} />
          </div>
          <p className="text-xs" style={{ color: '#91968e' }}>Loading Execute…</p>
        </div>
      </div>
    );
  }

  if (authError) {
    if (authError.type === 'user_not_registered') {
      return <UserNotRegisteredError />;
    } else if (authError.type === 'missing_config') {
      return <AuthScreen missingConfig />;
    } else if (authError.type === 'auth_required') {
      return <AuthScreen />;
    }
  }

  return (
    <AppShell>
      <Routes>
        <Route path="/" element={<PlanGuard><Home /></PlanGuard>} />
        <Route path="/home" element={<PlanGuard><Home /></PlanGuard>} />
        <Route path="/track" element={<Track />} />
        <Route path="/plan" element={<Plan />} />
        <Route path="/insights" element={<Insights />} />
        <Route path="/goals" element={<Goals />} />
        <Route path="/profile" element={<Profile />} />
        <Route path="/meals" element={<Meals />} />
        <Route path="/workouts" element={<Workouts />} />
        <Route path="/recovery" element={<Recovery />} />
        <Route path="/nutrition" element={<PlanGuard><Nutrition /></PlanGuard>} />
        <Route path="/onboarding" element={<Onboarding />} />
        <Route path="/log-food" element={<LogFood />} />
        <Route path="/my-week" element={<MyWeek />} />
        <Route path="/workout-session" element={<WorkoutSession />} />
        <Route path="/tracking-history" element={<TrackingHistoryPage />} />
        <Route path="/personalize" element={<PersonalizeQuestionnaire />} />
        <Route path="/billing" element={<Billing />} />
        <Route path="/progress" element={<Progress />} />
        <Route path="/privacy" element={<PrivacyPolicy />} />
        <Route path="/terms" element={<Terms />} />
        <Route path="*" element={<PageNotFound />} />
      </Routes>
    </AppShell>
  );
};

// Global unhandled promise-rejection logger. Without this a rejected promise in
// WKWebView vanishes silently; surfacing the reason makes Safari Web Inspector
// debugging possible. Registered once at module import.
window.addEventListener('unhandledrejection', (event) => {
  console.error('[unhandledrejection]', event.reason);
});

// Top-level error boundary. In WKWebView an uncaught render throw leaves a
// permanent white screen with no recovery, so we degrade to a branded fallback
// with a Reload button (window.location.reload reloads the bundled index.html —
// safe under Capacitor). componentDidCatch logs the full error + component stack
// so the throw is debuggable in Safari Web Inspector.
class ErrorBoundary extends Component {
  state = { hasError: false };

  static getDerivedStateFromError() {
    return { hasError: true };
  }

  componentDidCatch(error, info) {
    console.error('[ErrorBoundary]', error, info?.componentStack);
  }

  render() {
    if (this.state.hasError) {
      return (
        <div className="fixed inset-0 flex items-center justify-center px-6" style={{ background: '#f6f2e8' }}>
          <div className="flex flex-col items-center gap-3 text-center">
            <p className="text-base font-semibold" style={{ color: '#5d635d' }}>Something went wrong</p>
            <p className="text-xs" style={{ color: '#91968e' }}>Please reload to continue.</p>
            <button
              onClick={() => window.location.reload()}
              className="mt-2 px-5 py-2 rounded-xl text-sm font-semibold"
              style={{ background: '#c8e000', color: '#1a1c19' }}
            >
              Reload
            </button>
          </div>
        </div>
      );
    }
    return this.props.children;
  }
}

function App() {
  return (
    <AuthProvider>
      <QueryClientProvider client={queryClientInstance}>
        <ErrorBoundary>
          <Router>
            <AuthenticatedApp />
          </Router>
        </ErrorBoundary>
        <Toaster />
      </QueryClientProvider>
    </AuthProvider>
  )
}

export default App
