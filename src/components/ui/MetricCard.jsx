import { motion } from 'framer-motion';

export default function MetricCard({ icon, label, value, unit, color = '#7DF9FF', progress, trend, delay = 0 }) {
  const colorMap = {
    '#7DF9FF': 'rgba(125, 249, 255, 0.12)',
    '#FF5F1F': 'rgba(255, 95, 31, 0.12)',
    '#ADFF2F': 'rgba(173, 255, 47, 0.12)',
  };
  const bg = colorMap[color] || 'rgba(125, 249, 255, 0.12)';

  return (
    <motion.div
      initial={{ opacity: 0, y: 16 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ delay, duration: 0.5 }}
      className="tilt-card rounded-2xl p-4 card-z2 border border-white/5"
      style={{ background: '#0E0E14' }}
    >
      {/* Icon */}
      <div className="w-9 h-9 rounded-xl flex items-center justify-center mb-3" style={{ background: bg }}>
        <span style={{ color }}>{icon}</span>
      </div>

      {/* Value */}
      <div className="flex items-end gap-1 mb-1">
        <span className="text-2xl font-bold text-ice-white">{value}</span>
        {unit && <span className="text-xs text-slate-mist mb-1">{unit}</span>}
      </div>

      {/* Label */}
      <span className="text-xs text-slate-mist">{label}</span>

      {/* Progress bar */}
      {progress !== undefined && (
        <div className="mt-3 h-1 rounded-full bg-white/5 overflow-hidden">
          <motion.div
            className="h-full rounded-full"
            style={{ background: color }}
            initial={{ width: 0 }}
            animate={{ width: `${Math.min(progress * 100, 100)}%` }}
            transition={{ delay: delay + 0.3, duration: 1 }}
          />
        </div>
      )}

      {/* Trend */}
      {trend && (
        <div className="mt-2 flex items-center gap-1">
          <span className={`text-xs font-medium ${trend > 0 ? 'text-hyper-lime' : 'text-neon-ember'}`}>
            {trend > 0 ? '↑' : '↓'} {Math.abs(trend)}%
          </span>
          <span className="text-[10px] text-slate-mist">vs yesterday</span>
        </div>
      )}
    </motion.div>
  );
}