import { motion } from 'framer-motion';
import { useNavigate } from 'react-router-dom';
import { Moon, Footprints, Flame, Droplets, Smile, Zap, Dumbbell, Scale, Pencil } from 'lucide-react';

const ICON_MAP = { Moon, Footprints, Flame, Droplets, Smile, Zap, Dumbbell, Scale, Pencil };

export default function VitalsRowWidget({ today, vitals, isCustomizing }) {
  const navigate = useNavigate();
  const openTracker = (id) => {
    if (isCustomizing) return;
    navigate('/track', { state: { openTracker: id } });
  };

  return (
    <div className="space-y-2">
      <motion.div
        initial={{ opacity: 0, y: 12 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ delay: 0.1 }}
        className="grid gap-2"
        style={{ gridTemplateColumns: `repeat(${Math.min(vitals.activeVitals.length, 6)}, 1fr)` }}
      >
        {vitals.activeVitals.map((v) => {
          const IconComp = ICON_MAP[v.icon] || Zap;
          const raw = today[v.dataKey] ?? 0;
          const goal = v.goalKey ? (today[v.goalKey] ?? v.goalFixed) : v.goalFixed;
          const pct = goal ? raw / goal : 0;
          let displayValue;
          if (v.id === 'steps') displayValue = (raw / 1000).toFixed(1) + 'k';
          else if (v.unit) displayValue = `${raw}${v.unit}`;
          else displayValue = String(raw);

          // Calorie vital gets a ring instead of plain number
          if (v.id === 'calories') {
            const R = 18;
            const CIRC = 2 * Math.PI * R;
            const ringPct = Math.min(pct, 1);
            const offset = CIRC * (1 - ringPct);
            const ringColor = pct >= 1 ? '#b05a3a' : pct >= 0.7 ? '#c8e000' : '#8ea400';
            return (
              <button
                key={v.id}
                type="button"
                onClick={() => openTracker(v.id)}
                className="p-2 rounded-xl border text-center flex flex-col items-center active:scale-95 transition-transform"
                style={{
                  background: pct >= 1 ? 'rgba(176,90,58,0.06)' : '#ffffff',
                  borderColor: pct >= 1 ? 'rgba(176,90,58,0.35)' : '#e0d9cc',
                  boxShadow: '0 1px 6px rgba(20,22,19,0.07)',
                }}
              >
                <div className="relative flex items-center justify-center" style={{ width: 44, height: 44 }}>
                  <svg width="44" height="44" viewBox="0 0 44 44" style={{ transform: 'rotate(-90deg)' }}>
                    <circle cx="22" cy="22" r={R} fill="none" stroke="#ede8de" strokeWidth="4" />
                    <motion.circle
                      cx="22" cy="22" r={R}
                      fill="none"
                      stroke={ringColor}
                      strokeWidth="4"
                      strokeLinecap="round"
                      strokeDasharray={CIRC}
                      initial={{ strokeDashoffset: CIRC }}
                      animate={{ strokeDashoffset: offset }}
                      transition={{ duration: 1.0, ease: 'easeOut' }}
                    />
                  </svg>
                  <div className="absolute inset-0 flex items-center justify-center">
                    <Flame size={11} style={{ color: ringColor }} />
                  </div>
                </div>
                <div className="text-[10px] font-bold mt-0.5" style={{ color: '#141613' }}>
                  {raw > 0 ? (raw >= 1000 ? (raw / 1000).toFixed(1) + 'k' : raw) : '—'}
                </div>
                <div className="text-[9px]" style={{ color: '#a09a90' }}>{v.label}</div>
              </button>
            );
          }

          return (
            <button
              key={v.id}
              type="button"
              onClick={() => openTracker(v.id)}
              className="p-3 rounded-xl border text-center active:scale-95 transition-transform"
              style={{
                background: pct >= 1 ? 'rgba(200,224,0,0.08)' : '#ffffff',
                borderColor: pct >= 1 ? 'rgba(200,224,0,0.35)' : '#e0d9cc',
                boxShadow: '0 1px 6px rgba(20,22,19,0.07)',
              }}
            >
              <IconComp size={13} className="mx-auto mb-1" style={{ color: pct >= 0.8 ? '#8ea400' : '#a09a90' }} />
              <div className="text-xs font-bold" style={{ color: '#141613' }}>{displayValue}</div>
              <div className="text-[9px] mt-0.5" style={{ color: '#a09a90' }}>{v.label}</div>
              {goal && (
                <div className="h-0.5 rounded-full mt-1.5 overflow-hidden" style={{ background: '#ede8de' }}>
                  <div className="h-full rounded-full transition-all duration-500" style={{ width: `${Math.min(pct * 100, 100)}%`, background: pct >= 1 ? '#c8e000' : pct >= 0.5 ? '#d4ef1f' : '#c8c0b0' }} />
                </div>
              )}
            </button>
          );
        })}
      </motion.div>

      
    </div>
  );
}