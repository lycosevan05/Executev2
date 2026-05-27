import { useState, useEffect, useRef } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import {
  Sparkles, Loader2, ClipboardList, MessageCircle, SlidersHorizontal,
  RefreshCw, ChevronRight, GitBranch, Compass, Dumbbell, UtensilsCrossed, Leaf, Trophy, Heart,
} from 'lucide-react';
import { useSearchParams, useNavigate } from 'react-router-dom';

import PlanQuestionnaire from '@/components/plan/PlanQuestionnaire';
import PremiumPaywall from '@/components/premium/PremiumPaywall';
import { useSubscription } from '@/hooks/useSubscription';
import AskQuestionsModal from '@/components/plan/AskQuestionsModal';
import RefinePlanModal from '@/components/plan/RefinePlanModal';
import PlanFocusCard from '@/components/plan/PlanFocusCard';
import PlanSegmentedTabs from '@/components/plan/PlanSegmentedTabs';
import WeeklyPlanPreview from '@/components/plan/WeeklyPlanPreview';
import PlanInsightCard from '@/components/plan/PlanInsightCard';
import EmptyPlanState from '@/components/plan/EmptyPlanState';
import PlanGeneratingOverlay from '@/components/plan/PlanGeneratingOverlay';
import StarterProfileModal from '@/components/profile/StarterProfileModal';

import { backend } from '@/api/backendClient';
import { loadActiveAIPlan, loadPlanQuestionnaireDefaults, getTodayISODate } from '@/lib/personalizationSync';
import { appCache } from '@/lib/appCache';
import {
  startGeneration, subscribeToGeneration, isGenerating, loadPendingAnswers, loadPendingStep, clearPendingAnswers,
} from '@/lib/planGenerationState';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

const PLAN_SECTIONS = [
  { key: 'training', label: 'Training', color: '#b05a3a' },
  { key: 'nutrition', label: 'Nutrition', color: '#8ea400' },
  { key: 'recovery', label: 'Recovery', color: '#5d8aa8' },
];

const LONG_TERM_SECTIONS = [
  { key: 'performance_direction', label: 'Your Performance Direction', icon: Compass, color: '#8ea400', accentBg: 'rgba(200,224,0,0.07)' },
  { key: 'training_narrative',    label: 'Training',                  icon: Dumbbell, color: '#b05a3a', accentBg: 'rgba(176,90,58,0.06)' },
  { key: 'nutrition_narrative',   label: 'Nutrition',                 icon: UtensilsCrossed, color: '#5d8a5d', accentBg: 'rgba(93,138,93,0.06)' },
  { key: 'recovery_narrative',    label: 'Recovery',                  icon: Leaf, color: '#5d8aa8', accentBg: 'rgba(93,138,168,0.06)' },
  { key: 'first_milestone',       label: 'First Milestone',           icon: Trophy, color: '#a07030', accentBg: 'rgba(160,112,48,0.06)' },
  { key: 'coaching_commitment',   label: 'Coaching Commitment',       icon: Heart, color: '#b05a3a', accentBg: 'rgba(176,90,58,0.04)' },
];

export default function Plan() {
  const [searchParams] = useSearchParams();
  const navigate = useNavigate();

  // UI state
  const [activeTab, setActiveTab] = useState('week');
  const [showProfile, setShowProfile] = useState(false);
  const [showQuestionnaire, setShowQuestionnaire] = useState(false);
  const [showStarterProfile, setShowStarterProfile] = useState(false);
  const [pendingQuestionnaire, setPendingQuestionnaire] = useState(false);
  const [showAskQuestions, setShowAskQuestions] = useState(false);
  const [showRefine, setShowRefine] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);

  // Hydrate instantly from cache — check both plan-page cache and the standalone ai-plan cache
  const cachedPlan = appCache.get('plan-page') || {};
  const cachedAIPlan = appCache.get('ai-plan:daily');
  // Prefer plan-page cache (has savedPlan etc) but fall back to ai-plan:daily for the plan itself
  const initialPlan = cachedPlan.activePlan || cachedAIPlan || null;

  // Data state
  const [activePlan, setActivePlan] = useState(initialPlan);
  const [activePlanId, setActivePlanId] = useState(cachedPlan.activePlanId || initialPlan?.id || null);
  const [savedPlan, setSavedPlan] = useState(cachedPlan.savedPlan || (initialPlan ? {
    training: initialPlan.summary || '',
    nutrition: initialPlan.nutrition_guidance || '',
    recovery: initialPlan.recovery_advice || '',
    savedAt: initialPlan.generated_at,
  } : null));
  const [readiness, setReadiness] = useState(cachedPlan.readiness || null);
  const [planLoading, setPlanLoading] = useState(!initialPlan);
  const [dailyPlan, setDailyPlan] = useState(null);
  const [lastGenerated, setLastGenerated] = useState(null);
  const [questionnaireAnswers, setQuestionnaireAnswers] = useState(null);
  const [profileQuestionnaireAnswers, setProfileQuestionnaireAnswers] = useState({});
  const [profileSkippedStepIds, setProfileSkippedStepIds] = useState([]);
  // When the user clicks "Refresh Plan" / "Regenerate Plan", we ALWAYS re-ask
  // how often they're training right now — activity changes over time, so this
  // question must never be skipped on a refresh, even if it was answered earlier.
  const [isRefreshFlow, setIsRefreshFlow] = useState(false);

  // Generation state
  const [generating, setGenerating] = useState(false);
  const [saveError, setSaveError] = useState(null);

  // Ref tracks the most recent plan id so async handlers (visibility,
  // mount-effect recovery) can detect when a newly-arrived plan is different
  // from what was on screen — without being captured by stale closures.
  const activePlanIdRef = useRef(activePlanId);
  useEffect(() => { activePlanIdRef.current = activePlanId; }, [activePlanId]);

  const todayStr = getTodayISODate();
  const { isPremium, loading: subLoading } = useSubscription();
  const [showPremiumPaywall, setShowPremiumPaywall] = useState(false);

  useEffect(() => {
    if (searchParams.get('generate') === 'true' && !subLoading) {
      isPremium ? setShowQuestionnaire(true) : setShowPremiumPaywall(true);
      // Clear the param so re-renders / sub-loading flips don't re-open the modal
      const url = new URL(window.location.href);
      url.searchParams.delete('generate');
      window.history.replaceState({}, '', url.toString());
    }
   
  }, [subLoading]);

  useEffect(() => {
    // Skip network entirely if cached plan is fresh
    if (appCache.isFresh('plan-page') && cachedPlan.activePlan) {
      setPlanLoading(false);
    } else {
      const load = async () => {
        if (!cachedPlan.activePlan) setPlanLoading(true);
        const [plan, readinessCheckins] = await Promise.all([
          loadActiveAIPlan().catch(() => null),
          backend.entities.ReadinessCheckIn.filter({ date: todayStr }).catch(() => []),
        ]);

        const saved = plan ? {
          training: plan.summary || '',
          nutrition: plan.nutrition_guidance || '',
          recovery: plan.recovery_advice || '',
          savedAt: plan.generated_at,
        } : null;
        const r = readinessCheckins?.[0] || null;

        if (plan) {
          setActivePlan(plan);
          setActivePlanId(plan.id);
          setSavedPlan(saved);
        }
        setReadiness(r);
        setPlanLoading(false);

        if (plan) appCache.set('ai-plan:daily', plan);
        appCache.set('plan-page', {
          activePlan: plan,
          activePlanId: plan?.id || null,
          savedPlan: saved,
          readiness: r,
        });
      };

      load();
    }
    loadPlanQuestionnaireDefaults().then(({ initialAnswers, completedStepIds }) => {
      setProfileQuestionnaireAnswers(initialAnswers || {});
      setProfileSkippedStepIds(completedStepIds || []);
    }).catch(() => {});
   
  }, []);

  const openQuestionnaire = ({ isRefresh = false } = {}) => {
    if (!isPremium) { setShowPremiumPaywall(true); return; }
    setIsRefreshFlow(isRefresh);
    setShowQuestionnaire(true);
  };
  const refreshPlan = () => openQuestionnaire({ isRefresh: true });

  // Shared handler for generation completion (single source of truth — only called via subscriber)
  const applyGenerationResult = (err, result) => {
    if (err) {
      const isRateLimit = err?.message?.includes('429') || err?.message?.includes('Rate limit');
      setSaveError(isRateLimit
        ? 'Too many requests — please wait a moment and try again.'
        : (err?.message || 'Something went wrong. Please try again.'));
      setGenerating(false);
      setShowQuestionnaire(false);
      return;
    }
    clearPendingAnswers();
    const plan = result.aiPlan || result.masterPlan;
    const saved = {
      training: plan.summary || plan.workout_suggestion || '',
      nutrition: plan.nutrition_guidance || '',
      recovery: plan.recovery_advice || '',
      savedAt: plan.generated_at,
    };
    setActivePlan(plan);
    setActivePlanId(plan.id);
    setSavedPlan(saved);
    setDailyPlan({ training: plan.summary || '', nutrition: plan.nutrition_guidance || '', recovery: plan.recovery_advice || '' });
    setLastGenerated(new Date());
    setGenerating(false);
    setActiveTab('longterm');
    // Keep plan-page appCache in sync so a navigate-away-and-back doesn't show stale data.
    // Note: upsertAdaptivePlan already populated 'ai-plan:daily' — do NOT bust it here.
    appCache.set('plan-page', {
      activePlan: plan,
      activePlanId: plan.id,
      savedPlan: saved,
      readiness,
    });
  };

  // Re-attach to an in-progress generation when this page mounts (user navigated away and came back)
  useEffect(() => {
    if (isGenerating()) {
      setGenerating(true);
      setShowQuestionnaire(false);
    } else if (loadPendingAnswers() && !subLoading && isPremium) {
      // User had questionnaire open and navigated away — restore it
      setShowQuestionnaire(true);
    }

    // Subscribe so we get notified when an in-progress generation (started before mount) finishes
    const unsub = subscribeToGeneration((err, result) => {
      applyGenerationResult(err, result);
    });

    // If a freshly-loaded plan is newer than what's currently shown, adopt it
    // and switch the user to the long-term tab — covers the case where
    // generation finished while the app was backgrounded.
    const adoptNewerPlan = (plan) => {
      if (!plan) return;
      const previousId = activePlanIdRef.current;
      setActivePlan(plan);
      setActivePlanId(plan.id);
      setSavedPlan({
        training: plan.summary || '',
        nutrition: plan.nutrition_guidance || '',
        recovery: plan.recovery_advice || '',
        savedAt: plan.generated_at,
      });
      if (previousId && plan.id !== previousId) {
        setActiveTab('longterm');
      }
    };

    // If not generating, reload plan from DB (covers: generation finished while app was backgrounded)
    if (!isGenerating()) {
      loadActiveAIPlan().then(plan => {
        if (plan && plan.id !== activePlanIdRef.current) {
          adoptNewerPlan(plan);
        }
        // If we had a pending generation but the promise is gone (app was killed/backgrounded),
        // clear the stale pending state so the UI doesn't get stuck
        if (!isGenerating() && loadPendingAnswers()) {
          clearPendingAnswers();
          setGenerating(false);
        }
      }).catch(() => {
        // Clear stuck generating state on error
        if (!isGenerating()) {
          clearPendingAnswers();
          setGenerating(false);
        }
      });
    }

    // On mobile, when app comes back from background, re-check generating state
    const handleVisibilityChange = () => {
      if (document.visibilityState === 'visible' && !isGenerating()) {
        clearPendingAnswers();
        setGenerating(false);
        // Reload plan in case it finished while backgrounded
        loadActiveAIPlan().then(plan => {
          if (plan && plan.id !== activePlanIdRef.current) {
            adoptNewerPlan(plan);
          }
        }).catch(() => {});
      }
    };

    document.addEventListener('visibilitychange', handleVisibilityChange);

    return () => {
      unsub();
      document.removeEventListener('visibilitychange', handleVisibilityChange);
    };
  }, []);

  const handleQuestionnaireSubmit = (answers) => {
    setQuestionnaireAnswers(answers);
    setShowQuestionnaire(false);
    setIsRefreshFlow(false);
    setSaveError(null);
    setGenerating(true);

    // Start generation, then subscribe immediately so we're guaranteed to be
    // attached before completion. Completion fires through the subscriber only.
    startGeneration(answers).catch(() => {});
    subscribeToGeneration((err, result) => applyGenerationResult(err, result));
  };

  // Effective skip list: on a refresh flow, never skip the "how often are you
  // training right now" step — activity may have changed since the user last
  // answered it.
  const effectiveSkipStepIds = isRefreshFlow
    ? profileSkippedStepIds.filter(id => id !== 'currentTraining')
    : profileSkippedStepIds;

  const handleStartToday = () => {
    if (activePlan) navigate('/workouts');
    else setShowQuestionnaire(true);
  };

  const hasPlan = Boolean(activePlan);

  return (
    <div style={{ background: '#f6f2e8' }}>
      {/* ── Modals ── */}
      <AnimatePresence>
        {showAskQuestions && <AskQuestionsModal onClose={() => setShowAskQuestions(false)} planContext={dailyPlan} />}
      </AnimatePresence>
      <AnimatePresence>
        {showRefine && (
          <RefinePlanModal
            onClose={() => setShowRefine(false)}
            plan={dailyPlan}
            onPlanUpdate={(updated) => { setDailyPlan(updated); setLastGenerated(new Date()); }}
          />
        )}
      </AnimatePresence>

      {/* ── Starter Profile Modal (shown before questionnaire for new users) ── */}
      <AnimatePresence>
        {showStarterProfile && (
          <StarterProfileModal
            onClose={() => {
              setShowStarterProfile(false);
              setPendingQuestionnaire(false);
            }}
            onSaved={() => {
              setShowStarterProfile(false);
              if (pendingQuestionnaire) {
                setPendingQuestionnaire(false);
                setShowQuestionnaire(true);
              }
            }}
          />
        )}
      </AnimatePresence>

      {/* ── Questionnaire overlay ── */}
      <AnimatePresence>
        {showPremiumPaywall && (
          <PremiumPaywall onClose={() => setShowPremiumPaywall(false)} context="AI plan generation requires Execute Premium" />
      )}
      {showQuestionnaire && (
          <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}
            className="fixed inset-0 z-50 overflow-y-auto" style={{ background: '#f6f2e8' }}>
            <div className="sticky top-0 z-10 flex items-center justify-between px-5 pb-4"
              style={{ paddingTop: 'max(3rem, calc(env(safe-area-inset-top) + 1rem))', background: 'rgba(246,242,232,0.97)', backdropFilter: 'blur(20px)', borderBottom: '1px solid #e8e1d4' }}>
              <div>
                <h2 className="text-lg font-bold" style={{ color: '#141613' }}>Personalize Your Plan</h2>
                <p className="text-xs" style={{ color: '#91968e' }}>Complete this to build your plan</p>
              </div>
              <button onClick={() => setShowQuestionnaire(false)}
                className="text-xs font-semibold px-3 py-2 rounded-xl border"
                style={{ borderColor: '#e8e1d4', color: '#5d635d', background: '#ffffff' }}>
                Cancel
              </button>
            </div>
            <div className="px-5 pb-40 pt-5">
              <PlanQuestionnaire
                onSubmit={handleQuestionnaireSubmit}
                initialAnswers={{ ...profileQuestionnaireAnswers, ...(loadPendingAnswers() || {}), ...(questionnaireAnswers || {}) }}
                skipStepIds={effectiveSkipStepIds}
                initialStep={loadPendingStep()}
              />
            </div>
          </motion.div>
        )}
      </AnimatePresence>

      {/* ── Plan Profile overlay ── */}
      <AnimatePresence>
        {showProfile && (
          <motion.div initial={{ opacity: 0, y: 40 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: 40 }}
            className="fixed inset-0 z-50 overflow-y-auto" style={{ background: '#f6f2e8' }}>
            <div className="sticky top-0 z-10 flex items-center justify-between px-5 pb-4"
              style={{ paddingTop: 'max(3rem, calc(env(safe-area-inset-top) + 1rem))', background: 'rgba(246,242,232,0.97)', backdropFilter: 'blur(20px)', borderBottom: '1px solid #e8e1d4' }}>
              <h2 className="text-lg font-bold" style={{ color: '#141613' }}>Plan Profile</h2>
              <button onClick={() => setShowProfile(false)}
                className="text-xs font-semibold px-3 py-2 rounded-xl border"
                style={{ borderColor: '#e8e1d4', color: '#5d635d', background: '#ffffff' }}>
                Close
              </button>
            </div>
            <div className="px-5 pb-24 pt-5 space-y-4">
              {!savedPlan ? (
                <div className="flex flex-col items-center py-20 text-center">
                  <p className="text-base font-bold mb-2" style={{ color: '#141613' }}>No saved plan yet</p>
                  <p className="text-sm leading-relaxed max-w-xs" style={{ color: '#91968e' }}>Generate a plan first.</p>
                </div>
              ) : (
                <>
                  {savedPlan.savedAt && (
                    <p className="text-[10px]" style={{ color: '#91968e' }}>
                      Saved {new Date(savedPlan.savedAt).toLocaleDateString('en-US', { month: 'long', day: 'numeric', year: 'numeric' })}
                    </p>
                  )}
                  {PLAN_SECTIONS.map((section, i) => (
                    <motion.div key={section.key} initial={{ opacity: 0, y: 10 }} animate={{ opacity: 1, y: 0 }}
                      transition={{ delay: i * 0.08 }} className="p-5 rounded-2xl border"
                      style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
                      <p className="text-xs font-bold uppercase tracking-widest mb-2" style={{ color: section.color }}>{section.label}</p>
                      <p className="text-sm leading-relaxed" style={{ color: '#2d2f2c' }}>{savedPlan[section.key]}</p>
                    </motion.div>
                  ))}
                  <button onClick={() => setShowAskQuestions(true)}
                    className="w-full flex items-center justify-center gap-2 py-3.5 rounded-2xl text-sm font-semibold border"
                    style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#5d635d' }}>
                    <MessageCircle size={14} /> Ask Questions
                  </button>
                  <button onClick={() => setShowRefine(true)}
                    className="w-full flex items-center justify-center gap-2 py-3.5 rounded-2xl text-sm font-semibold border"
                    style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#5d635d' }}>
                    <SlidersHorizontal size={14} /> Refine
                  </button>
                  <button onClick={() => { setShowProfile(false); refreshPlan(); }}
                    className="w-full flex items-center justify-center gap-2 py-3.5 rounded-2xl text-sm font-semibold border"
                    style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#5d635d' }}>
                    <RefreshCw size={14} /> New Plan From Scratch
                  </button>
                  {!confirmDelete ? (
                    <button onClick={() => setConfirmDelete(true)}
                      className="w-full flex items-center justify-center gap-2 py-3.5 rounded-2xl text-sm font-semibold border"
                      style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#b05a3a' }}>
                      Delete Current Plan
                    </button>
                  ) : (
                    <div className="p-4 rounded-2xl border" style={{ background: 'rgba(176,90,58,0.06)', borderColor: 'rgba(176,90,58,0.25)' }}>
                      <p className="text-sm font-semibold text-center mb-3" style={{ color: '#141613' }}>Are you sure you want to delete this plan?</p>
                      <div className="flex gap-3">
                        <button onClick={() => setConfirmDelete(false)}
                          className="flex-1 py-3 rounded-xl text-sm font-semibold border"
                          style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#5d635d' }}>
                          Cancel
                        </button>
                        <button onClick={async () => {
                          if (activePlanId) await backend.entities.AIPlan.delete(activePlanId).catch(() => {});
                          setSavedPlan(null); setActivePlan(null); setActivePlanId(null);
                          setConfirmDelete(false); setShowProfile(false);
                        }} className="flex-1 py-3 rounded-xl text-sm font-bold"
                          style={{ background: '#b05a3a', color: '#ffffff' }}>
                          Yes, Delete
                        </button>
                      </div>
                    </div>
                  )}
                </>
              )}
            </div>
          </motion.div>
        )}
      </AnimatePresence>

      {/* ── Header ── */}
      <div className="sticky top-0 z-40 px-5 pb-1"
        style={{ paddingTop: 'max(3rem, calc(env(safe-area-inset-top) + 1rem))', background: 'rgba(251,248,241,0.97)', backdropFilter: 'blur(24px)', borderBottom: '1px solid #ddd6c8', boxShadow: '0 2px 12px rgba(20,22,19,0.06)' }}>
        <div className="flex items-center justify-between">
          <div className="flex-1 min-w-0">
            <h1 className="text-lg font-black tracking-tight" style={{ color: '#141613' }}>Your Performance Plan</h1>
            <p className="text-xs mt-0.5 max-w-xs" style={{ color: '#91968e' }}>Adaptive guidance for training, recovery, and nutrition</p>
          </div>
          <motion.button
            whileTap={{ scale: 0.93 }}
            onClick={() => { setSaveError(null); refreshPlan(); }}
            disabled={generating}
            className="flex items-center gap-1.5 px-3.5 py-2 rounded-xl text-xs font-semibold border"
            style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#5d635d' }}
          >
            {generating ? <Loader2 size={12} className="animate-spin" /> : <Sparkles size={12} />}
            {generating ? 'Generating…' : 'Refresh Plan'}
          </motion.button>
        </div>
      </div>

      {/* ── Generating state ── */}
      <AnimatePresence mode="wait">
        {generating && <PlanGeneratingOverlay key="generating" />}
      </AnimatePresence>

      {/* ── Error banner ── */}
      <AnimatePresence>
        {saveError && !generating && (
          <motion.div initial={{ opacity: 0, y: -8 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }}
            className="mx-5 mt-4 p-3 rounded-2xl border text-sm flex items-center justify-between gap-3"
            style={{ background: 'rgba(176,90,58,0.07)', borderColor: 'rgba(176,90,58,0.25)', color: '#b05a3a' }}>
            <span>{saveError}</span>
            <button onClick={() => { setSaveError(null); refreshPlan(); }}
              className="text-xs font-bold underline flex-shrink-0">Retry</button>
          </motion.div>
        )}
      </AnimatePresence>

      {/* ── Main content ── */}
      <div className="px-5 pb-8 pt-5 space-y-4">

        {/* Loading skeleton */}
        {planLoading && (
          <div className="flex flex-col items-center py-20 gap-3">
            <Loader2 size={22} className="animate-spin" style={{ color: ACCENT_DARK }} />
            <p className="text-sm" style={{ color: '#91968e' }}>Loading your plan…</p>
          </div>
        )}

        {!planLoading && !hasPlan && !generating && (
          <EmptyPlanState onGenerate={openQuestionnaire} />
        )}

        {!planLoading && hasPlan && !generating && (
          <>
            {/* Focus card */}
            <PlanFocusCard
              activePlan={activePlan}
              readiness={readiness}
              onStartToday={handleStartToday}
              hasPlan={hasPlan}
            />

            {/* Segmented tabs */}
            <PlanSegmentedTabs activeTab={activeTab} onChange={setActiveTab} />

            {/* Tab: This Week */}
            <div>
              {activeTab === 'week' && (
                <motion.div key="week" initial={{ opacity: 0 }} animate={{ opacity: 1 }} transition={{ duration: 0.15 }}
                  className="space-y-4">
                  <WeeklyPlanPreview activePlan={activePlan} />
                  <PlanInsightCard
                    activePlan={activePlan}
                    onSeeAdjustments={() => setActiveTab('adjustments')}
                  />
                  {/* View Full Timeline */}
                  <motion.button
                    whileTap={{ scale: 0.98 }}
                    onClick={() => setActiveTab('longterm')}
                    className="w-full flex items-center justify-between px-5 py-4 rounded-2xl border"
                    style={{ background: '#ffffff', borderColor: '#e8e1d4', boxShadow: '0 2px 8px rgba(20,22,19,0.05)' }}
                  >
                    <div className="flex items-center gap-3">
                      <div className="w-9 h-9 rounded-xl flex items-center justify-center"
                        style={{ background: '#f2efe7' }}>
                        <GitBranch size={16} style={{ color: '#5d635d' }} />
                      </div>
                      <span className="text-sm font-semibold" style={{ color: '#141613' }}>View Full Timeline</span>
                    </div>
                    <ChevronRight size={16} style={{ color: '#91968e' }} />
                  </motion.button>
                </motion.div>
              )}

              {/* Tab: Long-Term */}
              {activeTab === 'longterm' && (
                <motion.div key="longterm" initial={{ opacity: 0 }} animate={{ opacity: 1 }} transition={{ duration: 0.15 }}
                  className="space-y-3">
                  {savedPlan ? (() => {
                    const ltp = activePlan?.plan_payload?.long_term_plan;
                    return (
                      <>
                        {savedPlan.savedAt && (
                          <p className="text-[10px]" style={{ color: '#91968e' }}>
                            Plan created {new Date(savedPlan.savedAt).toLocaleDateString('en-US', { month: 'long', day: 'numeric', year: 'numeric' })}
                          </p>
                        )}

                        {ltp ? (
                          // ── Rich personalized blueprint ──
                          LONG_TERM_SECTIONS.map((section, i) => {
                            const text = ltp[section.key];
                            if (!text) return null;
                            const Icon = section.icon;
                            return (
                              <motion.div key={section.key} initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}
                                transition={{ delay: i * 0.06 }}
                                className="p-5 rounded-2xl border"
                                style={{ background: section.accentBg, borderColor: '#e8e1d4' }}>
                                <div className="flex items-center gap-2 mb-2">
                                  <Icon size={13} style={{ color: section.color }} />
                                  <p className="text-[10px] font-bold uppercase tracking-widest" style={{ color: section.color }}>{section.label}</p>
                                </div>
                                <p className="text-sm leading-relaxed" style={{ color: '#2d2f2c' }}>{text}</p>
                              </motion.div>
                            );
                          })
                        ) : (
                          // ── Fallback: legacy sections ──
                          PLAN_SECTIONS.map((section, i) => (
                            <motion.div key={section.key} initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}
                              transition={{ delay: i * 0.07 }} className="p-5 rounded-2xl border"
                              style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
                              <p className="text-xs font-bold uppercase tracking-widest mb-2" style={{ color: section.color }}>{section.label}</p>
                              <p className="text-sm leading-relaxed" style={{ color: '#2d2f2c' }}>{savedPlan[section.key] || '—'}</p>
                            </motion.div>
                          ))
                        )}

                        <button onClick={() => setShowProfile(true)}
                          className="w-full flex items-center justify-center gap-2 py-3.5 rounded-2xl text-sm font-semibold border"
                          style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#5d635d' }}>
                          <ClipboardList size={14} /> Full Plan Profile
                        </button>
                      </>
                    );
                  })() : (
                    <div className="flex flex-col items-center py-16 text-center">
                      <p className="text-base font-bold mb-2" style={{ color: '#141613' }}>No long-term plan saved yet</p>
                      <button onClick={openQuestionnaire}
                        className="mt-4 px-6 py-3 rounded-2xl text-sm font-bold"
                        style={{ background: ACCENT, color: '#141613' }}>
                        Generate Plan
                      </button>
                    </div>
                  )}
                </motion.div>
              )}

              {/* Tab: Adjustments */}
              {activeTab === 'adjustments' && (
                <motion.div key="adjustments" initial={{ opacity: 0 }} animate={{ opacity: 1 }} transition={{ duration: 0.15 }}
                  className="space-y-3">
                  <div className="p-5 rounded-2xl border" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
                    <p className="text-sm font-bold mb-1" style={{ color: '#141613' }}>Refine your plan</p>
                    <p className="text-xs leading-relaxed mb-4" style={{ color: '#91968e' }}>
                      Ask questions, adjust intensity, or tune your nutrition and recovery guidance.
                    </p>
                    <div className="space-y-2">
                      <button onClick={() => setShowRefine(true)}
                        className="w-full flex items-center justify-center gap-2 py-3.5 rounded-2xl text-sm font-semibold border"
                        style={{ background: '#f9f7f3', borderColor: '#e8e1d4', color: '#5d635d' }}>
                        <SlidersHorizontal size={14} /> Adjust Plan
                      </button>
                      <button onClick={() => setShowAskQuestions(true)}
                        className="w-full flex items-center justify-center gap-2 py-3.5 rounded-2xl text-sm font-semibold border"
                        style={{ background: '#f9f7f3', borderColor: '#e8e1d4', color: '#5d635d' }}>
                        <MessageCircle size={14} /> Ask Questions
                      </button>
                      <button onClick={refreshPlan}
                        className="w-full flex items-center justify-center gap-2 py-3.5 rounded-2xl text-sm font-semibold border"
                        style={{ background: '#f9f7f3', borderColor: '#e8e1d4', color: '#5d635d' }}>
                        <RefreshCw size={14} /> Regenerate Plan
                      </button>
                    </div>
                  </div>
                </motion.div>
              )}
            </div>
          </>
        )}
      </div>
    </div>
  );
}