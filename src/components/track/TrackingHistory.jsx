import { useState, useEffect } from 'react';
import { motion } from 'framer-motion';
import { Moon, Flame, Droplets, Heart, Weight, SmilePlus, UtensilsCrossed, CheckSquare } from 'lucide-react';
import { backend } from '@/api/backendClient';
import { getTodayISODate } from '@/lib/personalizationSync';

function toLocalISO(d) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

const ACCENT_DARK = '#8ea400';

const METRIC_CONFIG = [
  { key: 'sleep_hours',        label: 'Sleep',   unit: 'hrs',  icon: Moon,            color: '#5d8aa8' },
  { key: 'water_liters',       label: 'Water',   unit: 'L',    icon: Droplets,        color: '#4a90d9' },
  { key: 'calories_consumed',  label: 'Eaten',   unit: 'kcal', icon: UtensilsCrossed, color: '#8ea400' },
  { key: 'calories_burned',    label: 'Burned',  unit: 'kcal', icon: Flame,           color: '#b05a3a' },
  { key: 'mood',               label: 'Mood',    unit: '/ 5',  icon: Heart,           color: '#c85a8a' },
  { key: 'energy',             label: 'Energy',  unit: '/ 10', icon: SmilePlus,       color: ACCENT_DARK },
  { key: 'weight_kg',          label: 'Weight',  unit: 'kg',   icon: Weight,          color: '#91968e' },
  { key: 'habits_completed',   label: 'Habits',  unit: 'done', icon: CheckSquare,     color: '#5d8a5d' },
];

const MOOD_EMOJIS = ['😞', '😕', '😐', '😊', '😄'];

function formatDateLabel(dateStr) {
  const yesterday = new Date();
  yesterday.setDate(yesterday.getDate() - 1);
  if (dateStr === toLocalISO(yesterday)) return 'Yesterday';
  return new Date(dateStr + 'T12:00:00').toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric' });
}

function MetricPill({ metricKey, value }) {
  const config = METRIC_CONFIG.find(m => m.key === metricKey);
  if (!config) return null;
  const Icon = config.icon;

  if (metricKey === 'mood') {
    return (
      <div className="flex items-center gap-1 px-2.5 py-1.5 rounded-xl text-xs font-semibold"
        style={{ background: `${config.color}12`, border: `1px solid ${config.color}22` }}>
        <span className="text-sm leading-none">{MOOD_EMOJIS[Math.round(value) - 1] || value}</span>
      </div>
    );
  }

  const displayVal = metricKey === 'habits_completed'
    ? (Array.isArray(value) ? value.length : value)
    : value;
  const unitLabel = metricKey === 'habits_completed' ? 'habits' : config.unit;

  return (
    <div className="flex items-center gap-1.5 px-2.5 py-1.5 rounded-xl text-xs font-semibold"
      style={{ background: `${config.color}12`, border: `1px solid ${config.color}22` }}>
      <Icon size={11} style={{ color: config.color }} />
      <span style={{ color: '#141613' }}>{displayVal}</span>
      <span style={{ color: '#91968e', fontWeight: 400 }}>{unitLabel}</span>
    </div>
  );
}

function hasData(log) {
  return METRIC_CONFIG.some(m => {
    const val = log[m.key];
    return val != null && val !== 0 && !(Array.isArray(val) && val.length === 0);
  });
}

export default function TrackingHistory() {
  const [logs, setLogs] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const today = getTodayISODate();
    backend.entities.DailyLog.list('-date', 30)
      .then(allLogs => {
        const seen = new Set();
        const past = (allLogs || [])
          .filter(l => l.date && l.date !== today)
          .sort((a, b) => b.date.localeCompare(a.date))
          .filter(l => { if (seen.has(l.date)) return false; seen.add(l.date); return true; })
          .filter(hasData);
        setLogs(past);
      })
      .catch(() => setLogs([]))
      .finally(() => setLoading(false));
  }, []);

  if (loading) {
    return (
      <div className="flex items-center justify-center py-8">
        <span className="w-4 h-4 border-2 border-t-transparent rounded-full animate-spin inline-block" style={{ borderColor: ACCENT_DARK, borderTopColor: 'transparent' }} />
      </div>
    );
  }

  if (logs.length === 0) {
    return (
      <p className="text-sm text-center py-6" style={{ color: '#91968e' }}>No past tracking data yet.</p>
    );
  }

  return (
    <div className="space-y-3 pb-2">
      {logs.map((log, i) => (
        <motion.div key={log.id || log.date}
          initial={{ opacity: 0, y: 6 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: i * 0.04 }}
          className="p-4 rounded-2xl border"
          style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
          <p className="text-xs font-bold mb-3" style={{ color: '#141613' }}>
            {formatDateLabel(log.date)}
            <span className="font-normal ml-2" style={{ color: '#91968e' }}>
              {new Date(log.date + 'T12:00:00').toLocaleDateString('en-US', { month: 'short', day: 'numeric' })}
            </span>
          </p>
          <div className="flex flex-wrap gap-2">
            {METRIC_CONFIG.map(m => {
              const val = log[m.key];
              const hasVal = val != null && val !== 0 && !(Array.isArray(val) && val.length === 0);
              return hasVal ? <MetricPill key={m.key} metricKey={m.key} value={val} /> : null;
            })}
          </div>
        </motion.div>
      ))}
    </div>
  );
}