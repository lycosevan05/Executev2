import { motion } from 'framer-motion';
import { Link } from 'react-router-dom';
import { resolveMacroTargets } from '@/lib/calorieGoal';

const MACROS = [
  { key: 'protein', label: 'Protein', color: '#8ea400', consumed_key: 'protein_consumed_g', target_key: 'protein_g' },
  { key: 'carbs',   label: 'Carbs',   color: '#b05a3a', consumed_key: 'carbs_consumed_g',   target_key: 'carbs_g' },
  { key: 'fat',     label: 'Fat',     color: '#5d635d', consumed_key: 'fats_consumed_g',    target_key: 'fat_g' },
];

function MacroCircle({ consumed, target, color, label }) {
  const R = 22;
  const circumference = 2 * Math.PI * R;
  const progress = target > 0 ? Math.min(consumed / target, 1) : 0;
  const dashOffset = circumference * (1 - progress);
  const isOver = target && consumed > target;
  const displayColor = isOver ? '#b05a3a' : color;

  return (
    <Link
      to="/nutrition"
      className="flex flex-col items-center gap-1.5 py-3 px-1 rounded-xl border"
      style={{ background: '#ffffff', borderColor: '#e8e1d4', textDecoration: 'none' }}
    >
      <div className="relative" style={{ width: 52, height: 52 }}>
        <svg width="52" height="52" viewBox="0 0 52 52" style={{ transform: 'rotate(-90deg)' }}>
          <circle cx="26" cy="26" r={R} fill="none" stroke="#f2efe7" strokeWidth="5" />
          {progress > 0 && (
            <motion.circle
              cx="26" cy="26" r={R}
              fill="none"
              stroke={displayColor}
              strokeWidth="5"
              strokeLinecap="round"
              strokeDasharray={circumference}
              initial={{ strokeDashoffset: circumference }}
              animate={{ strokeDashoffset: dashOffset }}
              transition={{ duration: 1.0, ease: 'easeOut' }}
            />
          )}
        </svg>
        <div className="absolute inset-0 flex flex-col items-center justify-center">
          <span className="text-[11px] font-black leading-none" style={{ color: '#141613' }}>
            {Math.round(consumed)}
          </span>
          <span className="text-[8px]" style={{ color: '#91968e' }}>g</span>
        </div>
      </div>

      <span className="text-[10px] font-bold" style={{ color: '#91968e' }}>{label}</span>

      {target ? (
        <span className="text-[9px]" style={{ color: isOver ? '#b05a3a' : '#b8b4ac' }}>
          {isOver ? `+${Math.round(consumed - target)}g` : `/ ${Math.round(target)}g`}
        </span>
      ) : (
        <span className="text-[9px]" style={{ color: '#d9d1c2' }}>Set target</span>
      )}
    </Link>
  );
}

export default function MacroTrackerCard({ dailyLog, nutritionProfile, activePlan, mealPlan, userProfile }) {
  const targets = resolveMacroTargets({ nutritionProfile, activePlan, mealPlan, userProfile });

  return (
    <motion.div
      initial={{ opacity: 0, y: 10 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ delay: 0.13 }}
      className="grid grid-cols-3 gap-2"
    >
      {MACROS.map((macro) => (
        <MacroCircle
          key={macro.key}
          consumed={dailyLog?.[macro.consumed_key] || 0}
          target={targets[macro.target_key]}
          color={macro.color}
          label={macro.label}
        />
      ))}
    </motion.div>
  );
}