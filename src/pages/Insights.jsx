import { useEffect, useState, useCallback } from 'react';
import { usePullToRefresh } from '@/hooks/usePullToRefresh';
import { motion, AnimatePresence } from 'framer-motion';
import { AreaChart, Area, BarChart, Bar, XAxis, Tooltip, ResponsiveContainer } from 'recharts';
import { ChevronDown, ChevronUp, Sparkles, Loader2 } from 'lucide-react';
import CustomizeButton from '@/components/customize/CustomizeButton';
import { usePageLayout } from '@/components/customize/usePageLayout';
import { backend } from '@/api/backendClient';
import { getUserAIContext } from '@/lib/aiContext';
import { loadTodayDashboardState } from '@/lib/personalizationSync';

const PAGE_KEY = 'insights';
const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

function getTodayISO() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

function toLocalISO(date) {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
}

function getLastSevenDates() {
  return Array.from({ length: 7 }, (_, index) => {
    const date = new Date();
    date.setDate(date.getDate() - (6 - index));
    return toLocalISO(date);
  });
}

function shortDay(date) {
  return new Date(`${date}T12:00:00`).toLocaleDateString(undefined, { weekday: 'short' });
}

function sameValue(a, b) {
  return Boolean(a) && Boolean(b) && String(a) === String(b);
}

function newestFirst(a, b) {
  const aDate = a?.generated_at || a?.completed_at || a?.date || a?.updated_date || a?.created_date || '';
  const bDate = b?.generated_at || b?.completed_at || b?.date || b?.updated_date || b?.created_date || '';
  return String(bDate).localeCompare(String(aDate));
}

function chooseActiveMasterPlan(plans = []) {
  const safePlans = Array.isArray(plans) ? plans.filter(Boolean).sort(newestFirst) : [];

  return safePlans.find(plan =>
    plan.plan_type === 'daily' && plan.status === 'active' && plan.source === 'plan_questionnaire_overview'
  ) ||
    safePlans.find(plan =>
      plan.plan_type === 'daily' && plan.status === 'active' && plan.plan_payload?.source === 'plan_questionnaire_overview'
    ) ||
    safePlans.find(plan =>
      plan.plan_type === 'daily' && plan.status === 'active' && plan.source === 'plan_questionnaire_initial'
    ) ||
    safePlans.find(plan =>
      plan.plan_type === 'daily' && plan.status === 'active' && plan.plan_payload?.source === 'plan_questionnaire_initial'
    ) ||
    safePlans.find(plan => plan.plan_type === 'daily' && plan.status === 'active') ||
    null;
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

function valueOrZero(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : 0;
}

function average(values = []) {
  const valid = values.map(Number).filter(value => Number.isFinite(value) && value > 0);
  if (!valid.length) return 0;
  return valid.reduce((sum, value) => sum + value, 0) / valid.length;
}

function formatNumber(value) {
  if (value >= 1000) return `${(value / 1000).toFixed(1)}k`;
  return `${Math.round(value)}`;
}

function getPlanNutritionTargets(masterPlan) {
  return masterPlan?.nutrition_targets ||
    masterPlan?.plan_payload?.nutrition_targets ||
    {};
}

function getTargetCalories(masterPlan, dashboard) {
  const t = getPlanNutritionTargets(masterPlan);
  return t.calories || t.calorie_target ||
    dashboard?.mealPlan?.caloriesTarget ||
    dashboard?.user?.calorieGoal ||
    null;
}

function getTargetProtein(masterPlan, dashboard) {
  const t = getPlanNutritionTargets(masterPlan);
  return t.protein_g || t.protein || t.protein_target_g ||
    dashboard?.mealPlan?.proteinTarget ||
    null;
}

function getTargetCarbs(masterPlan) {
  const t = getPlanNutritionTargets(masterPlan);
  return t.carbs_g || t.carbs || t.carbs_target_g || null;
}

function getTargetFat(masterPlan) {
  const t = getPlanNutritionTargets(masterPlan);
  return t.fat_g || t.fats_g || t.fats || t.fat || t.fats_target_g || null;
}

function getTargetWater(masterPlan, dashboard) {
  const t = getPlanNutritionTargets(masterPlan);
  return t.hydration_liters || t.water_liters || t.hydration_target ||
    dashboard?.user?.waterGoal ||
    null;
}

function getNutrientStatus(n) {
  if (!n.goal) return { label: 'No target', color: '#91968e' };

  const pct = n.current / n.goal;
  if (pct < 0.6) return { label: 'Low', color: '#b05a3a' };
  if (pct < 0.85) return { label: 'Below', color: '#c9814a' };
  if (pct <= 1.1) return { label: 'On track', color: ACCENT_DARK };
  return { label: 'Over', color: '#b05a3a' };
}

function buildNutrients({ todayLog, masterPlan, dashboard }) {
  const targets = {
    calories: getTargetCalories(masterPlan, dashboard),
    protein: getTargetProtein(masterPlan, dashboard),
    carbs: getTargetCarbs(masterPlan),
    fat: getTargetFat(masterPlan),
    water: getTargetWater(masterPlan, dashboard),
  };

  return [
    {
      label: 'Calories',
      current: valueOrZero(todayLog?.calories_consumed),
      goal: valueOrZero(targets.calories),
      unit: 'kcal',
      color: ACCENT,
    },
    {
      label: 'Protein',
      current: valueOrZero(todayLog?.protein_consumed_g),
      goal: valueOrZero(targets.protein),
      unit: 'g',
      color: ACCENT_DARK,
    },
    {
      label: 'Carbohydrates',
      current: valueOrZero(todayLog?.carbs_consumed_g),
      goal: valueOrZero(targets.carbs),
      unit: 'g',
      color: '#7b6fa0',
    },
    {
      label: 'Fat',
      current: valueOrZero(todayLog?.fats_consumed_g || todayLog?.fat_consumed_g),
      goal: valueOrZero(targets.fat),
      unit: 'g',
      color: '#b05a3a',
    },
    {
      label: 'Water',
      current: valueOrZero(todayLog?.water_liters),
      goal: valueOrZero(targets.water),
      unit: 'L',
      color: '#5d8aa8',
    },
  ].filter(n => n.goal > 0 || n.current > 0);
}

function buildInsightData({
  dashboard,
  dailyLogs,
  workoutLogs,
  foodLogs,
  readinessLogs,
  mealPlans,
  masterPlan,
}) {
  const dates = getLastSevenDates();
  const todayISO = getTodayISO();

  const dailyByDate = new Map((dailyLogs || []).map(log => [log.date, log]));
  const readinessByDate = new Map((readinessLogs || []).map(log => [log.date, log]));

  const todayLog =
    dailyByDate.get(todayISO) ||
    dashboard?._raw?.dailyLog ||
    null;

  const stepsData = dates.map(date => {
    const log = dailyByDate.get(date);
    return {
      day: shortDay(date),
      date,
      steps: valueOrZero(log?.steps),
    };
  });

  const sleepData = dates.map(date => {
    const log = dailyByDate.get(date);
    return {
      day: shortDay(date),
      date,
      sleep: valueOrZero(log?.sleep_hours),
    };
  });

  const energyData = dates.map(date => {
    const log = dailyByDate.get(date);
    const readiness = readinessByDate.get(date);
    const energy = log?.energy != null
      ? valueOrZero(log.energy) * (valueOrZero(log.energy) <= 10 ? 10 : 1)
      : valueOrZero(readiness?.energy) * (valueOrZero(readiness?.energy) <= 10 ? 10 : 1);

    return {
      day: shortDay(date),
      date,
      energy,
    };
  });

  const weekWorkoutLogs = (workoutLogs || []).filter(log => dates.includes(log.date));
  const completedWorkouts = weekWorkoutLogs.filter(log => log.status === 'completed');

  const nutrients = buildNutrients({ todayLog, masterPlan, dashboard });
  const deficientNutrients = nutrients.filter(n => n.goal > 0 && n.current / n.goal < 0.75);

  const stepTotal = stepsData.reduce((sum, item) => sum + valueOrZero(item.steps), 0);
  const stepGoal = dashboard?.user?.stepGoal || 10000;
  const stepGoalPct = stepGoal ? Math.round((stepTotal / (stepGoal * 7)) * 100) : 0;

  const avgSleep = average(sleepData.map(item => item.sleep));
  const avgEnergy = average(energyData.map(item => item.energy));
  const latestReadiness = readinessLogs?.[0] || dashboard?._raw?.readinessCheckIn || null;
  const recoveryScore = valueOrZero(todayLog?.recovery_score || latestReadiness?.readiness_score || dashboard?.readiness?.score);

  return {
    dates,
    todayISO,
    dashboard,
    masterPlan,
    todayLog,
    dailyLogs,
    workoutLogs,
    foodLogs,
    readinessLogs,
    mealPlans,
    stepsData,
    sleepData,
    energyData,
    nutrients,
    deficientNutrients,
    summaryTiles: [
      {
        label: 'Steps',
        value: formatNumber(stepTotal),
        sub: stepGoal ? `${Math.max(0, stepGoalPct)}% weekly goal` : 'no goal set',
      },
      {
        label: 'Avg sleep',
        value: avgSleep ? `${avgSleep.toFixed(1)}h` : '--',
        sub: dashboard?.user?.sleepGoal ? `goal ${dashboard.user.sleepGoal}h` : 'not logged yet',
      },
      {
        label: 'Recovery',
        value: recoveryScore ? `${Math.round(recoveryScore)}` : '--',
        sub: recoveryScore ? 'today' : 'not logged yet',
      },
      {
        label: 'Energy',
        value: avgEnergy ? `${Math.round(avgEnergy)}` : '--',
        sub: avgEnergy ? '7-day avg' : 'not logged yet',
      },
    ],
    completedWorkoutCount: completedWorkouts.length,
  };
}

function buildPatternInsights(data) {
  if (!data) return [];

  const insights = [];
  const { avgSleep, stepTotal, stepGoal, proteinNutrient } = {
    avgSleep: average(data.sleepData.map(item => item.sleep)),
    stepTotal: data.stepsData.reduce((sum, item) => sum + valueOrZero(item.steps), 0),
    stepGoal: data.dashboard?.user?.stepGoal || 10000,
    proteinNutrient: data.nutrients.find(n => n.label === 'Protein'),
  };

  if (!data.masterPlan && !data.dailyLogs?.length && !data.workoutLogs?.length && !data.foodLogs?.length) {
    return [{
      what: 'Not enough logged data yet',
      why: 'Insights need your plan plus a few real check-ins, workouts, meals, or daily logs.',
      action: 'Complete your plan and log today once so Execute can start finding useful patterns.',
    }];
  }

  if (avgSleep > 0) {
    insights.push({
      what: `Average sleep is ${avgSleep.toFixed(1)} hours`,
      why: avgSleep >= 7 ? 'Your recent sleep gives the plan a stronger recovery base.' : 'Lower sleep can reduce readiness and make hard training days less productive.',
      action: avgSleep >= 7 ? 'Keep the same sleep window tonight.' : 'Move bedtime earlier by 30 minutes before your next hard session.',
    });
  }

  if (stepTotal > 0) {
    const pct = Math.round((stepTotal / (stepGoal * 7)) * 100);
    insights.push({
      what: `You are at ${pct}% of your weekly step target`,
      why: 'Steps are a low-friction signal for recovery, energy expenditure, and consistency.',
      action: pct >= 80 ? 'Protect the current routine for the rest of the week.' : 'Add one 15-minute walk after a meal today.',
    });
  }

  if (proteinNutrient?.goal > 0) {
    const pct = Math.round((proteinNutrient.current / proteinNutrient.goal) * 100);
    insights.push({
      what: `Protein is at ${pct}% of today’s target`,
      why: 'Protein consistency supports muscle retention and makes the nutrition plan easier to follow.',
      action: pct >= 85 ? 'Keep your current meal structure today.' : 'Add one protein-forward meal or snack before dinner.',
    });
  }

  if (data.completedWorkoutCount > 0) {
    insights.push({
      what: `${data.completedWorkoutCount} workout${data.completedWorkoutCount === 1 ? '' : 's'} completed this week`,
      why: 'Completed workouts are the strongest signal that the plan is turning into behavior.',
      action: 'Use My Week to protect your next planned training slot.',
    });
  }

  if (!insights.length) {
    insights.push({
      what: 'Your plan is ready, but logged behavior is limited',
      why: 'The app needs a few days of real activity, meals, and recovery inputs to identify useful trends.',
      action: 'Log sleep, water, and your next workout to unlock better insights.',
    });
  }

  return insights.slice(0, 4);
}

function CollapsibleSection({ title, subtitle, badge, children, defaultOpen = true }) {
  const [open, setOpen] = useState(defaultOpen);

  return (
    <div className="rounded-2xl border overflow-hidden" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
      <button className="w-full flex items-center justify-between px-5 py-4" onClick={() => setOpen(o => !o)}>
        <div className="text-left">
          <p className="text-sm font-semibold" style={{ color: '#141613' }}>{title}</p>
          {subtitle && <p className="text-xs mt-0.5" style={{ color: '#91968e' }}>{subtitle}</p>}
        </div>
        <div className="flex items-center gap-2">
          {badge && <span className="text-[10px] font-semibold px-2.5 py-1 rounded-full" style={{ background: 'rgba(200,224,0,0.12)', color: ACCENT_DARK }}>{badge}</span>}
          {open ? <ChevronUp size={14} style={{ color: '#91968e' }} /> : <ChevronDown size={14} style={{ color: '#91968e' }} />}
        </div>
      </button>

      <AnimatePresence>
        {open && (
          <motion.div initial={{ height: 0, opacity: 0 }} animate={{ height: 'auto', opacity: 1 }} exit={{ height: 0, opacity: 0 }} transition={{ duration: 0.2 }} className="overflow-hidden">
            <div className="px-5 pb-5">{children}</div>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}

const CustomTooltip = ({ active, payload, label }) => {
  if (active && payload?.length) {
    return (
      <div className="px-3 py-2 rounded-xl text-xs border" style={{ background: '#ffffff', borderColor: '#e8e1d4', boxShadow: '0 4px 16px rgba(20,22,19,0.1)' }}>
        <p className="mb-1" style={{ color: '#91968e' }}>{label}</p>
        <p style={{ color: ACCENT_DARK }}><strong>{payload[0].value}</strong></p>
      </div>
    );
  }

  return null;
};

export default function Insights() {
  const [insightData, setInsightData] = useState(null);
  const [loadingData, setLoadingData] = useState(true);
  const [aiInsight, setAiInsight] = useState(null);
  const [generatingInsight, setGeneratingInsight] = useState(false);
  const [nutrientTab, setNutrientTab] = useState('deficient');
  const [isCustomizing, setIsCustomizing] = useState(false);
  const layout = usePageLayout(PAGE_KEY);
  const { containerRef: pullRef } = usePullToRefresh(async () => { await loadData(); });

  const loadData = useCallback(async () => {
    setLoadingData(true);
    const todayISO = getTodayISO();
    const [
      dashboard,
      dailyLogs,
      workoutLogs,
      foodLogs,
      readinessLogs,
      mealPlans,
      aiPlans,
    ] = await Promise.all([
      loadTodayDashboardState(todayISO).catch(() => null),
      backend.entities.DailyLog.list('-date', 14).catch(() => []),
      backend.entities.WorkoutLog.list('-date', 20).catch(() => []),
      backend.entities.FoodLog.list('-date', 20).catch(() => []),
      backend.entities.ReadinessCheckIn.list('-date', 14).catch(() => []),
      backend.entities.MealPlan.list('-date', 14).catch(() => []),
      backend.entities.AIPlan.filter({ plan_type: 'daily', status: 'active' }, '-generated_at', 25).catch(() => []),
    ]);
    const masterPlan = dashboard?._raw?.masterPlan || chooseActiveMasterPlan(aiPlans);
    setInsightData(buildInsightData({ dashboard, dailyLogs, workoutLogs, foodLogs, readinessLogs, mealPlans, masterPlan }));
    setLoadingData(false);
  }, []);

  useEffect(() => { loadData().catch(() => { setInsightData(null); setLoadingData(false); }); }, [loadData]);

  const patternInsights = aiInsight || buildPatternInsights(insightData);
  const nutrients = insightData?.nutrients || [];
  const deficientNutrients = insightData?.deficientNutrients || [];
  const displayNutrients = nutrientTab === 'deficient' ? deficientNutrients : nutrients;

  const generateInsight = async () => {
    setGeneratingInsight(true);

    try {
      const aiContext = await getUserAIContext({ forceRefresh: true });
      const insightPayload = {
        masterPlan: {
          id: insightData?.masterPlan?.id || null,
          generation_batch_id: insightData?.masterPlan?.generation_batch_id || null,
          summary:
            insightData?.masterPlan?.summary ||
            insightData?.masterPlan?.plan_summary?.positioning_summary ||
            insightData?.masterPlan?.plan_payload?.plan_summary?.positioning_summary ||
            insightData?.masterPlan?.plan_payload?.long_term_plan?.summary ||
            null,
          nutrition_targets:
            insightData?.masterPlan?.nutrition_targets ||
            insightData?.masterPlan?.plan_payload?.nutrition_targets ||
            null,
        },
        recentDailyLogs: insightData?.dailyLogs?.slice(0, 7) || [],
        recentWorkoutLogs: insightData?.workoutLogs?.slice(0, 8) || [],
        recentFoodLogs: insightData?.foodLogs?.slice(0, 8) || [],
        recentReadiness: insightData?.readinessLogs?.slice(0, 7) || [],
        nutrients,
      };

      const result = await backend.integrations.Core.InvokeLLM({
        prompt: `You are Execute's AI performance analyst. Generate 4 personalized insights using only real plan and log data.

${aiContext}

Structured recent data:
${JSON.stringify(insightPayload, null, 2)}

Rules:
1. Do not invent logs, meals, nutrients, workouts, steps, sleep, or recovery patterns.
2. If data is sparse, say what is missing and give the next best logging action.
3. Distinguish planned recommendations from completed behavior.
4. Reference the user's active plan only as plan context, not as completed behavior.
5. Keep guidance practical and non-medical.
6. Do not diagnose or treat injuries.

Return 4 insights. Each insight needs:
- what: the pattern or data gap
- why: why it matters for this user's goal or plan
- action: one concrete next action`,
        response_json_schema: {
          type: 'object',
          properties: {
            insights: {
              type: 'array',
              items: {
                type: 'object',
                properties: {
                  what: { type: 'string' },
                  why: { type: 'string' },
                  action: { type: 'string' },
                },
              },
            },
          },
          required: ['insights'],
        },
      });

      setAiInsight(Array.isArray(result?.insights) ? result.insights : []);
    } catch (err) {
      console.warn('[Insights] AI insight generation failed', err);
      setAiInsight(buildPatternInsights(insightData));
    } finally {
      setGeneratingInsight(false);
    }
  };

  return (
    <div ref={pullRef} className="min-h-screen transition-transform transition-opacity" style={{ background: '#f6f2e8' }}>
      <div className="sticky top-0 z-40 px-5 pt-safe-header pb-4" style={{ background: 'rgba(251,248,241,0.95)', backdropFilter: 'blur(24px)', borderBottom: '1px solid #e8e1d4' }}>
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-lg font-bold tracking-tight" style={{ color: '#141613' }}>Insights</h1>
            <p className="text-xs mt-0.5" style={{ color: '#91968e' }}>Real trends from your plan and logs</p>
          </div>

          <div className="flex items-center gap-2">
            <CustomizeButton onCustomize={() => setIsCustomizing(prev => !prev)} isCustomizing={isCustomizing} />
            <motion.button
              whileTap={{ scale: 0.92 }}
              onClick={generateInsight}
              disabled={generatingInsight || loadingData}
              className="flex items-center gap-1.5 px-3 py-2 rounded-xl text-xs font-bold"
              style={{ background: generatingInsight || loadingData ? 'rgba(200,224,0,0.4)' : ACCENT, color: '#141613' }}
            >
              {generatingInsight ? <Loader2 size={11} className="animate-spin" /> : <Sparkles size={11} />}
              Generate insights
            </motion.button>
          </div>
        </div>
      </div>

      <div className="px-5 pb-8 space-y-4 pt-5">
        {loadingData ? (
          <div className="flex items-center justify-center py-16">
            <Loader2 size={22} className="animate-spin" style={{ color: ACCENT_DARK }} />
          </div>
        ) : (
          <>
            <div className="grid grid-cols-4 gap-2">
              {(insightData?.summaryTiles || []).map((s, i) => (
                <motion.div
                  key={s.label}
                  initial={{ opacity: 0, y: 10 }}
                  animate={{ opacity: 1, y: 0 }}
                  transition={{ delay: i * 0.06 }}
                  className="p-3 rounded-2xl border text-center"
                  style={{ background: '#ffffff', borderColor: '#e8e1d4' }}
                >
                  <div className="text-base font-black mb-0.5" style={{ color: ACCENT_DARK }}>{s.value}</div>
                  <div className="text-[9px] font-medium leading-tight" style={{ color: '#141613' }}>{s.label}</div>
                  <div className="text-[9px] mt-0.5" style={{ color: '#91968e' }}>{s.sub}</div>
                </motion.div>
              ))}
            </div>

            <div>
              <p className="text-[10px] font-bold uppercase tracking-widest mb-3" style={{ color: '#91968e' }}>
                {aiInsight ? 'Personalized Insights' : 'Pattern Insights'}
              </p>

              {generatingInsight ? (
                <div className="flex items-center justify-center py-10">
                  <Loader2 size={20} className="animate-spin" style={{ color: ACCENT_DARK }} />
                </div>
              ) : (
                <div className="space-y-2">
                  {patternInsights.map((ins, i) => (
                    <motion.div
                      key={`${ins.what}-${i}`}
                      initial={{ opacity: 0, x: -8 }}
                      animate={{ opacity: 1, x: 0 }}
                      transition={{ delay: 0.1 + i * 0.07 }}
                      className="p-4 rounded-xl border"
                      style={{ background: '#ffffff', borderColor: '#e8e1d4' }}
                    >
                      <p className="text-sm font-semibold mb-1" style={{ color: '#141613' }}>{ins.what}</p>
                      {ins.why && <p className="text-xs leading-relaxed mb-1.5" style={{ color: '#5d635d' }}>{ins.why}</p>}
                      <p className="text-xs font-semibold leading-snug" style={{ color: ACCENT_DARK }}>→ {ins.action}</p>
                    </motion.div>
                  ))}
                </div>
              )}
            </div>

            <CollapsibleSection title="Nutrition Targets" subtitle="Today vs active plan targets">
              {nutrients.length > 0 ? (
                <>
                  <div className="flex gap-1 mb-4">
                    {[{ id: 'deficient', label: 'Below target' }, { id: 'all', label: 'All logged' }].map(tab => (
                      <button
                        key={tab.id}
                        onClick={() => setNutrientTab(tab.id)}
                        className="flex-1 py-1.5 rounded-xl text-xs font-medium"
                        style={{ background: nutrientTab === tab.id ? ACCENT : '#f2efe7', color: '#141613', border: `1px solid ${nutrientTab === tab.id ? ACCENT : '#e8e1d4'}` }}
                      >
                        {tab.label}
                      </button>
                    ))}
                  </div>

                  <div className="space-y-3">
                    {(displayNutrients.length > 0 ? displayNutrients : nutrients).map((n, i) => {
                      const pct = n.goal ? Math.min((n.current / n.goal) * 100, 100) : 0;
                      const status = getNutrientStatus(n);

                      return (
                        <div key={n.label}>
                          <div className="flex items-center justify-between mb-1">
                            <span className="text-xs font-medium" style={{ color: '#141613' }}>{n.label}</span>
                            <div className="flex items-center gap-2">
                              <span className="text-xs" style={{ color: '#91968e' }}>{n.current}/{n.goal || '--'}{n.unit}</span>
                              <span className="text-[9px] font-bold px-1.5 py-0.5 rounded-full" style={{ background: status.color + '15', color: status.color }}>{status.label}</span>
                            </div>
                          </div>
                          <div className="h-1.5 rounded-full overflow-hidden" style={{ background: '#e8e1d4' }}>
                            <motion.div className="h-full rounded-full" style={{ background: n.color }} initial={{ width: 0 }} animate={{ width: `${pct}%` }} transition={{ duration: 0.7, delay: i * 0.03 }} />
                          </div>
                        </div>
                      );
                    })}
                  </div>

                  {deficientNutrients.length > 0 && (
                    <div className="mt-4 p-3 rounded-xl" style={{ background: 'rgba(176,90,58,0.06)', border: '1px solid rgba(176,90,58,0.15)' }}>
                      <p className="text-xs font-semibold mb-1" style={{ color: '#b05a3a' }}>Focus targets today</p>
                      <p className="text-xs leading-relaxed" style={{ color: '#5d635d' }}>
                        {deficientNutrients.slice(0, 3).map(n => n.label).join(', ')} are below 75% of target based on today's logged data.
                      </p>
                    </div>
                  )}
                </>
              ) : (
                <div className="p-4 rounded-xl border" style={{ background: '#fbf8f1', borderColor: '#e8e1d4' }}>
                  <p className="text-sm font-semibold mb-1" style={{ color: '#141613' }}>No nutrition logs yet</p>
                  <p className="text-xs leading-relaxed" style={{ color: '#5d635d' }}>
                    Log meals or daily nutrition to compare intake against your active plan.
                  </p>
                </div>
              )}
            </CollapsibleSection>

            <CollapsibleSection title="Daily Steps" subtitle="Last 7 days" badge={`${formatNumber(insightData?.stepsData?.reduce((sum, item) => sum + valueOrZero(item.steps), 0) || 0)} total`}>
              <ResponsiveContainer width="100%" height={120}>
                <BarChart data={insightData?.stepsData || []} barCategoryGap="35%">
                  <XAxis dataKey="day" axisLine={false} tickLine={false} tick={{ fill: '#91968e', fontSize: 11 }} />
                  <Tooltip content={<CustomTooltip />} cursor={false} />
                  <Bar dataKey="steps" radius={[3, 3, 0, 0]} fill={ACCENT} opacity={0.85} name="Steps" />
                </BarChart>
              </ResponsiveContainer>
            </CollapsibleSection>

            <CollapsibleSection title="Sleep Duration" subtitle="Last 7 days" badge={`${average((insightData?.sleepData || []).map(item => item.sleep)).toFixed(1)}h avg`} defaultOpen={false}>
              <ResponsiveContainer width="100%" height={110}>
                <AreaChart data={insightData?.sleepData || []}>
                  <defs>
                    <linearGradient id="sleepGrad" x1="0" y1="0" x2="0" y2="1">
                      <stop offset="5%" stopColor={ACCENT_DARK} stopOpacity={0.2} />
                      <stop offset="95%" stopColor={ACCENT_DARK} stopOpacity={0} />
                    </linearGradient>
                  </defs>
                  <XAxis dataKey="day" axisLine={false} tickLine={false} tick={{ fill: '#91968e', fontSize: 11 }} />
                  <Tooltip content={<CustomTooltip />} cursor={false} />
                  <Area type="monotone" dataKey="sleep" stroke={ACCENT_DARK} strokeWidth={2} fill="url(#sleepGrad)" name="Hours" />
                </AreaChart>
              </ResponsiveContainer>
            </CollapsibleSection>

            <CollapsibleSection title="Energy Score" subtitle="Last 7 days" badge={`${Math.round(average((insightData?.energyData || []).map(item => item.energy)))} avg`} defaultOpen={false}>
              <ResponsiveContainer width="100%" height={110}>
                <AreaChart data={insightData?.energyData || []}>
                  <defs>
                    <linearGradient id="energyGrad" x1="0" y1="0" x2="0" y2="1">
                      <stop offset="5%" stopColor={ACCENT} stopOpacity={0.25} />
                      <stop offset="95%" stopColor={ACCENT} stopOpacity={0} />
                    </linearGradient>
                  </defs>
                  <XAxis dataKey="day" axisLine={false} tickLine={false} tick={{ fill: '#91968e', fontSize: 11 }} />
                  <Tooltip content={<CustomTooltip />} cursor={false} />
                  <Area type="monotone" dataKey="energy" stroke={ACCENT} strokeWidth={2} fill="url(#energyGrad)" name="Energy" />
                </AreaChart>
              </ResponsiveContainer>
              <p className="text-xs mt-2" style={{ color: '#91968e' }}>
                Based on logged energy and readiness check-ins.
              </p>
            </CollapsibleSection>

            <motion.div
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              transition={{ delay: 0.4 }}
              className="p-4 rounded-xl border"
              style={{ background: '#ffffff', borderColor: '#e8e1d4' }}
            >
              <p className="text-[10px] font-bold uppercase tracking-widest mb-3" style={{ color: '#91968e' }}>Insight quality</p>
              <p className="text-sm leading-relaxed mb-1.5" style={{ color: '#5d635d' }}>
                Insights improve as you complete workouts, log meals, and submit readiness check-ins.
              </p>
              <p className="text-sm font-semibold" style={{ color: '#141613' }}>
                → Best next action: log one meaningful signal today.
              </p>
            </motion.div>
          </>
        )}
      </div>
    </div>
  );
}