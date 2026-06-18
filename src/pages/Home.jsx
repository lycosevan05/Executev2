import { useState, useEffect, useCallback, useMemo } from 'react';
import { usePullToRefresh } from '@/hooks/usePullToRefresh';
import { Link, useNavigate } from 'react-router-dom';
import StarterProfileModal from '@/components/profile/StarterProfileModal';
import StarterResultScreen from '@/components/profile/StarterResultScreen';
import { motion, AnimatePresence } from 'framer-motion';
import {
  User, ChevronRight, Sparkles, Loader2, AlertCircle, RefreshCw,
  CalendarDays, Dumbbell, UtensilsCrossed, BatteryCharging, Play, Leaf, TrendingUp,
  SlidersHorizontal,
} from 'lucide-react';
import { backend } from '@/api/backendClient';
import GoalsCompleteAnimation from '@/components/home/GoalsCompleteAnimation';
import DailyChecklist from '@/components/home/DailyChecklist';
import CalorieBalanceCard from '@/components/home/CalorieBalanceCard';
import CustomizeWrapper from '@/components/customize/CustomizeWrapper';
import { usePageLayout } from '@/components/customize/usePageLayout';
import { useVitalsLayout } from '@/components/home/useVitalsLayout';
import VitalsRowWidget from '@/components/home/VitalsRowWidget';
import VitalsPicker from '@/components/home/VitalsPicker';
import { loadActiveAIPlan, userScopedFilter } from '@/lib/personalizationSync';
import { getOrCreateWorkoutPlanForDate } from '@/lib/plans/getOrCreateWorkoutPlanForDate';
import { refreshDynamicReadiness } from '@/lib/readinessScore';
import MacroTrackerCard from '@/components/home/MacroTrackerCard';
import { resolveCalorieTarget } from '@/lib/calorieGoal';
import ProgressSnapshotCard from '@/components/home/ProgressSnapshotCard';
import { appCache } from '@/lib/appCache';
import { useCacheHydrated } from '@/hooks/useCacheHydrated';
import { getPlanDaySessionTitle } from '@/lib/planDayDisplay';
import LogModal from '@/components/track/LogModal';
import { ALL_CATEGORIES } from '@/components/track/categories';
import { loadCustomTrackers } from '@/lib/customTrackers';
import { saveVitalLog, getDailyLogUpdatesForCategory } from '@/lib/vitalsLog';

const PAGE_KEY = 'home';
const HOME_CACHE_KEY = 'home-dashboard';
const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

function getTodayStr() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

function aggregateFoodLogs(foodLogs = []) {
  const logs = Array.isArray(foodLogs) ? foodLogs : [];
  return {
    hasFoodLogs: logs.length > 0,
    totals: {
      calories_consumed: logs.reduce((sum, log) => sum + (Number(log.total_calories) || 0), 0),
      protein_consumed_g: logs.reduce((sum, log) => sum + (Number(log.total_protein_g) || 0), 0),
      carbs_consumed_g: logs.reduce((sum, log) => sum + (Number(log.total_carbs_g) || 0), 0),
      fats_consumed_g: logs.reduce((sum, log) => sum + (Number(log.total_fats_g) || 0), 0),
    },
  };
}

const NON_TRAINING_TYPES = ['rest', 'recovery', 'mobility'];

function isRestDay(overviewDay) {
  if (!overviewDay) return false;
  if (overviewDay.day_type && NON_TRAINING_TYPES.includes(overviewDay.day_type)) return true;
  if (overviewDay.workout_needed === false) {
    const t = (overviewDay.training_type || '').toLowerCase();
    if (/\brest\b|\brecovery\b|\boff\b|\bmobility\b|\bstretch/.test(t)) return true;
  }
  return false;
}

// ─── Score card ───────────────────────────────────────────────────────────────

function ScoreCard({ label, score, maxScore = 100, caption, color = ACCENT }) {
  return (
    <div className="p-4 rounded-2xl border" style={{ background: '#ffffff', borderColor: '#e0d9cc', boxShadow: '0 2px 10px rgba(20,22,19,0.08)' }}>
      <p className="text-[10px] font-bold uppercase tracking-widest mb-2" style={{ color: '#a09a90' }}>{label}</p>
      {score != null ? (
        <>
          <div className="flex items-end gap-2 mb-1.5">
            <span className="text-2xl font-black" style={{ color: '#141613' }}>{Math.round(score)}</span>
            <span className="text-xs mb-0.5" style={{ color: '#91968e' }}>/{maxScore}</span>
          </div>
          <div className="h-1.5 rounded-full overflow-hidden" style={{ background: '#e8e1d4' }}>
            <motion.div className="h-full rounded-full" style={{ background: color }}
              initial={{ width: 0 }} animate={{ width: `${Math.min((score / maxScore) * 100, 100)}%` }}
              transition={{ duration: 1.2 }} />
          </div>
          {caption && <p className="text-[10px] mt-1.5 leading-tight" style={{ color: ACCENT_DARK }}>{caption}</p>}
        </>
      ) : (
        <p className="text-xs" style={{ color: '#91968e' }}>Not checked in today</p>
      )}
    </div>
  );
}

// ─── Today's Training card ────────────────────────────────────────────────────

function TrainingCard({ activePlan, overviewDay, workoutPlan, todayStr }) {
  const navigate = useNavigate();
  const rest = isRestDay(overviewDay);
  const sessionTitle = getPlanDaySessionTitle(overviewDay, "Today's workout");

  if (!activePlan) {
    return (
      <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}
        className="p-4 rounded-2xl border" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
        <p className="text-[10px] font-bold uppercase tracking-widest mb-1" style={{ color: '#91968e' }}>Training</p>
        <p className="text-sm font-semibold mb-3" style={{ color: '#141613' }}>No plan yet.</p>
        <button onClick={() => navigate('/plan?generate=true')}
          className="flex items-center gap-2 px-4 py-2.5 rounded-xl text-xs font-bold"
          style={{ background: ACCENT, color: '#141613' }}>
          <Sparkles size={12} /> Create my plan
        </button>
      </motion.div>
    );
  }

  if (rest) {
    return (
      <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}
        className="p-4 rounded-2xl border" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
        <div className="flex items-center justify-between mb-1">
          <p className="text-[10px] font-bold uppercase tracking-widest" style={{ color: '#91968e' }}>Training</p>
          <Leaf size={12} style={{ color: '#5d8a5d' }} />
        </div>
        <p className="text-sm font-bold mb-0.5" style={{ color: '#141613' }}>Recovery day</p>
        <p className="text-xs mb-3 leading-relaxed" style={{ color: '#5d635d' }}>
          {overviewDay?.recovery_focus || 'Focus on recovery today.'}
        </p>
        <button onClick={() => navigate(`/recovery?date=${todayStr}&source=home`)}
          className="flex items-center gap-2 px-4 py-2.5 rounded-xl text-xs font-bold border"
          style={{ borderColor: '#e8e1d4', background: '#f9f7f3', color: '#5d635d' }}>
          View recovery <ChevronRight size={11} />
        </button>
      </motion.div>
    );
  }

  if (workoutPlan) {
    return (
      <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}
        className="p-4 rounded-2xl border" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
        <div className="flex items-center justify-between mb-1">
          <p className="text-[10px] font-bold uppercase tracking-widest" style={{ color: '#91968e' }}>Training</p>
          <Dumbbell size={12} style={{ color: ACCENT_DARK }} />
        </div>
        <p className="text-sm font-bold mb-0.5" style={{ color: '#141613' }}>
          {workoutPlan.name || sessionTitle}
        </p>
        <p className="text-xs mb-3" style={{ color: '#5d635d' }}>
          {workoutPlan.workout_summary || workoutPlan.type || overviewDay?.priority || ''}
        </p>
        <button
          onClick={() => navigate(`/workouts?date=${todayStr}&planId=${workoutPlan.id}`)}
          className="flex items-center gap-2 px-4 py-2.5 rounded-xl text-xs font-bold"
          style={{ background: ACCENT, color: '#141613' }}>
          <Play size={12} /> View workout
        </button>
      </motion.div>
    );
  }

  // Training day but no workout built yet
  return (
    <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}
      className="p-4 rounded-2xl border" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
      <div className="flex items-center justify-between mb-1">
        <p className="text-[10px] font-bold uppercase tracking-widest" style={{ color: '#91968e' }}>Training</p>
        <Dumbbell size={12} style={{ color: ACCENT_DARK }} />
      </div>
      <p className="text-sm font-bold mb-0.5" style={{ color: '#141613' }}>
        {sessionTitle}
      </p>
      <p className="text-xs mb-3" style={{ color: '#5d635d' }}>
        {overviewDay?.priority || "Build today's workout from your plan."}
      </p>
      <button onClick={() => navigate(`/workouts?date=${todayStr}`)}
        className="flex items-center gap-2 px-4 py-2.5 rounded-xl text-xs font-bold"
        style={{ background: ACCENT, color: '#141613' }}>
        <Sparkles size={12} /> Build workout
      </button>
    </motion.div>
  );
}

// ─── Today's Nutrition card ───────────────────────────────────────────────────

function NutritionCard({ activePlan, mealPlan, overviewDay, todayStr }) {
  const navigate = useNavigate();

  if (!activePlan) {
    return (
      <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}
        className="p-4 rounded-2xl border" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
        <p className="text-[10px] font-bold uppercase tracking-widest mb-1" style={{ color: '#91968e' }}>Nutrition</p>
        <p className="text-sm font-semibold mb-3" style={{ color: '#141613' }}>No plan yet.</p>
        <button onClick={() => navigate('/plan?generate=true')}
          className="flex items-center gap-2 px-4 py-2.5 rounded-xl text-xs font-bold"
          style={{ background: ACCENT, color: '#141613' }}>
          <Sparkles size={12} /> Create my plan
        </button>
      </motion.div>
    );
  }

  if (mealPlan) {
    return (
      <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}
        className="p-4 rounded-2xl border" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
        <div className="flex items-center justify-between mb-1">
          <p className="text-[10px] font-bold uppercase tracking-widest" style={{ color: '#91968e' }}>Nutrition</p>
          <UtensilsCrossed size={12} style={{ color: ACCENT_DARK }} />
        </div>
        <p className="text-sm font-bold mb-0.5" style={{ color: '#141613' }}>Today's meals are ready</p>
        <p className="text-xs mb-3" style={{ color: '#5d635d' }}>
          {mealPlan.total_calories ? `${mealPlan.total_calories} kcal` : ''}
          {mealPlan.total_protein_g ? ` · ${mealPlan.total_protein_g}g protein` : ''}
        </p>
        <button
          onClick={() => navigate(`/nutrition?date=${todayStr}&planId=${mealPlan.id}`)}
          className="flex items-center gap-2 px-4 py-2.5 rounded-xl text-xs font-bold border"
          style={{ borderColor: '#e8e1d4', background: '#f9f7f3', color: '#5d635d' }}>
          View meals <ChevronRight size={11} />
        </button>
      </motion.div>
    );
  }

  // Plan exists but no meals built
  const nutritionFocus = overviewDay?.nutrition_focus || '';
  const planSummary = activePlan?.plan_summary || activePlan?.plan_payload?.plan_summary || {};
  const nutritionTargets = activePlan?.nutrition_targets || activePlan?.plan_payload?.nutrition_targets || {};
  const subtitle = nutritionFocus || (nutritionTargets.calories ? `Target: ${nutritionTargets.calories} kcal` : planSummary.nutrition_focus || 'Build meals from your nutrition targets.');

  return (
    <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}
      className="p-4 rounded-2xl border" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
      <div className="flex items-center justify-between mb-1">
        <p className="text-[10px] font-bold uppercase tracking-widest" style={{ color: '#91968e' }}>Nutrition</p>
        <UtensilsCrossed size={12} style={{ color: ACCENT_DARK }} />
      </div>
      <p className="text-sm font-bold mb-0.5" style={{ color: '#141613' }}>Build today's meals</p>
      <p className="text-xs mb-3" style={{ color: '#5d635d' }}>{subtitle}</p>
      <button onClick={() => navigate(`/nutrition?date=${todayStr}`)}
        className="flex items-center gap-2 px-4 py-2.5 rounded-xl text-xs font-bold"
        style={{ background: ACCENT, color: '#141613' }}>
        <Sparkles size={12} /> Build meals
      </button>
    </motion.div>
  );
}

// ─── Plan status hero banner ──────────────────────────────────────────────────

function PlanHeroBanner({ activePlan, overviewDay, personalizationSaved, onPersonalize, onShowInfo, planResolved }) {
  const navigate = useNavigate();

  if (!activePlan) {
    // Loading floor: until the durable cache has hydrated AND the first load has
    // settled, we don't yet know whether a plan exists — render a skeleton, never
    // the "Build my plan" CTA, so an existing plan can't flash the empty state.
    if (!planResolved) {
      return (
        <div className="p-4 rounded-2xl border space-y-3"
          style={{ background: 'rgba(200,224,0,0.07)', borderColor: 'rgba(200,224,0,0.3)' }}>
          <div className="h-3 w-24 rounded-full animate-pulse" style={{ background: 'rgba(142,164,0,0.25)' }} />
          <div className="h-10 w-full rounded-xl animate-pulse" style={{ background: 'rgba(200,224,0,0.18)' }} />
        </div>
      );
    }
    return (
      <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}
        className="p-4 rounded-2xl border space-y-2"
        style={{ background: 'rgba(200,224,0,0.07)', borderColor: 'rgba(200,224,0,0.3)' }}>
        <div className="flex items-center gap-2">
          <Sparkles size={12} style={{ color: ACCENT_DARK }} />
          <span className="text-[10px] font-bold uppercase tracking-widest" style={{ color: ACCENT_DARK }}>Get started</span>
        </div>
        <button onClick={() => navigate('/plan?generate=true')}
          className="w-full flex items-center justify-between px-4 py-3 rounded-xl text-sm font-bold whitespace-nowrap"
          style={{ background: ACCENT, color: '#141613' }}>
          <span>Build my Performance Plan</span>
          <ChevronRight size={14} />
        </button>
        {!personalizationSaved && (
          <button onClick={onShowInfo}
            className="w-full flex items-center justify-between px-4 py-2 rounded-xl text-xs font-semibold border"
            style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#5d635d' }}>
            <span>Calculate My Starting Targets</span>
            <ChevronRight size={12} />
          </button>
        )}
      </motion.div>
    );
  }

  const planSummary = activePlan?.plan_summary || activePlan?.plan_payload?.plan_summary || {};
  const priority = getPlanDaySessionTitle(overviewDay, overviewDay?.day_focus || planSummary?.primary_goal || '');
  const rest = isRestDay(overviewDay);
  const dayLabel = rest ? 'Recovery day' : overviewDay?.day_type === 'training' ? 'Training day' : overviewDay?.training_type ? 'Training day' : '';

  return (
    <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}
      className="p-4 rounded-2xl border"
      style={{ background: 'rgba(200,224,0,0.07)', borderColor: 'rgba(200,224,0,0.3)' }}>
      <div className="flex items-center justify-between mb-1">
        <div className="flex items-center gap-2">
          <Sparkles size={12} style={{ color: ACCENT_DARK }} />
          <span className="text-[10px] font-bold uppercase tracking-widest" style={{ color: ACCENT_DARK }}>Today's performance plan</span>
        </div>
        {dayLabel && (
          <span className="text-[10px] font-semibold px-2 py-0.5 rounded-full"
            style={{ background: rest ? '#f2efe7' : 'rgba(200,224,0,0.2)', color: rest ? '#91968e' : ACCENT_DARK }}>
            {dayLabel}
          </span>
        )}
      </div>
      {priority && <p className="text-sm font-semibold leading-snug" style={{ color: '#141613' }}>{priority}</p>}
    </motion.div>
  );
}

// ─── Main component ───────────────────────────────────────────────────────────

export default function Home() {
  const navigate = useNavigate();
  const [greeting, setGreeting] = useState('');
  const [loading, setLoading] = useState(false);
  // Warm-nav optimization: a populated in-memory STORE means we already have a
  // definitive plan/no-plan snapshot, so skip the floor on remount. On a true
  // cold launch STORE is still empty here (boot hydration is async) → false →
  // step in loadDashboard lifts it after whenHydrated().
  const [loadedOnce, setLoadedOnce] = useState(() => Boolean(appCache.get(HOME_CACHE_KEY)));
  const [refreshing, setRefreshing] = useState(false);
  const [loadError, setLoadError] = useState(false);
  const [showCelebration, setShowCelebration] = useState(false);
  const [isCustomizing, setIsCustomizing] = useState(false);
  const [activeVital, setActiveVital] = useState(null);
  const [showStarterProfile, setShowStarterProfile] = useState(false);
  const [starterResultData, setStarterResultData] = useState(null);
  const [personalizationSaved, setPersonalizationSaved] = useState(false);

  // Canonical data — hydrate immediately from in-memory cache so navigating
  // back to Home shows the previous state instantly while a fresh load runs
  // in the background. This eliminates the "forgets context on every switch" bug.
  const cached = appCache.get(HOME_CACHE_KEY) || {};
  const [activePlan, setActivePlan] = useState(cached.activePlan || null);
  const [overviewDay, setOverviewDay] = useState(cached.overviewDay || null);
  const [dailyLog, setDailyLog] = useState(cached.dailyLog || null);
  const [workoutPlan, setWorkoutPlan] = useState(cached.workoutPlan || null);
  const [mealPlan, setMealPlan] = useState(cached.mealPlan || null);
  const [readiness, setReadiness] = useState(cached.readiness || null);
  const [userProfile, setUserProfile] = useState(cached.userProfile || null);
  const [nutritionProfile, setNutritionProfile] = useState(cached.nutritionProfile || null);

  const layout = usePageLayout(PAGE_KEY);
  const vitals = useVitalsLayout();
  const todayStr = getTodayStr();

  // Resolve a tapped vital id to a Track category so the logger overlay can open
  // above Home (no route change). Custom trackers are included so their ids resolve.
  const allTrackCategories = useMemo(() => [...ALL_CATEGORIES, ...loadCustomTrackers()], []);

  const openVital = (id) => {
    const cat = allTrackCategories.find(c => c.id === id);
    if (cat) setActiveVital(cat);
  };

  const onVitalSave = async (val) => {
    const cat = activeVital;
    setActiveVital(null);
    if (!cat) return;
    // Instant optimistic merge from the in-memory dailyLog — zero reads, pre-await.
    const updates = getDailyLogUpdatesForCategory(cat.id, val, dailyLog);
    if (updates) setDailyLog(prev => ({ ...(prev || {}), ...updates }));
    // Authoritative write; the DailyLog subscription reconciles any drift.
    try {
      await saveVitalLog({ categoryId: cat.id, value: val });
    } catch {
      // swallow; Home stays usable, next authoritative reload corrects it
    }
  };

  // Loading floor: the empty-state CTA may only render once the durable cache
  // has hydrated AND the first load has settled. Until then we can't tell a
  // plan-less user from a not-yet-loaded one, so we show a skeleton.
  const cacheReady = useCacheHydrated();
  const planResolved = cacheReady && loadedOnce;

  useEffect(() => {
    const h = new Date().getHours();
    setGreeting(h < 12 ? 'Good morning' : h < 17 ? 'Good afternoon' : 'Good evening');
  }, []);

  useEffect(() => {
    window.dispatchEvent(new CustomEvent('execute:customize-mode', { detail: { active: isCustomizing } }));
    return () => {
      window.dispatchEvent(new CustomEvent('execute:customize-mode', { detail: { active: false } }));
    };
  }, [isCustomizing]);

  const loadDashboard = useCallback(async (silent = false) => {
    setLoadError(false);
    // The durable cache replays into appCache asynchronously at boot. Wait for it
    // so a cold launch reads the persisted plan instead of an empty cache, then
    // re-seed state (the useState initializers ran pre-hydration and saw null).
    await appCache.whenHydrated();
    // Capture the owning user; if an account switch lands while this load runs,
    // the late response must not write the new user's screen (Invariant 1).
    const uid = appCache.getActiveUid();
    const hydrated = appCache.get(HOME_CACHE_KEY);
    if (hydrated) {
      setActivePlan(hydrated.activePlan || null);
      setOverviewDay(hydrated.overviewDay || null);
      setDailyLog(hydrated.dailyLog || null);
      setWorkoutPlan(hydrated.workoutPlan || null);
      setMealPlan(hydrated.mealPlan || null);
      setReadiness(hydrated.readiness || null);
      setUserProfile(hydrated.userProfile || null);
      setNutritionProfile(hydrated.nutritionProfile || null);
      setPersonalizationSaved(Boolean(hydrated.userProfile?.profile_setup_completed || hydrated.userProfile?.plan_questionnaire_completed));
      // A cached HOME_CACHE_KEY snapshot is a definitive plan/no-plan answer
      // (activePlan may be null). Lift the loading floor now; the network fetch
      // below refreshes in the background (SWR). Only the first-ever launch, with
      // no cached entry, must wait for the network to learn plan existence.
      setLoadedOnce(true);
    }
    // If we have fresh cached data with a valid plan, skip the network round-trip entirely.
    // The longer TTL in appCache means this stays fresh across many tab switches.
    if (!silent && appCache.isFresh(HOME_CACHE_KEY) && appCache.get(HOME_CACHE_KEY)?.activePlan) {
      setLoading(false);
      setLoadedOnce(true);
      return;
    }
    try {
      // 1. Fire all independent fetches in parallel
      const [plan, userProfiles, readinessCheckins, nutritionProfiles, dailyLogs, foodLogs] = await Promise.all([
        loadActiveAIPlan('daily').catch(() => null),
        backend.entities.UserProfile.filter(await userScopedFilter(), '-updated_date', 1).catch(() => []),
        backend.entities.ReadinessCheckIn.filter(await userScopedFilter({ date: todayStr })).catch(() => []),
        backend.entities.NutritionProfile.filter(await userScopedFilter(), '-updated_date', 1).catch(() => []),
        backend.entities.DailyLog.filter(await userScopedFilter({ date: todayStr })).catch(() => []),
        backend.entities.FoodLog.filter(await userScopedFilter({ date: todayStr })).catch(() => []),
      ]);

      // Bail if the active user changed mid-fetch — don't paint stale data.
      if (appCache.getActiveUid() !== uid) { setLoading(false); setLoadedOnce(true); return; }

      const up = userProfiles?.[0] || null;
      const baseLog = dailyLogs?.[0] || null;
      const foodLogTotals = aggregateFoodLogs(foodLogs);
      const log = foodLogTotals.hasFoodLogs
        ? { ...(baseLog || { date: todayStr }), ...foodLogTotals.totals }
        : baseLog;

      setActivePlan(plan || null);
      setUserProfile(up);
      setNutritionProfile(nutritionProfiles?.[0] || null);
      setPersonalizationSaved(Boolean(up?.profile_setup_completed || up?.plan_questionnaire_completed));
      setReadiness(readinessCheckins?.[0] || null);
      setDailyLog(log);

      // 2. Extract today's overview day
      if (plan) {
        const weeklyOverview = plan.weekly_overview || plan.plan_payload?.weekly_overview || null;
        setOverviewDay(weeklyOverview?.days?.find(d => d.date === todayStr) || null);
      }

      // 3. Load linked workout + meal plan from canonical helpers so Home and Train always agree
      const [wpResult, mpResult] = await Promise.all([
        getOrCreateWorkoutPlanForDate(todayStr, { planId: log?.planned_workout_id, generate: false, masterPlan: plan || undefined })
          .catch(() => null),
        log?.planned_meal_plan_id
          ? backend.entities.MealPlan.filter(await userScopedFilter({ id: log.planned_meal_plan_id })).catch(() => []).then(r => r?.[0] || null)
          : plan
            ? backend.entities.MealPlan.filter(await userScopedFilter({ date: todayStr, source_plan_id: plan.id })).catch(() => []).then(r => r?.[0] || null)
            : backend.entities.MealPlan.filter(await userScopedFilter({ date: todayStr })).catch(() => []).then(r => r?.[0] || null),
      ]);
      // Re-check after the second round-trip: a switch may have landed since.
      if (appCache.getActiveUid() !== uid) { setLoading(false); setLoadedOnce(true); return; }

      const finalWorkoutPlan = wpResult?.status === 'ready' ? wpResult.workoutPlan : null;
      setWorkoutPlan(finalWorkoutPlan);
      setMealPlan(mpResult);

      // Also persist the plan independently so Plan page and other consumers get it instantly
      if (plan) appCache.set('ai-plan:daily', plan);

      // Persist to cache so the next mount hydrates instantly
      appCache.set(HOME_CACHE_KEY, {
        activePlan: plan || null,
        overviewDay: plan ? ((plan.weekly_overview || plan.plan_payload?.weekly_overview)?.days?.find(d => d.date === todayStr) || null) : null,
        dailyLog: log,
        workoutPlan: finalWorkoutPlan,
        mealPlan: mpResult,
        readiness: readinessCheckins?.[0] || null,
        userProfile: up,
        nutritionProfile: nutritionProfiles?.[0] || null,
      });
    } catch (e) {
      console.error('[Home] loadDashboard failed', e);
      setLoadError(true);
    } finally {
      setLoading(false);
      setLoadedOnce(true);
    }
  }, [todayStr]);

  useEffect(() => { loadDashboard(); }, [loadDashboard]);

  // Live-sync DailyLog changes (workout completion, calorie updates, food logging) without full reload
  useEffect(() => {
    let currentUserEmail = '';
    backend.auth.me().then(user => { currentUserEmail = user?.email || ''; }).catch(() => {});
    const unsub = backend.entities.DailyLog.subscribe((event) => {
      if (event.type === 'update' || event.type === 'create') {
        const log = event.data;
        if (!log || log.date !== getTodayStr() || (currentUserEmail && log.created_by !== currentUserEmail)) return;
        appCache.invalidate(HOME_CACHE_KEY);
        setDailyLog(prev => ({ ...(prev || {}), ...log }));
        // Refresh readiness whenever daily log changes (workout done, calories, sleep, steps)
        refreshDynamicReadiness(getTodayStr()).then(result => {
          setReadiness(prev => prev ? { ...prev, readiness_score: result.score, energy: prev.energy } : { readiness_score: result.score, date: getTodayStr() });
        }).catch(() => {});
      }
    });
    return unsub;
  }, []);

  // Live-sync FoodLog changes so calorie and macro rings update immediately
  useEffect(() => {
    let currentUserEmail = '';
    backend.auth.me().then(user => { currentUserEmail = user?.email || ''; }).catch(() => {});
    const unsub = backend.entities.FoodLog.subscribe((event) => {
      const log = event.data;
      if (!log || log.date !== getTodayStr() || (currentUserEmail && log.created_by !== currentUserEmail)) return;
      backend.entities.FoodLog.filter({ date: getTodayStr() }).then(foodLogs => {
        const foodLogTotals = aggregateFoodLogs(foodLogs);
        setDailyLog(prev => ({ ...(prev || { date: getTodayStr() }), ...foodLogTotals.totals }));
      }).catch(() => {});
    });
    return unsub;
  }, []);

  // Also live-sync ReadinessCheckIn so home score updates after check-in
  useEffect(() => {
    let currentUserEmail = '';
    backend.auth.me().then(user => { currentUserEmail = user?.email || ''; }).catch(() => {});
    const unsub = backend.entities.ReadinessCheckIn.subscribe((event) => {
      if (event.type === 'update' || event.type === 'create') {
        const rec = event.data;
        if (!rec || rec.date !== getTodayStr() || (currentUserEmail && rec.created_by !== currentUserEmail)) return;
        setReadiness(prev => ({ ...(prev || {}), ...rec }));
      }
    });
    return unsub;
  }, []);

  const refresh = useCallback(() => {
    appCache.invalidate(HOME_CACHE_KEY);
    return loadDashboard();
  }, [loadDashboard]);

  const { containerRef: pullRef } = usePullToRefresh(async () => {
    setRefreshing(true);
    appCache.invalidate(HOME_CACHE_KEY);
    try { await loadDashboard(false); } finally { setRefreshing(false); }
  });

  // ── Derived display values ────────────────────────────────────────────────
  // Prefer UserProfile.display_name, then fall back to the questionnaire name
  // captured in the active AI plan so users who completed the questionnaire
  // but never set their profile still see a personalized greeting.
  const userName = userProfile?.display_name
    || activePlan?.plan_payload?.questionnaire?.name
    || '';
  // readiness_score is stored as 0–100 in the dynamic engine
  const readinessScore = readiness?.readiness_score ?? null;
  const readinessLabel =
    readinessScore == null ? null :
    readinessScore >= 75 ? 'High readiness — push today.' :
    readinessScore >= 50 ? 'Moderate readiness — train smart.' :
    'Low readiness — protect recovery.';

  const resolvedCalories = resolveCalorieTarget({ nutritionProfile, userProfile, activePlan });

  const vitalsToday = {
    steps: dailyLog?.steps || 0,
    steps_goal: userProfile?.step_goal_daily || 10000,
    calories_consumed: dailyLog?.calories_consumed || 0,
    calories_goal: resolvedCalories.calories,
    water_liters: dailyLog?.water_liters || 0,
    water_goal: userProfile?.water_goal_liters || 2.5,
    sleep_hours: dailyLog?.sleep_hours || 0,
    sleep_goal: userProfile?.sleep_goal_hours || 8,
    protein_consumed_g: dailyLog?.protein_consumed_g || 0,
  };

  // Workout quick-link route
  const rest = isRestDay(overviewDay);
  const workoutRoute = rest
    ? `/recovery?date=${todayStr}&source=home`
    : workoutPlan
      ? `/workouts?date=${todayStr}&planId=${workoutPlan.id}`
      : `/workouts?date=${todayStr}`;

  const nutritionRoute = mealPlan
    ? `/nutrition?date=${todayStr}&planId=${mealPlan.id}`
    : `/nutrition?date=${todayStr}`;

  // ── Widget content ────────────────────────────────────────────────────────
  const widgetContent = {
    ai_summary: (
      <motion.div initial={{ opacity: 0, y: 12 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.03 }}>
        <PlanHeroBanner activePlan={activePlan} overviewDay={overviewDay} personalizationSaved={personalizationSaved} planResolved={planResolved} onPersonalize={() => setShowStarterProfile(true)} onShowInfo={() => setShowStarterProfile(true)} />
      </motion.div>
    ),

    calorie_balance: (() => {
      const resolved = resolveCalorieTarget({ nutritionProfile, userProfile, activePlan });
      return (
        <CalorieBalanceCard
          caloriesConsumed={dailyLog?.calories_consumed || 0}
          caloriesBurned={dailyLog?.calories_burned || 0}
          calorieGoal={resolved.calories}
          calorieGoalSource={resolved.source}
        />
      );
    })(),

    macro_tracker: (
      <MacroTrackerCard
        dailyLog={dailyLog}
        nutritionProfile={nutritionProfile}
        activePlan={activePlan}
        mealPlan={mealPlan}
        userProfile={userProfile}
      />
    ),

    score_row: (
      <motion.div initial={{ opacity: 0, y: 12 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.07 }}>
        {/* Readiness — full-width, tap to check in */}
        <button onClick={() => navigate('/recovery')} className="text-left w-full">
          <div className="p-4 rounded-2xl border" style={{ background: '#ffffff', borderColor: '#e0d9cc', boxShadow: '0 2px 10px rgba(20,22,19,0.08)' }}>
            <div className="flex items-center justify-between mb-2">
              <p className="text-[10px] font-bold uppercase tracking-widest" style={{ color: '#a09a90' }}>Readiness</p>
              {readinessScore != null && (
                <p className="text-[10px] font-semibold leading-tight" style={{ color: ACCENT_DARK }}>{readinessLabel?.split(' —')[0]}</p>
              )}
            </div>
            {readinessScore != null ? (
              <>
                <div className="flex items-end gap-2 mb-2">
                  <span className="text-3xl font-black" style={{ color: '#141613' }}>{Math.round(readinessScore)}</span>
                  <span className="text-xs mb-1" style={{ color: '#91968e' }}>/100</span>
                </div>
                <div className="h-2 rounded-full overflow-hidden" style={{ background: '#e8e1d4' }}>
                  <motion.div className="h-full rounded-full" style={{ background: ACCENT }}
                    initial={{ width: 0 }} animate={{ width: `${Math.min(readinessScore, 100)}%` }}
                    transition={{ duration: 1.2 }} />
                </div>
              </>
            ) : (
              <p className="text-xs font-semibold" style={{ color: ACCENT_DARK }}>Tap to check in →</p>
            )}
          </div>
        </button>
      </motion.div>
    ),

    vitals_row: (
      <VitalsRowWidget
        today={vitalsToday}
        vitals={vitals}
        isCustomizing={isCustomizing}
        onOpen={openVital}
      />
    ),

    today_plan: (
      <motion.div initial={{ opacity: 0, y: 12 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.1 }}
        className="rounded-2xl border overflow-hidden" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
        <div className="px-4 pt-4 pb-3 flex items-center justify-between" style={{ borderBottom: '1px solid #f2efe7' }}>
          <p className="text-[10px] font-bold uppercase tracking-widest" style={{ color: '#91968e' }}>Today's Actions</p>
          <Link to="/my-week" className="text-[10px] flex items-center gap-0.5" style={{ color: '#91968e' }}>
            Full week <ChevronRight size={10} />
          </Link>
        </div>
        <div className="px-4 py-3">
          <DailyChecklist onAllDone={() => setShowCelebration(true)} onItemToggled={refresh} />
        </div>
      </motion.div>
    ),

    progress_snapshot: <ProgressSnapshotCard />,

    top_action: null,

    quick_links: (
      <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} transition={{ delay: 0.2 }}
        className="space-y-2">
        {/* Training quick link — gated on planResolved so a pre-hydrate null
            plan can't flash "Build workout"/training styling before the real
            session (or "Recovery day") resolves. Mirrors PlanHeroBanner. */}
        {!planResolved ? (
          <button
            onClick={() => navigate(workoutRoute)}
            className="w-full flex items-center justify-between px-4 py-3.5 rounded-2xl"
            style={{ background: '#ffffff', color: '#141613', border: '1px solid #e0d9cc', boxShadow: '0 1px 6px rgba(20,22,19,0.07)' }}>
            <div className="flex items-center gap-3">
              <div className="w-8 h-8 rounded-xl animate-pulse" style={{ background: '#e8e1d4' }} />
              <div className="text-left space-y-1.5">
                <span className="block h-3 w-28 rounded animate-pulse" style={{ background: '#e8e1d4' }} />
                <span className="block h-2 w-20 rounded animate-pulse" style={{ background: '#eee7d9' }} />
              </div>
            </div>
            <Play size={14} style={{ opacity: 0.6 }} />
          </button>
        ) : (
          <button
            onClick={() => navigate(workoutRoute)}
            className="w-full flex items-center justify-between px-4 py-3.5 rounded-2xl"
            style={{
              background: rest ? '#ffffff' : ACCENT,
              color: '#141613',
              border: rest ? '1px solid #e0d9cc' : 'none',
              boxShadow: rest ? '0 1px 6px rgba(20,22,19,0.07)' : '0 5px 20px rgba(200,224,0,0.38), 0 2px 6px rgba(200,224,0,0.18)',
            }}>
            <div className="flex items-center gap-3">
              <div className="w-8 h-8 rounded-xl flex items-center justify-center"
                style={{ background: rest ? 'rgba(93,138,93,0.12)' : 'rgba(20,22,19,0.1)' }}>
                {rest
                  ? <Leaf size={15} style={{ color: '#5d8a5d' }} />
                  : <Dumbbell size={15} style={{ color: '#141613' }} />}
              </div>
              <div className="text-left">
                <p className="text-sm font-bold leading-tight">
                  {rest
                    ? 'Recovery day'
                    : workoutPlan
                      ? (workoutPlan.name || 'View workout')
                      : getPlanDaySessionTitle(overviewDay, 'Build workout')}
                </p>
                <p className="text-[10px] opacity-60">
                  {rest ? 'View recovery guidance' : workoutPlan ? 'Tap to view session' : 'Tap to build from your plan'}
                </p>
              </div>
            </div>
            <Play size={14} style={{ opacity: 0.6 }} />
          </button>
        )}

        {/* Secondary row */}
        <div className="grid grid-cols-3 gap-2">
          <button onClick={() => navigate(nutritionRoute)}
            className="flex flex-col items-center gap-1.5 py-3 rounded-xl border"
            style={{ background: '#ffffff', borderColor: '#e0d9cc', boxShadow: '0 1px 6px rgba(20,22,19,0.07)' }}>
            <UtensilsCrossed size={16} style={{ color: ACCENT_DARK }} />
            <span className="text-[10px] font-semibold" style={{ color: '#141613' }}>Nutrition</span>
            <span className="text-[9px]" style={{ color: '#91968e' }}>
              {!planResolved
                ? <span className="inline-block h-2 w-10 rounded animate-pulse align-middle" style={{ background: '#e8e1d4' }} />
                : mealPlan ? `${mealPlan.total_calories || '—'} kcal` : 'Build meals'}
            </span>
          </button>

          <Link to={`/recovery?date=${todayStr}&source=home`}
            className="flex flex-col items-center gap-1.5 py-3 rounded-xl border"
            style={{ background: '#ffffff', borderColor: '#e0d9cc', boxShadow: '0 1px 6px rgba(20,22,19,0.07)' }}>
            <BatteryCharging size={16} style={{ color: ACCENT_DARK }} />
            <span className="text-[10px] font-semibold" style={{ color: '#141613' }}>Recovery</span>
            <span className="text-[9px]" style={{ color: '#91968e' }}>
              {readinessScore != null ? `${readinessScore}/100` : 'Check in'}
            </span>
          </Link>

          <Link to="/my-week"
            className="flex flex-col items-center gap-1.5 py-3 rounded-xl border"
            style={{ background: '#ffffff', borderColor: '#e0d9cc', boxShadow: '0 1px 6px rgba(20,22,19,0.07)' }}>
            <CalendarDays size={16} style={{ color: ACCENT_DARK }} />
            <span className="text-[10px] font-semibold" style={{ color: '#141613' }}>My Week</span>
            <span className="text-[9px]" style={{ color: '#91968e' }}>Schedule</span>
          </Link>
        </div>
      </motion.div>
    ),
  };

  // ── Render ────────────────────────────────────────────────────────────────

  if (loadError) {
    return (
      <div className="fixed inset-0 flex flex-col items-center justify-center px-8 text-center" style={{ background: '#f6f2e8' }}>
        <AlertCircle size={28} style={{ color: '#b05a3a', marginBottom: 12 }} />
        <p className="text-base font-bold mb-2" style={{ color: '#141613' }}>Couldn't load your dashboard</p>
        <p className="text-sm mb-6" style={{ color: '#91968e' }}>Check your connection and try again.</p>
        <button onClick={loadDashboard}
          className="flex items-center gap-2 px-5 py-3 rounded-2xl text-sm font-bold"
          style={{ background: ACCENT, color: '#141613' }}>
          <RefreshCw size={14} /> Retry
        </button>
      </div>
    );
  }

  return (
    <div ref={pullRef} className="transition-transform transition-opacity" style={{ background: '#f6f2e8' }} data-customize-mode={isCustomizing}>
      <AnimatePresence>
        {refreshing && (
          <motion.div
            initial={{ opacity: 0, height: 0 }} animate={{ opacity: 1, height: 36 }} exit={{ opacity: 0, height: 0 }}
            className="flex items-center justify-center gap-2 overflow-hidden"
            style={{ background: '#f6f2e8' }}
          >
            <Loader2 size={14} className="animate-spin" style={{ color: ACCENT_DARK }} />
            <span className="text-xs font-medium" style={{ color: '#91968e' }}>Updating…</span>
          </motion.div>
        )}
      </AnimatePresence>
      <AnimatePresence>
        {showCelebration && <GoalsCompleteAnimation onDismiss={() => setShowCelebration(false)} />}

        {showStarterProfile && !starterResultData && (
          <StarterProfileModal
            onClose={() => setShowStarterProfile(false)}
            showIntroPopup={true}
            onSaved={(savedData) => {
              setPersonalizationSaved(true);
              setShowStarterProfile(false);
              setStarterResultData(savedData);
              refresh();
            }}
          />
        )}
        {starterResultData && (
          <StarterResultScreen
            savedData={starterResultData}
            onClose={() => setStarterResultData(null)}
          />
        )}
      </AnimatePresence>

      {/* Header */}
      <div className="pt-safe-header px-5 pb-5" style={{ background: 'rgba(251,248,241,0.95)', backdropFilter: 'blur(24px)', borderBottom: '1px solid #e8e1d4' }}>
        <div className="flex items-center justify-between gap-3">
          {/* Greeting + name */}
          <div className="min-w-0">
            <h1 className="text-xl font-black tracking-tight leading-none" style={{ color: '#141613' }}>
              {greeting}, {userName || 'Welcome'}
            </h1>
          </div>
          {/* Right: always-visible buttons */}
          <div className="flex items-center gap-3 flex-shrink-0">
            <button
              onClick={() => navigate('/progress')}
              className="w-12 h-12 rounded-full flex items-center justify-center border"
              style={{ background: '#ffffff', borderColor: '#e8e1d4', boxShadow: '0 1px 4px rgba(20,22,19,0.06)' }}
            >
              <TrendingUp size={18} style={{ color: '#5d635d' }} />
            </button>
            <button
              onClick={() => setIsCustomizing(!isCustomizing)}
              className="w-12 h-12 rounded-full flex items-center justify-center border transition-all"
              style={{ background: isCustomizing ? ACCENT : '#ffffff', borderColor: isCustomizing ? ACCENT : '#e8e1d4', boxShadow: isCustomizing ? '0 2px 8px rgba(200,224,0,0.2)' : '0 1px 4px rgba(20,22,19,0.06)' }}
            >
              <SlidersHorizontal size={18} style={{ color: isCustomizing ? '#141613' : '#5d635d' }} />
            </button>
            <Link to="/profile"
              className="w-12 h-12 rounded-full flex items-center justify-center border"
              style={{ background: '#ffffff', borderColor: '#e8e1d4', boxShadow: '0 1px 4px rgba(20,22,19,0.06)' }}>
              <User size={18} style={{ color: '#5d635d' }} />
            </Link>
          </div>
        </div>
      </div>

      <div className="px-5 pb-8 pt-5">
        <CustomizeWrapper
          pageKey={PAGE_KEY}
          layout={layout}
          isCustomizing={isCustomizing}
          onDone={() => setIsCustomizing(false)}
          onCancel={() => setIsCustomizing(false)}
          onStartCustomizing={() => setIsCustomizing(true)}
          widgetContent={widgetContent}
          className="space-y-4"
        />
        {isCustomizing && (
          <div className="mt-3">
            <VitalsPicker
              allVitals={vitals.allVitals}
              selectedIds={vitals.selectedIds}
              onToggle={vitals.toggle}
            />
          </div>
        )}
      </div>

      {/* Floating exit customize button */}
      <AnimatePresence>
        {isCustomizing && (
          <motion.div
            initial={{ opacity: 0, y: 16 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0, y: 16 }}
            className="fixed left-0 right-0 flex justify-center z-50 pointer-events-none"
            style={{ bottom: 'calc(env(safe-area-inset-bottom) + 4rem)' }}
          >
            <button
              onClick={() => { layout.commitSave(); setIsCustomizing(false); }}
              className="pointer-events-auto flex items-center gap-2 px-6 py-3 rounded-full text-sm font-semibold"
              style={{
                background: 'rgba(20,22,19,0.75)',
                backdropFilter: 'blur(12px)',
                color: '#ffffff',
                boxShadow: '0 4px 20px rgba(20,22,19,0.25)',
              }}
            >
              Done editing
            </button>
          </motion.div>
        )}
      </AnimatePresence>

      <AnimatePresence>
        {activeVital && (
          <LogModal
            category={activeVital}
            currentValue={undefined}
            onClose={() => setActiveVital(null)}
            onSave={onVitalSave}
          />
        )}
      </AnimatePresence>
    </div>
  );
}
