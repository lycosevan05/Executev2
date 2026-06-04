import { Toaster } from "@/components/ui/toaster"
import { QueryClientProvider } from '@tanstack/react-query'
import { queryClientInstance } from '@/lib/query-client'
import { BrowserRouter as Router, Route, Routes, useNavigate, useLocation } from 'react-router-dom';
import { useEffect, useRef, useState } from 'react';
import PageNotFound from './lib/PageNotFound';
import { AuthProvider, useAuth } from '@/lib/AuthContext';
import UserNotRegisteredError from '@/components/UserNotRegisteredError';
import AuthScreen from '@/components/AuthScreen';
import AppShell from './components/layout/AppShell';
import { backend } from '@/api/backendClient';
import { runMigrationIfNeeded, userScopedFilter, prewarmUserEmail, loadActivePlan, getTodayISODate } from '@/lib/personalizationSync';

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

const AuthenticatedApp = () => {
  const { isAuthenticated, isLoadingAuth, isLoadingPublicSettings, authError } = useAuth();
  const isMobileApp = useIsMobileApp();
  const location = useLocation();
  useAutoResumeWorkout(isAuthenticated);

  // Public legal pages are reachable without authentication so links on the
  // sign-in screen (and the App Store metadata) always resolve.
  if (location.pathname === '/privacy') return <PrivacyPolicy />;
  if (location.pathname === '/terms') return <Terms />;

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
        <Route path="/" element={<Home />} />
        <Route path="/home" element={<Home />} />
        <Route path="/track" element={<Track />} />
        <Route path="/plan" element={<Plan />} />
        <Route path="/insights" element={<Insights />} />
        <Route path="/goals" element={<Goals />} />
        <Route path="/profile" element={<Profile />} />
        <Route path="/meals" element={<Meals />} />
        <Route path="/workouts" element={<Workouts />} />
        <Route path="/recovery" element={<Recovery />} />
        <Route path="/nutrition" element={<Nutrition />} />
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

function App() {
  return (
    <AuthProvider>
      <QueryClientProvider client={queryClientInstance}>
        <Router>
          <AuthenticatedApp />
        </Router>
        <Toaster />
      </QueryClientProvider>
    </AuthProvider>
  )
}

export default App
