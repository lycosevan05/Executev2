import { motion } from 'framer-motion';
import { Sparkles } from 'lucide-react';

export default function AIInsightCard({ insight, category, delay = 0 }) {
  const categoryColors = {
    recovery: '#7DF9FF',
    nutrition: '#ADFF2F',
    workout: '#FF5F1F',
    sleep: '#a78bfa',
    default: '#7DF9FF',
  };
  const color = categoryColors[category] || categoryColors.default;

  return (
    <motion.div
      initial={{ opacity: 0, x: -12 }}
      animate={{ opacity: 1, x: 0 }}
      transition={{ delay, duration: 0.4 }}
      className="flex items-start gap-3 p-4 rounded-2xl border border-white/5 card-z1"
      style={{ background: '#0E0E14' }}
    >
      <div
        className="w-8 h-8 rounded-xl flex items-center justify-center flex-shrink-0"
        style={{ background: `${color}18` }}
      >
        <Sparkles size={16} style={{ color }} />
      </div>
      <div className="flex-1 min-w-0">
        {category && (
          <span
            className="text-[10px] font-semibold uppercase tracking-widest mb-1 block"
            style={{ color }}
          >
            {category}
          </span>
        )}
        <p className="text-sm text-ice-white/90 leading-relaxed">{insight}</p>
      </div>
    </motion.div>
  );
}