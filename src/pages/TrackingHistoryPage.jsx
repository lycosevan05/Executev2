import { useState, useEffect } from 'react';
import { motion } from 'framer-motion';
import { ArrowLeft, Moon, Flame, Droplets, Heart, Weight, SmilePlus, UtensilsCrossed, CheckSquare } from 'lucide-react';
import { useNavigate } from 'react-router-dom';
import { backend } from '@/api/backendClient';
import { getTodayISODate } from '@/lib/personalizationSync';

function toLocalISO(d) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

const ACCENT_DARK = '#8ea400';

const METRIC_CONFIG = [
  { key: 'sleep_hours',        label: 'Sleep',   unit: 'hrs',    icon: Moon,            color: '#5d8aa8' },
  { key: 'water_liters',       label: 'Water',   unit: 'L',      icon: Droplets,        color: '#4a90d9' },
  { key: 'calories_consumed',  label: 'Eaten',   unit: 'kcal',   icon: UtensilsCrossed, color: '#8ea400' },
  { key: 'calories_burned',    label: 'Burned',  unit: 'kcal',   icon: Flame,           color: '#b05a3a' },
  { key: 'mood',               label: 'Mood',    unit: '/ 5',    icon: Heart,           color: '#c85a8a' },
  { key: 'energy',             label: 'Energy',  unit: '/ 10',   icon: SmilePlus,       color: ACCENT_DARK },
  { key: 'weight_kg',          label: 'Weight',  unit: 'kg',     icon: Weight,          color: '#91968e' },
  { key: 'habits_completed',   label: 'Habits',  unit: 'done',   icon: CheckSquare,     color: '#5d8a5d' },
];

const MOOD_EMOJIS = ['😞', '😕', '😐', '😊', '😄'];

function formatDateLabel(dateStr) {
  const today = getTodayISODate();
  const yesterday = new Date();
  yesterday.setDate(yesterday.getDate() - 1);
  const yStr = toLocalISO(yesterday);
  if (dateStr === today) return 'Today';
  if (dateStr === yStr) return 'Yesterday';
  return new Date(dateStr + 'T12:00:00').toLocaleDateString('en-US', { weekday: 'long', month: 'short', day: 'numeric' });
}

function MetricPill({ metricKey, value }) {
  const config = METRIC_CONFIG.find(m => m.key === metricKey);
  if (!config) return null;
  const Icon = config.icon;

  if (metricKey === 'mood') {
    return (
      <div className="flex items-center gap-1.5 px-3 py-2 rounded-xl text-xs font-semibold"
        style={{ background: `${config.color}12`, border: `1px solid ${config.color}22` }}>
        <Icon size={12} style={{ color: config.color }} />
        <span className="text-sm leading-none">{MOOD_EMOJIS[Math.round(value) - 1] || value}</span>
        <span style={{ color: '#91968e', fontWeight: 400 }}>{config.label}</span>
      </div>
    );
  }

  const displayVal = metricKey === 'habits_completed'
    ? (Array.isArray(value) ? value.length : value)
    : value;
  const unitLabel = metricKey === 'habits_completed' ? 'habits' : config.unit;

  return (
    <div className="flex items-center gap-1.5 px-3 py-2 rounded-xl text-xs font-semibold"
      style={{ background: `${config.color}12`, border: `1px solid ${config.color}22` }}>
      <Icon size={12} style={{ color: config.color }} />
      <span style={{ color: '#141613', fontWeight: 700 }}>{displayVal}</span>
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

export default function TrackingHistoryPage() {
  const navigate = useNavigate();
  const [logs, setLogs] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    backend.entities.DailyLog.list('-date', 60)
      .then(allLogs => {
        const seen = new Set();
        const past = (allLogs || [])
          .sort((a, b) => b.date?.localeCompare(a.date))
          .filter(l => {
            if (!l.date || seen.has(l.date)) return false;
            seen.add(l.date);
            return true;
          })
          .filter(hasData);
        setLogs(past);
      })
      .catch(() => setLogs([]))
      .finally(() => setLoading(false));
  }, []);

  return (
    <div className="min-h-screen" style={{ background: '#f6f2e8' }}>
      {/* Header */}
      <div className="sticky top-0 z-40 px-5 pt-12 pb-4"
        style={{ background: 'rgba(251,248,241,0.95)', backdropFilter: 'blur(24px)', borderBottom: '1px solid #e8e1d4' }}>
        <div className="flex items-center gap-3">
          <button onClick={() => navigate(-1)}
            className="w-9 h-9 rounded-xl flex items-center justify-center border"
            style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
            <ArrowLeft size={16} style={{ color: '#5d635d' }} />
          </button>
          <div>
            <h1 className="text-lg font-bold tracking-tight" style={{ color: '#141613' }}>History</h1>
            <p className="text-xs mt-0.5" style={{ color: '#91968e' }}>Your past tracked days</p>
          </div>
        </div>
      </div>

      {/* Content */}
      <div className="px-5 pt-5 pb-24 space-y-3">
        {loading ? (
          <div className="flex items-center justify-center py-20">
            <span className="w-5 h-5 border-2 border-t-transparent rounded-full animate-spin"
              style={{ borderColor: ACCENT_DARK, borderTopColor: 'transparent' }} />
          </div>
        ) : logs.length === 0 ? (
          <div className="flex flex-col items-center py-24 text-center">
            <div className="w-14 h-14 rounded-2xl flex items-center justify-center mb-4"
              style={{ background: 'rgba(200,224,0,0.1)', border: '1px solid rgba(200,224,0,0.2)' }}>
              <Moon size={22} style={{ color: ACCENT_DARK }} />
            </div>
            <p className="text-base font-bold mb-1" style={{ color: '#141613' }}>No history yet</p>
            <p className="text-sm" style={{ color: '#91968e' }}>Start logging today and your data will appear here.</p>
          </div>
        ) : (
          logs.map((log, i) => (
            <motion.div key={log.id || log.date}
              initial={{ opacity: 0, y: 8 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ delay: i * 0.03 }}
              className="p-4 rounded-2xl border"
              style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
              <p className="text-sm font-bold mb-1" style={{ color: '#141613' }}>
                {formatDateLabel(log.date)}
              </p>
              <p className="text-xs mb-3" style={{ color: '#91968e' }}>
                {new Date(log.date + 'T12:00:00').toLocaleDateString('en-US', { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' })}
              </p>
              <div className="flex flex-wrap gap-2">
                {METRIC_CONFIG.map(m => {
                  const val = log[m.key];
                  const hasVal = val != null && val !== 0 && !(Array.isArray(val) && val.length === 0);
                  return hasVal ? <MetricPill key={m.key} metricKey={m.key} value={val} /> : null;
                })}
              </div>
            </motion.div>
          ))
        )}
      </div>
    </div>
  );
}