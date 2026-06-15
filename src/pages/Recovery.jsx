import { useState, useEffect } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { useSearchParams } from 'react-router-dom';
import { Plus, X, Sparkles, Loader2, ShieldCheck, AlertTriangle, Check, TrendingUp } from 'lucide-react';
import { backend } from '@/api/backendClient';
import { getUserAIContext } from '@/lib/aiContext';
import { createInjury, updateInjury, archiveInjury, upsertReadinessCheckIn, getTodayISODate } from '@/lib/personalizationSync';
import { refreshDynamicReadiness, getReadinessDrivers } from '@/lib/readinessScore';
import CustomizeButton from '@/components/customize/CustomizeButton';
import { usePageLayout } from '@/components/customize/usePageLayout';

const PAGE_KEY = 'recovery';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

function sameValue(a, b) {
  return Boolean(a) && Boolean(b) && String(a) === String(b);
}

function newestFirst(a, b) {
  const aDate = a?.generated_at || a?.updated_date || a?.created_date || '';
  const bDate = b?.generated_at || b?.updated_date || b?.created_date || '';
  return String(bDate).localeCompare(String(aDate));
}

function chooseBestLinkedRecord(records = [], masterPlan = null) {
  const safeRecords = Array.isArray(records) ? records.filter(Boolean).sort(newestFirst) : [];
  if (!safeRecords.length) return null;

  if (masterPlan) {
    const exact = safeRecords.find(record =>
      sameValue(record.source_plan_id, masterPlan.id) &&
      sameValue(record.generation_batch_id, masterPlan.generation_batch_id)
    );
    if (exact) return exact;

    const sourcePlanMatch = safeRecords.find(record => sameValue(record.source_plan_id, masterPlan.id));
    if (sourcePlanMatch) return sourcePlanMatch;
  }

  const canonical =
    safeRecords.find(record => record.source === 'plan_questionnaire_overview') ||
    safeRecords.find(record => record.plan_payload?.source === 'plan_questionnaire_overview') ||
    safeRecords.find(record => record.source === 'plan_questionnaire_initial') ||
    safeRecords.find(record => record.plan_payload?.source === 'plan_questionnaire_initial');
  if (canonical) return canonical;

  return safeRecords[0] || null;
}

async function loadActiveCanonicalMasterPlan() {
  const plans = await backend.entities.AIPlan
    .filter({ plan_type: 'daily', status: 'active' }, '-generated_at', 25)
    .catch(() => []);

  const sortedPlans = Array.isArray(plans) ? plans.filter(Boolean).sort(newestFirst) : [];

  return sortedPlans.find(plan => plan.source === 'plan_questionnaire_overview') ||
    sortedPlans.find(plan => plan.plan_payload?.source === 'plan_questionnaire_overview') ||
    sortedPlans.find(plan => plan.source === 'plan_questionnaire_initial') ||
    sortedPlans.find(plan => plan.plan_payload?.source === 'plan_questionnaire_initial') ||
    sortedPlans[0] ||
    null;
}

async function loadLinkedDailyLogForDate(date, masterPlan) {
  if (!date) return null;

  if (masterPlan?.id && masterPlan?.generation_batch_id) {
    const linkedLogs = await backend.entities.DailyLog.filter({
      date,
      source_plan_id: masterPlan.id,
      generation_batch_id: masterPlan.generation_batch_id,
    }).catch(() => []);

    const linkedLog = chooseBestLinkedRecord(linkedLogs, masterPlan);
    if (linkedLog) return linkedLog;
  }

  const dateLogs = await backend.entities.DailyLog.filter({ date }).catch(() => []);
  return chooseBestLinkedRecord(dateLogs, masterPlan);
}

function useInjuries() {
  const [injuries, setInjuries] = useState([]);
  const [loadingInjuries, setLoadingInjuries] = useState(true);

  useEffect(() => {
    backend.entities.InjuryProfile.list('-created_date', 30)
      .then(records => setInjuries(records))
      .catch(() => setInjuries([]))
      .finally(() => setLoadingInjuries(false));
  }, []);

  return { injuries, setInjuries, loadingInjuries };
}

const TABS = [
  { id: 'checkin', label: 'Check-In' },
  { id: 'injuries', label: 'Limitations' },
  { id: 'guidance', label: 'Guidance' },
];

const BODY_AREAS = ['Lower Back', 'Knee (Left)', 'Knee (Right)', 'Shoulder (Left)', 'Shoulder (Right)', 'Hip', 'Ankle', 'Wrist', 'Neck', 'Elbow', 'Hamstring', 'Calf', 'Other'];
const SEVERITY_OPTIONS = [
  { value: 'mild_discomfort', label: 'Mild discomfort', desc: 'Noticeable but not limiting' },
  { value: 'moderate_pain', label: 'Moderate pain', desc: 'Affects some movements' },
  { value: 'significant_pain', label: 'Significant pain', desc: 'Limits range of motion' },
  { value: 'movement_limited', label: 'Movement limited', desc: 'Cannot perform certain exercises' },
];



const CHECK_IN_FIELDS = [
  { key: 'energy', label: 'Energy Level', desc: '1 = drained · 10 = fully charged' },
  { key: 'soreness', label: 'Muscle Soreness', desc: '1 = none · 10 = very sore', inverted: true },
  { key: 'sleep', label: 'Sleep Quality', desc: '1 = poor · 10 = excellent' },
  { key: 'stress', label: 'Stress Level', desc: '1 = relaxed · 10 = very stressed', inverted: true },
  { key: 'motivation', label: 'Motivation to Train', desc: '1 = none · 10 = fired up' },
];

// Preview score from sliders only (1–10 scale → 0–100)
function getCheckinBaseScore(checkin) {
  const energy = checkin.energy;
  const soreness = 11 - checkin.soreness;
  const sleep = checkin.sleep;
  const stress = 11 - checkin.stress;
  const motivation = checkin.motivation;
  return Math.round(((energy + soreness + sleep + stress + motivation) / 5) * 10);
}

function getReadinessLabelLocal(score) {
  if (score >= 80) return { label: 'High readiness — push today', color: ACCENT_DARK, emoji: '💪' };
  if (score >= 65) return { label: 'Good readiness — train as planned', color: ACCENT_DARK, emoji: '🙂' };
  if (score >= 45) return { label: 'Moderate — adjust intensity down', color: '#b05a3a', emoji: '😐' };
  return { label: 'Low readiness — rest or easy movement', color: '#b05a3a', emoji: '😴' };
}

export default function Recovery() {
  // Support ?date=YYYY-MM-DD&source=my_week from My Week routing
  const [searchParams] = useSearchParams();
  const dateParam = searchParams.get('date');
  const sourceParam = searchParams.get('source');
  const isFromMyWeek = sourceParam === 'my_week';
  const targetDate = dateParam || getTodayISODate();

  const [activeTab, setActiveTab] = useState(isFromMyWeek ? 'guidance' : 'checkin');
  const [checkin, setCheckin] = useState({ energy: 7, soreness: 3, sleep: 7, stress: 3, motivation: 7 });
  const [submitted, setSubmitted] = useState(false);
  const [hydrating, setHydrating] = useState(true);
  const { injuries, setInjuries, loadingInjuries } = useInjuries();
  const [showAddInjury, setShowAddInjury] = useState(false);
  const [newInjury, setNewInjury] = useState({ area: '', severity: '', severityLabel: '', notes: '' });
  const [guidance, setGuidance] = useState(null);
  const [guidanceInputs, setGuidanceInputs] = useState(null);
  const [generatingGuidance, setGeneratingGuidance] = useState(false);
  const [isCustomizing, setIsCustomizing] = useState(false);
  const [plannedRecoveryTasks, setPlannedRecoveryTasks] = useState([]);
  const [completedRecoveryIds, setCompletedRecoveryIds] = useState([]);
  const [dailyLogId, setDailyLogId] = useState(null);
  const [planContext, setPlanContext] = useState(null);
  const [dynamicScore, setDynamicScore] = useState(null);
  const [dynamicBreakdown, setDynamicBreakdown] = useState(null);
  const [dailyLogForDrivers, setDailyLogForDrivers] = useState(null);
  const [workoutLogForDrivers, setWorkoutLogForDrivers] = useState(null);
  const layout = usePageLayout(PAGE_KEY);

  // Load dynamic readiness on mount
  useEffect(() => {
    const today = getTodayISODate();
    if (targetDate !== today) return; // only dynamic for today

    refreshDynamicReadiness(today).then(result => {
      setDynamicScore(result.score);
      setDynamicBreakdown(result.breakdown);
    }).catch(() => {});

    // Also load today's daily log + workout log for driver labels
    backend.entities.DailyLog.filter({ date: today }).then(logs => setDailyLogForDrivers(logs[0] || null)).catch(() => {});
    backend.entities.WorkoutLog.filter({ date: today, status: 'completed' }).then(logs => {
      const sorted = logs.sort((a, b) => (b.completed_at || '').localeCompare(a.completed_at || ''));
      setWorkoutLogForDrivers(sorted[0] || null);
    }).catch(() => {});
  }, [targetDate]);

  // Hydrate from an existing readiness check-in so a completed day opens on the
  // saved score + guidance instead of the blank data-entry form.
  useEffect(() => {
    let cancelled = false;
    setHydrating(true);

    backend.entities.ReadinessCheckIn.filter({ date: targetDate })
      .then(records => {
        if (cancelled) return;
        const record = records?.[0];
        if (!record) return;

        setCheckin(prev => ({
          energy: record.energy ?? prev.energy,
          soreness: record.soreness ?? prev.soreness,
          sleep: record.sleep_quality ?? prev.sleep,
          stress: record.stress ?? prev.stress,
          motivation: record.motivation ?? prev.motivation,
        }));
        setSubmitted(true);
        setGuidance(record.guidance ?? null);
        setGuidanceInputs(record.guidance_inputs ?? null);
        setActiveTab('guidance');
      })
      .catch(() => {})
      .finally(() => {
        if (!cancelled) setHydrating(false);
      });

    return () => {
      cancelled = true;
    };
  }, [targetDate]);

  // Load planned recovery tasks from the canonical DailyLog for this date.
  useEffect(() => {
    let cancelled = false;

    async function loadPlannedRecovery() {
      const activeMasterPlan = await loadActiveCanonicalMasterPlan();
      const linkedDailyLog = await loadLinkedDailyLogForDate(targetDate, activeMasterPlan);

      if (cancelled) return;

      setPlanContext(activeMasterPlan);
      setDailyLogId(linkedDailyLog?.id || null);
      setPlannedRecoveryTasks(linkedDailyLog?.planned_recovery_tasks || []);
      setCompletedRecoveryIds(linkedDailyLog?.plan_items_completed || []);
    }

    loadPlannedRecovery().catch(() => {
      if (!cancelled) {
        setPlanContext(null);
        setDailyLogId(null);
        setPlannedRecoveryTasks([]);
        setCompletedRecoveryIds([]);
      }
    });

    return () => {
      cancelled = true;
    };
  }, [targetDate]);

  // Preview score from sliders (shown before submitting)
  const previewScore = getCheckinBaseScore(checkin);
  // After submission, use dynamic score (includes workout/sleep/nutrition signals)
  const displayScore = submitted && dynamicScore != null ? dynamicScore : previewScore;
  const { label: readinessLabel, color: readinessColor, emoji } = getReadinessLabelLocal(displayScore);
  // Guidance is stale when the current sliders differ from the inputs it was generated from.
  const guidanceStale = Boolean(
    guidance && guidanceInputs &&
    CHECK_IN_FIELDS.some(field => checkin[field.key] !== guidanceInputs[field.key])
  );

  const generateGuidance = async () => {
    setGeneratingGuidance(true);
    const activeInjuries = injuries.filter(i => i.is_active !== false).map(i => `${i.body_area} (${(i.severity || '').replace(/_/g, ' ')})`).join(', ') || 'None';
    const aiContext = await getUserAIContext({ forceRefresh: true });
    const result = await backend.integrations.Core.InvokeLLM({
      prompt: `You are a world-class sports scientist and recovery specialist who has full visibility into this athlete's training load, biometrics, sleep, stress, nutrition, and injury history. Your recovery guidance must be so targeted it feels like a personalized medical-grade coaching report — minus any diagnosis.

${aiContext}

TODAY'S CHECK-IN:
- Energy: ${checkin.energy}/10
- Muscle Soreness: ${checkin.soreness}/10 (10 = extremely sore)
- Sleep Quality Last Night: ${checkin.sleep}/10
- Stress Level: ${checkin.stress}/10 (10 = very stressed)
- Motivation to Train: ${checkin.motivation}/10
- Calculated Readiness Score: ${previewScore}/100
- Active Physical Limitations: ${activeInjuries || 'None'}

YOUR TASK: Generate hyper-specific recovery guidance for today.

MANDATORY SPECIFICITY RULES:
1. Training recommendation: Be explicit — tell them exactly whether to train hard, train light (with specific % intensity reduction), do active recovery, or rest completely. Reference their specific recent workout history to justify the call (e.g. "You trained legs 2 days ago and soreness is 7/10 — another leg session today would compromise adaptation. Instead...")
2. Mobility exercises: Must be targeted to their specific active injury areas and the muscle groups trained recently. Include hold times, reps, and exactly WHY this exercise helps THEM (e.g. "Hip flexor 90/90 stretch — 3×45 sec per side — you sit long hours and your hip flexors are fighting your squat pattern")
3. Nutrition for recovery: Be specific with amounts — if they need protein, say exactly how much and when (e.g. "40g protein within 90 min of any training today — a casein-heavy source like cottage cheese or Greek yogurt before bed will maximize overnight muscle repair given your muscle gain goal")
4. Sleep/stress tip: Must be actionable and specific to their stress score today (if stress is 7+, give a concrete breathwork or wind-down protocol with exact timing, not just "get more sleep")
5. Motivating insight: Must reference their specific goal and show progress math (e.g. "You've hit 4/5 training days this week — one more consistent week puts you 30% closer to your strength target by the date you set")

ANTI-GENERIC RULES:
- Never say "rest and recover" without telling them exactly what to do during that rest
- Never recommend generic stretches — tie every mobility drill to a specific muscle group they've stressed
- Never give nutrition advice that ignores their dietary preference or macro targets
- Never give a motivating statement that could apply to any human being — make it specific to THIS person's goals, timeline, and recent data

Use safety language always: "guidance", "recommendation", "consider consulting a professional if pain persists". Never diagnose.`,
      response_json_schema: {
        type: 'object',
        properties: {
          training_recommendation: { type: 'string' },
          mobility_exercises: { type: 'array', items: { type: 'object', properties: { name: { type: 'string' }, duration: { type: 'string' }, benefit: { type: 'string' } } } },
          nutrition_focus: { type: 'string' },
          sleep_stress_tip: { type: 'string' },
          motivating_insight: { type: 'string' },
        }
      }
    });
    const inputsSnapshot = { ...checkin };
    setGuidance(result);
    setGuidanceInputs(inputsSnapshot);
    setGeneratingGuidance(false);

    upsertReadinessCheckIn(targetDate, { guidance: result, guidance_inputs: inputsSnapshot }).catch(() => {});
  };

  const handleSubmitCheckin = async () => {
    setSubmitted(true);
    setActiveTab('guidance');
    generateGuidance();

    const dateForCheckin = targetDate || getTodayISODate();

    await upsertReadinessCheckIn(dateForCheckin, {
      energy: checkin.energy,
      soreness: checkin.soreness,
      sleep_quality: checkin.sleep,
      stress: checkin.stress,
      motivation: checkin.motivation,
      readiness_score: previewScore,
      training_recommendation: '',
    }).catch(() => {});

    // Recompute dynamic score now that check-in is saved
    refreshDynamicReadiness(dateForCheckin).then(result => {
      setDynamicScore(result.score);
      setDynamicBreakdown(result.breakdown);
    }).catch(() => {});

    const activeMasterPlan = planContext || await loadActiveCanonicalMasterPlan();
    const linkedDailyLog = dailyLogId
      ? (await backend.entities.DailyLog.filter({ id: dailyLogId }).catch(() => []))[0]
      : await loadLinkedDailyLogForDate(dateForCheckin, activeMasterPlan);

    const dailyLogUpdates = {
      energy: checkin.energy,
      sleep_quality: checkin.sleep,
      recovery_score: previewScore,
    };

    if (linkedDailyLog?.id) {
      await backend.entities.DailyLog.update(linkedDailyLog.id, dailyLogUpdates).catch(() => {});
      setDailyLogId(linkedDailyLog.id);
    } else {
      const source =
        activeMasterPlan?.source ||
        activeMasterPlan?.plan_payload?.source ||
        'manual';
      const created = await backend.entities.DailyLog.create({
        date: dateForCheckin,
        source,
        source_plan_id: activeMasterPlan?.id || '',
        generation_batch_id: activeMasterPlan?.generation_batch_id || '',
        ...dailyLogUpdates,
      }).catch(() => null);

      if (created?.id) setDailyLogId(created.id);
    }

    if (activeMasterPlan && !planContext) {
      setPlanContext(activeMasterPlan);
    }
  };


  const addInjury = async () => {
    if (!newInjury.area || !newInjury.severity) return;
    const created = await createInjury({
      body_area: newInjury.area,
      severity: newInjury.severity,
      notes: newInjury.notes || '',
      is_active: true,
    }).catch(() => null);
    if (created) setInjuries(prev => [...prev, created]);
    setNewInjury({ area: '', severity: '', severityLabel: '', notes: '' });
    setShowAddInjury(false);
  };

  const toggleInjuryActive = async (injury) => {
    const newActive = !injury.is_active;
    setInjuries(prev => prev.map(i => i.id === injury.id ? { ...i, is_active: newActive } : i));
    await updateInjury(injury.id, { is_active: newActive }).catch(() => {});
  };

  const removeInjury = async (injury) => {
    setInjuries(prev => prev.filter(i => i.id !== injury.id));
    await archiveInjury(injury.id).catch(() => {});
  };

  return (
    <div className="min-h-screen" style={{ background: '#f6f2e8' }}>
      <div className="sticky top-0 z-40 px-5 pb-3" style={{ paddingTop: 'max(3rem, calc(env(safe-area-inset-top) + 1rem))', background: 'rgba(251,248,241,0.97)', backdropFilter: 'blur(24px)', borderBottom: '1px solid #ddd6c8', boxShadow: '0 2px 12px rgba(20,22,19,0.06)' }}>
        <div className="flex items-center justify-between mb-3">
          <div>
            <h1 className="text-lg font-bold tracking-tight" style={{ color: '#141613' }}>Recovery</h1>
            <p className="text-xs" style={{ color: '#91968e' }}>Adapt your training to how you feel today</p>
          </div>
          <CustomizeButton onCustomize={() => setIsCustomizing(prev => !prev)} isCustomizing={isCustomizing} />
        </div>
        <div className="flex gap-1">
          {TABS.map(tab => (
            <button key={tab.id} onClick={() => setActiveTab(tab.id)}
              className="flex-1 py-2 rounded-xl text-xs font-medium transition-all"
              style={{ background: activeTab === tab.id ? '#ffffff' : 'transparent', color: activeTab === tab.id ? '#141613' : '#a09a90', border: activeTab === tab.id ? '1px solid #ddd6c8' : '1px solid transparent', boxShadow: activeTab === tab.id ? '0 2px 8px rgba(20,22,19,0.09)' : 'none' }}>
              {tab.label}
            </button>
          ))}
        </div>
      </div>

      <div className="px-5 pb-32 pt-4">
        {hydrating ? (
          <div className="flex justify-center py-20">
            <Loader2 size={20} className="animate-spin" style={{ color: '#8ea400' }} />
          </div>
        ) : (
        <AnimatePresence mode="wait">

          {/* CHECK-IN */}
          {activeTab === 'checkin' && (
            <motion.div key="checkin" initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }} className="space-y-4">
              {!submitted ? (
                <>
                  <div className="p-5 rounded-2xl border space-y-5" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
                    <p className="text-xs font-bold uppercase tracking-widest" style={{ color: '#91968e' }}>Daily Readiness Check-In</p>
                    {CHECK_IN_FIELDS.map(field => (
                      <div key={field.key} className="space-y-1.5">
                        <div className="flex items-center justify-between">
                          <div>
                            <span className="text-sm font-medium" style={{ color: '#141613' }}>{field.label}</span>
                            <p className="text-[10px]" style={{ color: '#91968e' }}>{field.desc}</p>
                          </div>
                          <span className="text-base font-black" style={{ color: ACCENT_DARK }}>{checkin[field.key]}</span>
                        </div>
                        <input type="range" min={1} max={10} value={checkin[field.key]}
                          onChange={e => setCheckin(prev => ({ ...prev, [field.key]: Number(e.target.value) }))}
                          className="w-full" style={{ accentColor: ACCENT }} />
                      </div>
                    ))}
                  </div>

                  <div className="p-4 rounded-xl border" style={{ background: 'rgba(200,224,0,0.06)', borderColor: 'rgba(200,224,0,0.2)' }}>
                    <div className="flex items-center justify-between">
                      <span className="text-sm font-medium" style={{ color: '#141613' }}>Readiness Preview</span>
                      <span className="text-xl font-black" style={{ color: ACCENT_DARK }}>{previewScore}/100</span>
                    </div>
                    <p className="text-xs mt-1" style={{ color: readinessColor }}>{getReadinessLabelLocal(previewScore).label}</p>
                    <p className="text-[10px] mt-1.5" style={{ color: '#91968e' }}>Final score adjusts with sleep, steps, workout & nutrition logged today.</p>
                  </div>

                  <button onClick={handleSubmitCheckin}
                    className="w-full py-4 rounded-2xl text-sm font-bold flex items-center justify-center gap-2"
                    style={{ background: ACCENT, color: '#141613', boxShadow: '0 5px 20px rgba(200,224,0,0.38)' }}>
                    <Sparkles size={14} /> Save & Get Guidance
                  </button>
                </>
              ) : (
                <motion.div initial={{ opacity: 0, scale: 0.97 }} animate={{ opacity: 1, scale: 1 }} className="space-y-4">
                  <div className="p-6 rounded-2xl border text-center" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
                    <div className="text-4xl mb-3">{emoji}</div>
                    <p className="text-3xl font-black mb-1" style={{ color: ACCENT_DARK }}>{displayScore}/100</p>
                    <p className="text-sm font-semibold mb-1" style={{ color: '#141613' }}>{readinessLabel}</p>
                    <p className="text-xs mb-3" style={{ color: '#91968e' }}>
                      {dynamicScore != null ? 'Live score — updates as you log sleep, food, steps & workouts' : 'Based on today\'s check-in'}
                    </p>
                    {/* Dynamic drivers */}
                    {dynamicBreakdown && (() => {
                      const drivers = getReadinessDrivers(dynamicBreakdown, dailyLogForDrivers, workoutLogForDrivers);
                      if (!drivers.length) return null;
                      return (
                        <div className="space-y-1.5 text-left mb-3">
                          {drivers.map((d, i) => (
                            <div key={i} className="flex items-center gap-2 px-3 py-2 rounded-xl" style={{ background: '#f9f7f3' }}>
                              <TrendingUp size={11} style={{ color: ACCENT_DARK, flexShrink: 0 }} />
                              <p className="text-xs" style={{ color: '#5d635d' }}>{d}</p>
                            </div>
                          ))}
                        </div>
                      );
                    })()}
                    {/* Score breakdown mini-grid */}
                    {dynamicBreakdown && (
                    <div className="grid grid-cols-5 gap-1 mt-2 mb-3">
                      {[
                        { label: 'Check-In', val: Math.round((dynamicBreakdown.baseFromCheckin / 50) * 100), max: 100 },
                        { label: 'Sleep', val: dynamicBreakdown.sleepPoints, max: 20 },
                        { label: 'Nutrition', val: dynamicBreakdown.nutritionPoints, max: 20 },
                        { label: 'Workout', val: dynamicBreakdown.workoutAdj, max: 15, signed: true },
                        { label: dynamicBreakdown.timeOfDayLabel || 'Time', val: dynamicBreakdown.timeOfDayPoints ?? 0, max: 5, signed: true },
                      ].map(item => (
                          <div key={item.label} className="rounded-xl py-2.5 px-1 text-center" style={{ background: '#f2efe7' }}>
                            <p className="text-[10px] font-bold" style={{ color: item.signed && item.val > 0 ? ACCENT_DARK : item.signed && item.val < 0 ? '#b05a3a' : '#141613' }}>
                              {item.signed && item.val > 0 ? '+' : ''}{item.val}
                            </p>
                            <p className="text-[9px] mt-0.5" style={{ color: '#91968e' }}>{item.label}</p>
                          </div>
                        ))}
                      </div>
                    )}
                    <button onClick={() => setSubmitted(false)} className="text-xs underline" style={{ color: '#91968e' }}>Edit check-in</button>
                  </div>
                  <button onClick={() => setActiveTab('guidance')}
                    className="w-full py-3.5 rounded-2xl text-sm font-semibold border flex items-center justify-center gap-2"
                    style={{ borderColor: '#e8e1d4', color: '#141613', background: '#ffffff' }}>
                    View Recovery Guidance →
                  </button>
                </motion.div>
              )}
            </motion.div>
          )}

          {/* LIMITATIONS */}
          {activeTab === 'injuries' && (
            <motion.div key="injuries" initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }} className="space-y-4">
              <div className="p-3 rounded-xl border text-xs leading-relaxed" style={{ background: 'rgba(200,224,0,0.06)', borderColor: 'rgba(200,224,0,0.2)', color: '#91968e' }}>
                <ShieldCheck size={12} className="inline mr-1.5 align-middle" style={{ color: ACCENT_DARK }} />
                Logging limitations helps Execute tailor training around your current constraints.
              </div>

              {loadingInjuries && <div className="flex justify-center py-6"><Loader2 size={16} className="animate-spin" style={{ color: '#8ea400' }} /></div>}
              {injuries.map((injury, i) => (
                <motion.div key={injury.id || i} initial={{ opacity: 0, x: -8 }} animate={{ opacity: 1, x: 0 }} transition={{ delay: i * 0.07 }}
                  className="p-4 rounded-2xl border" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
                  <div className="flex items-start justify-between mb-2">
                    <div className="flex items-center gap-2.5 flex-1">
                      <div className="w-9 h-9 rounded-xl flex items-center justify-center flex-shrink-0" style={{ background: 'rgba(176,90,58,0.08)' }}>
                        <AlertTriangle size={15} style={{ color: '#b05a3a' }} />
                      </div>
                      <div>
                        <p className="text-sm font-semibold" style={{ color: '#141613' }}>{injury.body_area}</p>
                        <p className="text-xs mt-0.5" style={{ color: '#b05a3a' }}>{(injury.severity || '').replace(/_/g, ' ')}</p>
                      </div>
                    </div>
                    <div className="flex items-center gap-2 ml-2">
                      <button onClick={() => toggleInjuryActive(injury)}
                        className="text-[10px] px-2.5 py-1 rounded-full font-semibold"
                        style={{ background: injury.is_active !== false ? 'rgba(176,90,58,0.1)' : '#f2efe7', color: injury.is_active !== false ? '#b05a3a' : '#91968e' }}>
                        {injury.is_active !== false ? 'Active' : 'Resolved'}
                      </button>
                      <button onClick={() => removeInjury(injury)}>
                        <X size={14} style={{ color: '#d9d1c2' }} />
                      </button>
                    </div>
                  </div>
                  {injury.notes && <p className="text-xs leading-relaxed" style={{ color: '#91968e' }}>{injury.notes}</p>}
                  {injury.is_active !== false && (
                    <div className="mt-2 pt-2 border-t text-[10px]" style={{ borderColor: '#f2efe7', color: '#91968e' }}>
                      Workouts will automatically use lower-impact alternatives for this area.
                    </div>
                  )}
                </motion.div>
              ))}

              {!showAddInjury ? (
                <button onClick={() => setShowAddInjury(true)}
                  className="w-full flex items-center justify-center gap-2 py-3.5 rounded-2xl border border-dashed text-sm font-medium"
                  style={{ borderColor: '#d9d1c2', color: '#91968e' }}>
                  <Plus size={15} /> Add Limitation
                </button>
              ) : (
                <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}
                  className="p-4 rounded-2xl border space-y-4" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
                  <div className="flex items-center justify-between">
                    <h3 className="text-sm font-semibold" style={{ color: '#141613' }}>Add Limitation</h3>
                    <button onClick={() => setShowAddInjury(false)}><X size={15} style={{ color: '#91968e' }} /></button>
                  </div>

                  <div>
                    <p className="text-xs font-medium mb-2" style={{ color: '#91968e' }}>Body Area</p>
                    <div className="flex flex-wrap gap-2">
                      {BODY_AREAS.map(area => (
                        <button key={area} onClick={() => setNewInjury(prev => ({ ...prev, area }))}
                          className="px-3 py-1.5 rounded-full text-xs font-medium border transition-all"
                          style={{ background: newInjury.area === area ? 'rgba(200,224,0,0.12)' : '#f2efe7', borderColor: newInjury.area === area ? 'rgba(200,224,0,0.4)' : '#e8e1d4', color: newInjury.area === area ? ACCENT_DARK : '#5d635d' }}>
                          {area}
                        </button>
                      ))}
                    </div>
                  </div>

                  <div>
                    <p className="text-xs font-medium mb-2" style={{ color: '#91968e' }}>Severity</p>
                    <div className="space-y-2">
                      {SEVERITY_OPTIONS.map(s => (
                        <button key={s.value} onClick={() => setNewInjury(prev => ({ ...prev, severity: s.value, severityLabel: s.label }))}
                          className="w-full text-left px-3 py-3 rounded-xl border transition-all"
                          style={{ background: newInjury.severity === s.value ? 'rgba(200,224,0,0.08)' : '#f2efe7', borderColor: newInjury.severity === s.value ? 'rgba(200,224,0,0.3)' : '#e8e1d4' }}>
                          <p className="text-sm font-medium" style={{ color: '#141613' }}>{s.label}</p>
                          <p className="text-xs" style={{ color: '#91968e' }}>{s.desc}</p>
                        </button>
                      ))}
                    </div>
                  </div>

                  <textarea value={newInjury.notes} onChange={e => setNewInjury(prev => ({ ...prev, notes: e.target.value }))}
                    placeholder="Optional notes (e.g. aggravated by squatting, improves after warmup)"
                    rows={2} className="w-full p-3 rounded-xl border text-xs resize-none outline-none"
                    style={{ background: '#f2efe7', borderColor: '#e8e1d4', color: '#141613' }} />

                  <button onClick={addInjury} disabled={!newInjury.area || !newInjury.severity}
                    className="w-full py-3 rounded-xl text-sm font-bold"
                    style={{ background: newInjury.area && newInjury.severity ? ACCENT : '#e8e1d4', color: '#141613' }}>
                    Add Limitation
                  </button>
                </motion.div>
              )}
            </motion.div>
          )}

          {/* GUIDANCE */}
          {activeTab === 'guidance' && (
            <motion.div key="guidance" initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }} className="space-y-4">

              {/* My Week planned recovery tasks */}
              {plannedRecoveryTasks.length > 0 && (
                <div>
                  <p className="text-[10px] font-bold uppercase tracking-widest mb-3" style={{ color: '#91968e' }}>Planned Recovery Tasks</p>
                  {plannedRecoveryTasks.map(task => {
                    const isDone = completedRecoveryIds.includes(task.id);
                    return (
                      <motion.div key={task.id} initial={{ opacity: 0, y: 6 }} animate={{ opacity: 1, y: 0 }}
                        className="flex items-start gap-3 p-4 rounded-2xl border mb-2 transition-all"
                        style={{ background: isDone ? 'rgba(200,224,0,0.06)' : '#ffffff', borderColor: isDone ? 'rgba(200,224,0,0.3)' : '#e8e1d4' }}>
                        <button
                          onClick={async () => {
                            const { togglePlanItemComplete } = await import('@/lib/personalizationSync');
                            const result = await togglePlanItemComplete(targetDate, task.id, {
                              daily_log_id: dailyLogId,
                              source_plan_id: planContext?.id,
                              generation_batch_id: planContext?.generation_batch_id,
                            }).catch(() => null);
                            if (result) {
                              setCompletedRecoveryIds(result.newCompleted);
                            }
                          }}
                          className="w-6 h-6 rounded-full border-2 flex items-center justify-center flex-shrink-0 mt-0.5"
                          style={{ borderColor: isDone ? ACCENT_DARK : '#d9d1c2', background: isDone ? 'rgba(200,224,0,0.15)' : 'transparent' }}>
                          {isDone && <Check size={11} style={{ color: ACCENT_DARK }} />}
                        </button>
                        <div>
                          <p className="text-sm font-semibold" style={{ color: isDone ? '#91968e' : '#141613', textDecoration: isDone ? 'line-through' : 'none' }}>{task.title}</p>
                          <p className="text-xs mt-0.5" style={{ color: '#5d635d' }}>{task.description}</p>
                          {task.duration_minutes && <p className="text-[10px] mt-1" style={{ color: '#91968e' }}>{task.duration_minutes} min</p>}
                        </div>
                      </motion.div>
                    );
                  })}
                  <div className="h-px my-4" style={{ background: '#e8e1d4' }} />
                </div>
              )}

              {/* Prompt to check in if no readiness for this date */}
              {isFromMyWeek && !submitted && !guidance && (
                <div className="p-4 rounded-2xl border mb-2"
                  style={{ background: 'rgba(200,224,0,0.07)', borderColor: 'rgba(200,224,0,0.25)' }}>
                  <p className="text-xs font-bold mb-1" style={{ color: '#8ea400' }}>No readiness check-in for this day</p>
                  <p className="text-sm mb-3" style={{ color: '#5d635d' }}>Log how you feel to get personalized recovery guidance.</p>
                  <button onClick={() => setActiveTab('checkin')}
                    className="px-4 py-2 rounded-xl text-xs font-bold"
                    style={{ background: ACCENT, color: '#141613' }}>
                    Log Readiness
                  </button>
                </div>
              )}

              {generatingGuidance && (
                <div className="flex flex-col items-center py-16">
                  <motion.div className="w-14 h-14 rounded-2xl flex items-center justify-center mb-4"
                    style={{ background: 'rgba(200,224,0,0.1)', border: '1px solid rgba(200,224,0,0.25)' }}
                    animate={{ scale: [1, 1.05, 1] }} transition={{ repeat: Infinity, duration: 1.5 }}>
                    <Sparkles size={22} style={{ color: ACCENT_DARK }} />
                  </motion.div>
                  <p className="text-sm font-medium" style={{ color: '#141613' }}>Generating recovery guidance...</p>
                  <p className="text-xs mt-1" style={{ color: '#91968e' }}>Based on your check-in and limitations</p>
                </div>
              )}

              {!generatingGuidance && !guidance && (
                <div className="flex flex-col items-center py-16 text-center">
                  <div className="text-4xl mb-4">🧘</div>
                  <p className="text-sm font-medium mb-1" style={{ color: '#141613' }}>No guidance yet</p>
                  <p className="text-xs mb-5" style={{ color: '#91968e' }}>Complete today's check-in to get personalised recovery advice.</p>
                  <button onClick={() => setActiveTab('checkin')}
                    className="px-5 py-2.5 rounded-xl text-sm font-semibold"
                    style={{ background: ACCENT, color: '#141613' }}>
                    Go to Check-In
                  </button>
                </div>
              )}

              {guidanceStale && !generatingGuidance && (
                <div className="p-4 rounded-2xl border mb-4" style={{ background: 'rgba(176,90,58,0.07)', borderColor: 'rgba(176,90,58,0.25)' }}>
                  <p className="text-xs font-bold mb-1" style={{ color: '#b05a3a' }}>Inputs changed</p>
                  <p className="text-sm mb-3" style={{ color: '#5d635d' }}>Your check-in has been edited since this guidance was generated.</p>
                  <button onClick={generateGuidance}
                    className="px-4 py-2 rounded-xl text-xs font-bold flex items-center gap-2"
                    style={{ background: ACCENT, color: '#141613' }}>
                    <Sparkles size={13} /> Regenerate Guidance
                  </button>
                </div>
              )}

              {guidance && !generatingGuidance && (
                <div className="space-y-4" style={{ opacity: guidanceStale ? 0.5 : 1 }}>
                  <div className="p-4 rounded-2xl border" style={{ background: 'rgba(200,224,0,0.08)', borderColor: 'rgba(200,224,0,0.3)' }}>
                    <p className="text-[10px] font-bold uppercase tracking-widest mb-2" style={{ color: ACCENT_DARK }}>Training Today</p>
                    <p className="text-sm leading-relaxed font-medium" style={{ color: '#141613' }}>{guidance.training_recommendation}</p>
                  </div>

                  {guidance.mobility_exercises?.length > 0 && (
                    <div>
                      <p className="text-[10px] font-bold uppercase tracking-widest mb-3" style={{ color: '#91968e' }}>Mobility & Recovery</p>
                      {guidance.mobility_exercises.map((ex, i) => (
                        <div key={i} className="p-4 rounded-xl border mb-2" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
                          <div className="flex items-center justify-between mb-1">
                            <p className="text-sm font-semibold" style={{ color: '#141613' }}>{ex.name}</p>
                            <span className="text-xs" style={{ color: '#91968e' }}>{ex.duration}</span>
                          </div>
                          <p className="text-xs" style={{ color: '#5d635d' }}>{ex.benefit}</p>
                        </div>
                      ))}
                    </div>
                  )}

                  {[
                    { label: 'Nutrition Focus', content: guidance.nutrition_focus },
                    { label: 'Sleep & Stress', content: guidance.sleep_stress_tip },
                  ].filter(s => s.content).map(section => (
                    <div key={section.label} className="p-4 rounded-xl border" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
                      <p className="text-[10px] font-bold uppercase tracking-widest mb-2" style={{ color: '#91968e' }}>{section.label}</p>
                      <p className="text-sm leading-relaxed" style={{ color: '#5d635d' }}>{section.content}</p>
                    </div>
                  ))}

                  {guidance.motivating_insight && (
                    <div className="p-4 rounded-xl border" style={{ background: 'rgba(200,224,0,0.06)', borderColor: 'rgba(200,224,0,0.2)' }}>
                      <p className="text-sm leading-relaxed italic" style={{ color: '#141613' }}>"{guidance.motivating_insight}"</p>
                    </div>
                  )}

                  <button onClick={generateGuidance}
                    className="w-full py-3.5 rounded-2xl text-sm font-semibold border flex items-center justify-center gap-2"
                    style={{ borderColor: '#e8e1d4', color: '#91968e', background: '#ffffff' }}>
                    <Sparkles size={13} /> Regenerate Guidance
                  </button>
                </div>
              )}
            </motion.div>
          )}

        </AnimatePresence>
        )}
      </div>

    </div>
  );
}