import { useState, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import { motion } from 'framer-motion';
import { TrendingUp, ChevronRight } from 'lucide-react';
import { loadActiveGoals } from '@/lib/personalizationSync';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

function calcPct(goal) {
  const cur = goal.current_value || 0;
  const tgt = goal.target_value || 1;
  const start = goal.start_value ?? 0;
  const dir = goal.target_direction || 'increase';
  if (dir === 'decrease') {
    const denom = start - tgt;
    return denom > 0 ? Math.max(0, Math.min(1, (start - cur) / denom)) : (cur <= tgt ? 1 : 0);
  }
  const denom = tgt - start;
  return denom > 0 ? Math.max(0, Math.min(1, (cur - start) / denom)) : (cur >= tgt ? 1 : 0);
}

export default function ProgressSnapshotCard() {
  const navigate = useNavigate();
  const [goals, setGoals] = useState([]);
  const [loaded, setLoaded] = useState(false);

  useEffect(() => {
    loadActiveGoals().then(gs => { setGoals(gs); setLoaded(true); }).catch(() => setLoaded(true));
  }, []);

  if (!loaded || goals.length === 0) return null;

  const active = goals.filter(g => g.status !== 'completed');
  const onTrack = active.filter(g => calcPct(g) > 0).length;
  const overallPct = active.length > 0
    ? Math.round(active.reduce((s, g) => s + calcPct(g), 0) / active.length * 100)
    : 0;

  return (
    <motion.div
      initial={{ opacity: 0, y: 8 }}
      animate={{ opacity: 1, y: 0 }}
      className="p-4 rounded-2xl border"
      style={{ background: '#ffffff', borderColor: '#e8e1d4' }}
    >
      <div className="flex items-center justify-between mb-3">
        <div className="flex items-center gap-2">
          <div className="w-7 h-7 rounded-xl flex items-center justify-center" style={{ background: 'rgba(200,224,0,0.12)' }}>
            <TrendingUp size={13} style={{ color: ACCENT_DARK }} />
          </div>
          <p className="text-xs font-bold uppercase tracking-widest" style={{ color: '#91968e' }}>Progress</p>
        </div>
        <button onClick={() => navigate('/progress')}
          className="flex items-center gap-0.5 text-xs font-semibold"
          style={{ color: ACCENT_DARK }}>
          View Progress <ChevronRight size={11} />
        </button>
      </div>

      <p className="text-sm font-semibold mb-2" style={{ color: '#141613' }}>
        {onTrack} of {active.length} goal{active.length !== 1 ? 's' : ''} on track
      </p>

      <div className="h-1.5 rounded-full overflow-hidden mb-1" style={{ background: '#e8e1d4' }}>
        <motion.div
          className="h-full rounded-full"
          style={{ background: ACCENT }}
          initial={{ width: 0 }}
          animate={{ width: `${overallPct}%` }}
          transition={{ duration: 1 }}
        />
      </div>
      <p className="text-[10px]" style={{ color: '#91968e' }}>{overallPct}% overall progress</p>
    </motion.div>
  );
}