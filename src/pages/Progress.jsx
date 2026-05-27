import { useState, useEffect, useCallback } from 'react';
import { useSearchParams, useNavigate } from 'react-router-dom';
import { motion } from 'framer-motion';
import {
  TrendingUp, TrendingDown, Minus, Trophy, AlertCircle,
  ChevronRight, Target, Loader2, BarChart2, Plus, ChevronLeft,
} from 'lucide-react';
import { LineChart, Line, ResponsiveContainer, Tooltip, XAxis } from 'recharts';
import { backend } from '@/api/backendClient';
import { loadActiveGoals } from '@/lib/personalizationSync';
import { format } from 'date-fns/format';
import { subDays } from 'date-fns/subDays';
import { parseISO } from 'date-fns/parseISO';
import { differenceInDays } from 'date-fns/differenceInDays';

const toLocalISO = (d) =>
  `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
import { syncPlanGoals, autoTrackGoalProgress } from '@/lib/goalSync';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

// ─── Helpers ──────────────────────────────────────────────────────────────────

function calcProgress(goal, entries = []) {
  const current = goal.current_value || 0;
  const target = goal.target_value || 1;
  const start = goal.start_value ?? 0;
  const direction = goal.target_direction || 'increase';

  let pct = 0;
  if (direction === 'decrease') {
    const denom = start - target;
    pct = denom > 0 ? (start - current) / denom : (current <= target ? 1 : 0);
  } else {
    const denom = target - start;
    pct = denom > 0 ? (current - start) / denom : (current >= target ? 1 : 0);
  }
  return Math.max(0, Math.min(1, pct));
}

function getStatus(goal, progressPct) {
  if (progressPct >= 1) return 'complete';
  if (!goal.target_date) return progressPct > 0 ? 'in_progress' : 'no_data';

  const today = new Date();
  const start = goal.start_date ? parseISO(goal.start_date) : parseISO(goal.created_date || today.toISOString());
  const end = parseISO(goal.target_date);
  const totalDays = differenceInDays(end, start) || 1;
  const elapsed = differenceInDays(today, start);
  const expectedPct = Math.min(elapsed / totalDays, 1);
  if (progressPct >= expectedPct - 0.15) return 'on_track';
  return 'behind';
}

const STATUS_META = {
  complete:    { label: 'Complete',        color: '#4a7c59', bg: 'rgba(74,124,89,0.1)',    icon: Trophy },
  on_track:    { label: 'On track',        color: ACCENT_DARK, bg: 'rgba(200,224,0,0.1)', icon: TrendingUp },
  behind:      { label: 'Behind pace',     color: '#b05a3a', bg: 'rgba(176,90,58,0.1)',   icon: TrendingDown },
  in_progress: { label: 'In progress',     color: '#5d635d', bg: 'rgba(93,99,93,0.1)',    icon: Minus },
  no_data:     { label: 'No recent data',  color: '#91968e', bg: 'rgba(145,150,142,0.08)',icon: AlertCircle },
};

const RANGE_OPTIONS = [
  { label: '7D',  days: 7 },
  { label: '30D', days: 30 },
  { label: '90D', days: 90 },
  { label: 'All', days: 365 },
];

// ─── Mini sparkline ───────────────────────────────────────────────────────────

function Sparkline({ data, color = ACCENT }) {
  if (!data || data.length < 2) return null;
  return (
    <ResponsiveContainer width="100%" height={36}>
      <LineChart data={data} margin={{ top: 2, bottom: 2, left: 0, right: 0 }}>
        <Line type="monotone" dataKey="pct" stroke={color} strokeWidth={2} dot={false} />
      </LineChart>
    </ResponsiveContainer>
  );
}

// ─── Goal Progress Card ───────────────────────────────────────────────────────

function GoalProgressCard({ goal, entries, highlighted, onViewTrend }) {
  const progressPct = calcProgress(goal, entries);
  const status = getStatus(goal, progressPct);
  const meta = STATUS_META[status];
  const StatusIcon = meta.icon;

  const sparkData = entries
    .sort((a, b) => a.date.localeCompare(b.date))
    .map(e => ({
      date: e.date,
      pct: Math.round(Math.min((e.value / (goal.target_value || 1)) * 100, 100)),
    }));

  return (
    <motion.div
      initial={{ opacity: 0, y: 8 }}
      animate={{ opacity: 1, y: 0 }}
      className="p-4 rounded-2xl border"
      style={{
        background: highlighted ? 'rgba(200,224,0,0.06)' : '#ffffff',
        borderColor: highlighted ? 'rgba(200,224,0,0.4)' : '#e8e1d4',
      }}
    >
      <div className="flex items-start justify-between mb-3">
        <div className="flex items-start gap-2.5 flex-1 min-w-0">
          <span className="text-lg flex-shrink-0 mt-0.5">{goal.emoji || '🎯'}</span>
          <div className="min-w-0">
            <p className="text-sm font-semibold leading-tight truncate" style={{ color: '#141613' }}>{goal.title}</p>
            <div className="flex items-center gap-1.5 mt-1">
              <span className="text-[10px] px-1.5 py-0.5 rounded-full font-semibold flex items-center gap-1"
                style={{ background: meta.bg, color: meta.color }}>
                <StatusIcon size={9} /> {meta.label}
              </span>
            </div>
          </div>
        </div>
        <div className="text-right flex-shrink-0 ml-2">
          <p className="text-lg font-black" style={{ color: ACCENT_DARK }}>{Math.round(progressPct * 100)}%</p>
          <p className="text-[10px]" style={{ color: '#91968e' }}>
            {goal.current_value || 0}/{goal.target_value} {goal.unit}
          </p>
        </div>
      </div>

      {/* Progress bar */}
      <div className="h-1.5 rounded-full overflow-hidden mb-3" style={{ background: '#e8e1d4' }}>
        <motion.div
          className="h-full rounded-full"
          style={{ background: status === 'complete' ? '#4a7c59' : ACCENT }}
          initial={{ width: 0 }}
          animate={{ width: `${Math.round(progressPct * 100)}%` }}
          transition={{ duration: 1, ease: [0.4, 0, 0.2, 1] }}
        />
      </div>

      {/* Sparkline */}
      {sparkData.length >= 2 && (
        <div className="mb-3 -mx-1">
          <Sparkline data={sparkData} color={status === 'complete' ? '#4a7c59' : ACCENT} />
        </div>
      )}

      <button
        onClick={() => onViewTrend(goal.id)}
        className="w-full flex items-center justify-center gap-1.5 py-2 rounded-xl text-xs font-semibold border"
        style={{ background: 'rgba(200,224,0,0.06)', borderColor: 'rgba(200,224,0,0.2)', color: ACCENT_DARK }}
      >
        <BarChart2 size={11} /> View Trend
      </button>
    </motion.div>
  );
}

// ─── Overview Card ────────────────────────────────────────────────────────────

function OverviewCard({ goals, allEntries }) {
  const active = goals.filter(g => g.status !== 'completed');
  const complete = goals.filter(g => {
    const pct = calcProgress(g);
    return pct >= 1;
  });
  const onTrack = active.filter(g => {
    const pct = calcProgress(g);
    return ['on_track', 'in_progress'].includes(getStatus(g, pct));
  });
  const behind = active.filter(g => getStatus(g, calcProgress(g)) === 'behind');
  const overallPct = active.length > 0
    ? Math.round(active.reduce((sum, g) => sum + calcProgress(g), 0) / active.length * 100)
    : 0;

  return (
    <div className="p-4 rounded-2xl border" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
      <div className="flex items-center gap-4 mb-4">
        <div className="text-center">
          <p className="text-2xl font-black" style={{ color: ACCENT_DARK }}>{active.length}</p>
          <p className="text-[10px]" style={{ color: '#91968e' }}>Active</p>
        </div>
        <div className="h-8 w-px" style={{ background: '#e8e1d4' }} />
        <div className="text-center">
          <p className="text-2xl font-black" style={{ color: '#4a7c59' }}>{onTrack.length}</p>
          <p className="text-[10px]" style={{ color: '#91968e' }}>On track</p>
        </div>
        <div className="h-8 w-px" style={{ background: '#e8e1d4' }} />
        <div className="text-center">
          <p className="text-2xl font-black" style={{ color: '#b05a3a' }}>{behind.length}</p>
          <p className="text-[10px]" style={{ color: '#91968e' }}>Behind</p>
        </div>
        <div className="h-8 w-px" style={{ background: '#e8e1d4' }} />
        <div className="text-center">
          <p className="text-2xl font-black" style={{ color: '#4a7c59' }}>{complete.length}</p>
          <p className="text-[10px]" style={{ color: '#91968e' }}>Done</p>
        </div>
      </div>

      {active.length > 0 && (
        <>
          <div className="flex justify-between mb-1.5">
            <span className="text-xs" style={{ color: '#91968e' }}>Overall progress</span>
            <span className="text-xs font-semibold" style={{ color: ACCENT_DARK }}>{overallPct}%</span>
          </div>
          <div className="h-2 rounded-full overflow-hidden" style={{ background: '#e8e1d4' }}>
            <motion.div
              className="h-full rounded-full"
              style={{ background: ACCENT }}
              initial={{ width: 0 }}
              animate={{ width: `${overallPct}%` }}
              transition={{ duration: 1.2 }}
            />
          </div>
        </>
      )}
    </div>
  );
}

// ─── Cross-goal chart ─────────────────────────────────────────────────────────

function CrossGoalChart({ goals, allEntries, rangeDays }) {
  // Build normalized daily progress snapshots per goal, merged into unified date series
  const cutoff = toLocalISO(subDays(new Date(), rangeDays));

  const goalColors = [ACCENT, '#5d8aa8', '#b05a3a', '#4a7c59', '#9b59b6', '#e67e22'];

  // For each goal, build a map of date → normalized pct
  const goalSeries = goals.slice(0, 6).map((g, idx) => {
    const goalEntries = (allEntries[g.id] || [])
      .filter(e => e.date >= cutoff)
      .sort((a, b) => a.date.localeCompare(b.date));
    return { goal: g, entries: goalEntries, color: goalColors[idx % goalColors.length] };
  });

  // Collect all unique dates
  const allDates = [...new Set(
    goalSeries.flatMap(s => s.entries.map(e => e.date))
  )].sort();

  if (allDates.length < 2) {
    return (
      <div className="p-6 rounded-2xl border flex flex-col items-center text-center gap-3"
        style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
        <BarChart2 size={28} style={{ color: '#d9d1c2' }} />
        <p className="text-sm font-semibold" style={{ color: '#141613' }}>Not enough data yet</p>
        <p className="text-xs leading-relaxed max-w-xs" style={{ color: '#91968e' }}>
          Log progress or complete daily tracking to start seeing trends here.
        </p>
      </div>
    );
  }

  // Build merged chart data
  const chartData = allDates.map(date => {
    const point = { date: format(parseISO(date), 'MMM d') };
    goalSeries.forEach(({ goal, entries }) => {
      const entry = entries.find(e => e.date === date);
      if (entry) {
        point[goal.id] = Math.round(Math.min((entry.value / (goal.target_value || 1)) * 100, 100));
      }
    });
    return point;
  });

  return (
    <div className="p-4 rounded-2xl border" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
      <p className="text-xs font-bold uppercase tracking-widest mb-3" style={{ color: '#91968e' }}>Normalized Progress (%)</p>
      <ResponsiveContainer width="100%" height={160}>
        <LineChart data={chartData} margin={{ top: 4, bottom: 0, left: 0, right: 4 }}>
          <XAxis dataKey="date" tick={{ fontSize: 9, fill: '#91968e' }} axisLine={false} tickLine={false} interval="preserveStartEnd" />
          <Tooltip
            contentStyle={{ background: '#ffffff', border: '1px solid #e8e1d4', borderRadius: 12, fontSize: 11 }}
            formatter={(val, key) => {
              const g = goals.find(g => g.id === key);
              return [`${val}%`, g?.title || key];
            }}
          />
          {goalSeries.map(({ goal, color }) => (
            <Line
              key={goal.id}
              type="monotone"
              dataKey={goal.id}
              stroke={color}
              strokeWidth={2}
              dot={false}
              connectNulls
            />
          ))}
        </LineChart>
      </ResponsiveContainer>
      {/* Legend */}
      <div className="flex flex-wrap gap-2 mt-3">
        {goalSeries.map(({ goal, color }) => (
          <div key={goal.id} className="flex items-center gap-1">
            <div className="w-2 h-2 rounded-full flex-shrink-0" style={{ background: color }} />
            <span className="text-[10px] truncate max-w-[80px]" style={{ color: '#5d635d' }}>{goal.title}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

// ─── Main Page ────────────────────────────────────────────────────────────────

export default function Progress() {
  const [searchParams] = useSearchParams();
  const navigate = useNavigate();
  const focusGoalId = searchParams.get('goalId');

  const [goals, setGoals] = useState([]);
  const [allEntries, setAllEntries] = useState({}); // { [goal_id]: GoalProgressEntry[] }
  const [loading, setLoading] = useState(true);
  const [rangeIdx, setRangeIdx] = useState(1); // default 30D

  const load = useCallback(async () => {
    setLoading(true);
    try {
      // 1. Sync plan-derived goals (creates missing ones, skips existing)
      await syncPlanGoals().catch(() => {});

      // 2. Load all active goals
      const gs = await loadActiveGoals();
      setGoals(gs);

      if (gs.length > 0) {
        // 3. Auto-track progress from logs (non-blocking, runs in parallel with entry fetch)
        const [entries] = await Promise.all([
          backend.entities.GoalProgressEntry.list('-date', 200).catch(() => []),
          autoTrackGoalProgress(gs).catch(() => {}),
        ]);

        const byGoal = {};
        entries.forEach(e => {
          if (!byGoal[e.goal_id]) byGoal[e.goal_id] = [];
          byGoal[e.goal_id].push(e);
        });
        setAllEntries(byGoal);

        // 4. Reload goals after auto-track to pick up updated current_values
        const refreshed = await loadActiveGoals().catch(() => gs);
        setGoals(refreshed);
      }
    } catch {
      // silent
    } finally {
      setLoading(false);
    }

    backend.analytics.track({ eventName: 'progress_page_viewed' });
  }, []);

  useEffect(() => { load(); }, [load]);

  // Scroll focused goal into view
  useEffect(() => {
    if (focusGoalId && !loading) {
      setTimeout(() => {
        const el = document.getElementById(`goal-card-${focusGoalId}`);
        if (el) el.scrollIntoView({ behavior: 'smooth', block: 'center' });
      }, 400);
    }
  }, [focusGoalId, loading]);

  const handleViewTrend = (goalId) => {
    backend.analytics.track({ eventName: 'progress_goal_card_opened', properties: { goal_id: goalId } });
    navigate(`/progress?goalId=${goalId}`);
  };

  const activeGoals = goals.filter(g => g.status !== 'completed');
  const onTrackCount = activeGoals.filter(g => ['on_track', 'in_progress', 'complete'].includes(getStatus(g, calcProgress(g)))).length;
  const rangeDays = RANGE_OPTIONS[rangeIdx].days;

  if (loading) {
    return (
      <div className="min-h-screen flex items-center justify-center" style={{ background: '#f6f2e8' }}>
        <div className="flex flex-col items-center gap-3">
          <Loader2 size={20} className="animate-spin" style={{ color: ACCENT_DARK }} />
          <p className="text-xs" style={{ color: '#91968e' }}>Loading progress…</p>
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen" style={{ background: '#f6f2e8' }}>
      {/* Header */}
      <div className="sticky top-0 z-40 px-5 pt-4 pb-3"
        style={{ background: 'rgba(251,248,241,0.95)', backdropFilter: 'blur(24px)', borderBottom: '1px solid #e8e1d4', paddingTop: 'max(1rem, calc(env(safe-area-inset-top) + 1rem))' }}>
        <div className="flex items-center justify-between gap-3 mb-3">
          <button onClick={() => navigate(-1)}
            className="w-8 h-8 rounded-xl flex items-center justify-center border flex-shrink-0"
            style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
            <ChevronLeft size={16} style={{ color: '#5d635d' }} />
          </button>
        </div>
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-lg font-bold tracking-tight" style={{ color: '#141613' }}>Progress</h1>
            <p className="text-xs mt-0.5" style={{ color: '#91968e' }}>
              {activeGoals.length > 0
                ? `${activeGoals.length} active goal${activeGoals.length !== 1 ? 's' : ''} · ${onTrackCount} on track`
                : 'See what is actually improving.'}
            </p>
          </div>
          <button
            onClick={() => { backend.analytics.track({ eventName: 'progress_log_progress_clicked' }); navigate('/goals'); }}
            className="flex items-center gap-1.5 px-3 py-2 rounded-xl text-xs font-semibold border"
            style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#5d635d' }}
          >
            <Target size={12} /> Goals
          </button>
        </div>
      </div>

      <div className="px-5 pb-36 pt-5 space-y-4">

        {/* Empty state — no goals */}
        {goals.length === 0 && (
          <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}
            className="flex flex-col items-center py-20 text-center px-4">
            <div className="w-20 h-20 rounded-3xl flex items-center justify-center mb-6"
              style={{ background: 'rgba(200,224,0,0.1)', border: '1px solid rgba(200,224,0,0.2)' }}>
              <TrendingUp size={32} style={{ color: ACCENT_DARK }} />
            </div>
            <h2 className="text-xl font-black tracking-tight mb-2" style={{ color: '#141613' }}>No goals set up yet</h2>
            <p className="text-sm leading-relaxed max-w-xs mb-6" style={{ color: '#91968e' }}>
              Create your plan and goals will be set up automatically — tracking workouts, nutrition, steps, and more.
            </p>
            <button onClick={() => navigate('/plan?generate=true')}
              className="flex items-center gap-2 px-6 py-3.5 rounded-2xl text-sm font-bold mb-3"
              style={{ background: ACCENT, color: '#141613' }}>
              <Plus size={14} /> Create My Plan
            </button>
            <button onClick={() => navigate('/goals')}
              className="text-xs font-semibold"
              style={{ color: '#91968e' }}>
              Or add goals manually →
            </button>
          </motion.div>
        )}

        {goals.length > 0 && (
          <>
            {/* Overview */}
            <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}>
              <OverviewCard goals={goals} allEntries={allEntries} />
            </motion.div>

            {/* Time range toggle */}
            <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }}
              className="flex gap-1 p-1 rounded-2xl border"
              style={{ background: '#f2efe7', borderColor: '#e8e1d4' }}>
              {RANGE_OPTIONS.map((opt, i) => (
                <button key={opt.label} onClick={() => {
                  setRangeIdx(i);
                  backend.analytics.track({ eventName: 'progress_time_range_changed', properties: { range: opt.label } });
                }}
                  className="flex-1 py-1.5 rounded-xl text-xs font-semibold transition-all"
                  style={{
                    background: rangeIdx === i ? '#ffffff' : 'transparent',
                    color: rangeIdx === i ? '#141613' : '#91968e',
                    border: rangeIdx === i ? '1px solid #e8e1d4' : '1px solid transparent',
                  }}>
                  {opt.label}
                </button>
              ))}
            </motion.div>

            {/* Cross-goal chart */}
            <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.05 }}>
              <CrossGoalChart goals={activeGoals} allEntries={allEntries} rangeDays={rangeDays} />
            </motion.div>

            {/* Goal cards */}
            <p className="text-[10px] font-bold uppercase tracking-widest pt-1" style={{ color: '#91968e' }}>Goal Progress</p>

            {activeGoals.length === 0 && (
              <div className="p-5 rounded-2xl border text-center" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
                <p className="text-sm font-semibold mb-1" style={{ color: '#141613' }}>All goals completed!</p>
                <button onClick={() => navigate('/goals')}
                  className="text-xs font-semibold mt-2 inline-flex items-center gap-1"
                  style={{ color: ACCENT_DARK }}>
                  Set new goals <ChevronRight size={11} />
                </button>
              </div>
            )}

            {activeGoals.map(goal => (
              <div key={goal.id} id={`goal-card-${goal.id}`}>
                <GoalProgressCard
                  goal={goal}
                  entries={allEntries[goal.id] || []}
                  highlighted={goal.id === focusGoalId}
                  onViewTrend={handleViewTrend}
                />
              </div>
            ))}

            {/* No data nudge */}
            {Object.keys(allEntries).length === 0 && activeGoals.length > 0 && (
              <div className="p-4 rounded-2xl border text-center" style={{ background: 'rgba(200,224,0,0.05)', borderColor: 'rgba(200,224,0,0.2)' }}>
                <p className="text-xs font-semibold mb-1" style={{ color: '#5d635d' }}>
                  Goals auto-track as you log — complete a workout, log meals, or track steps to see trends appear here.
                </p>
                <div className="flex justify-center gap-3 mt-2">
                  <button onClick={() => navigate('/track')}
                    className="text-xs font-semibold px-3 py-1.5 rounded-lg border"
                    style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#5d635d' }}>
                    Track today
                  </button>
                  <button onClick={() => navigate('/workouts')}
                    className="text-xs font-semibold px-3 py-1.5 rounded-lg border"
                    style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#5d635d' }}>
                    Log workout
                  </button>
                </div>
              </div>
            )}
          </>
        )}
      </div>
    </div>
  );
}
