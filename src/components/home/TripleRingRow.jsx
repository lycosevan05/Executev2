import { motion } from 'framer-motion';

function RingMini({ pct, size = 72, strokeWidth = 7 }) {
  const r = (size - strokeWidth * 2) / 2;
  const circ = 2 * Math.PI * r;
  const offset = circ * (1 - Math.min(pct, 1));

  return (
    <svg width={size} height={size} style={{ transform: 'rotate(-90deg)' }}>
      <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke="#e8e1d4" strokeWidth={strokeWidth} />
      <motion.circle
        cx={size / 2} cy={size / 2} r={r}
        fill="none" stroke="#c8e000" strokeWidth={strokeWidth}
        strokeLinecap="round"
        strokeDasharray={circ}
        initial={{ strokeDashoffset: circ }}
        animate={{ strokeDashoffset: offset }}
        transition={{ duration: 1.4, ease: [0.4, 0, 0.2, 1] }}
      />
    </svg>
  );
}

export default function TripleRingRow({ data }) {
  const { energy, calories, goalProgress } = data;

  const cards = [
    {
      label: 'Energy',
      value: `${energy.score}%`,
      sublabel: 'Readiness',
      pct: energy.score / 100,
      color: '#7DF9FF',
      context: 'Sleep + recovery',
    },
    {
      label: 'Calories',
      value: `${calories.net > 0 ? '+' : ''}${calories.net}`,
      sublabel: 'Net today',
      pct: Math.min(Math.abs(calories.net) / 500, 1),
      context: `${calories.consumed} in · ${calories.burned} out`,
    },
    {
      label: 'Goal',
      value: `${Math.round(goalProgress.pct * 100)}%`,
      sublabel: goalProgress.label,
      pct: goalProgress.pct,
      context: goalProgress.context,
    },
  ];

  return (
    <div className="grid grid-cols-3 gap-3">
      {cards.map((c, i) => (
        <motion.div
          key={c.label}
          initial={{ opacity: 0, y: 16 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: i * 0.1 + 0.1 }}
          className="flex flex-col items-center p-4 rounded-3xl border"
          style={{ background: '#ffffff', borderColor: '#e8e1d4' }}
        >
          <div className="relative flex items-center justify-center mb-2">
            <RingMini pct={c.pct} />
            <div className="absolute inset-0 flex flex-col items-center justify-center">
              <span className="text-sm font-black leading-none" style={{ color: '#141613' }}>{c.value}</span>
            </div>
          </div>
          <span className="text-[11px] font-semibold" style={{ color: '#141613' }}>{c.label}</span>
          <span className="text-[10px] mt-0.5 text-center leading-tight" style={{ color: '#91968e' }}>{c.context}</span>
        </motion.div>
      ))}
    </div>
  );
}